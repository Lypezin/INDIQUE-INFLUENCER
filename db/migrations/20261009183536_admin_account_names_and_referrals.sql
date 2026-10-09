begin;

alter table indique_ganhe_influencer.account_members
  add column if not exists display_name text;

do $$
begin
  if not exists (
    select 1 from pg_constraint
    where conrelid = 'indique_ganhe_influencer.account_members'::regclass
      and conname = 'account_members_display_name_check'
  ) then
    alter table indique_ganhe_influencer.account_members
      add constraint account_members_display_name_check
      check (
        display_name is null
        or (
          display_name = btrim(display_name)
          and char_length(display_name) between 1 and 80
          and display_name !~ '[[:cntrl:]]'
        )
      );
  end if;
end;
$$;

create or replace function indique_ganhe_influencer.current_profile()
returns jsonb language plpgsql stable security definer
set search_path = pg_catalog, indique_ganhe_influencer
as $$
declare
  v_profile jsonb;
begin
  select jsonb_build_object(
    'user_id', m.user_id,
    'role', m.role,
    'influencer_id', m.influencer_id,
    'email', m.email,
    'display_name', m.display_name
  )
  into v_profile
  from indique_ganhe_influencer.account_members m
  where m.user_id = auth.uid();

  if v_profile is null then
    raise exception 'Esta conta ainda não tem convite. Peça ao administrador para vincular seu e-mail.';
  end if;
  return v_profile;
end;
$$;

create or replace function indique_ganhe_influencer.admin_overview()
returns jsonb language plpgsql stable security definer
set search_path = pg_catalog, indique_ganhe_influencer
as $$
begin
  if not indique_ganhe_influencer.is_admin() then
    raise exception 'Apenas a administração pode abrir esta área.';
  end if;
  return jsonb_build_object(
    'influencers', (
      select coalesce(jsonb_agg(to_jsonb(i) order by i.sort_order), '[]'::jsonb)
      from indique_ganhe_influencer.influencers i where not i.is_demo
    ),
    'availableInfluencers', (
      select coalesce(jsonb_agg(to_jsonb(i) order by i.sort_order), '[]'::jsonb)
      from indique_ganhe_influencer.influencers i
    ),
    'imports', (
      select coalesce(jsonb_agg(jsonb_build_object(
        'id', b.id, 'kind', b.kind, 'file_name', b.file_name,
        'status', b.status, 'created_at', b.created_at, 'metrics', b.metrics
      ) order by b.created_at desc), '[]'::jsonb)
      from (
        select * from indique_ganhe_influencer.import_batches
        where status <> 'staging' order by created_at desc limit 10
      ) b
    ),
    'reviews', (
      select coalesce(jsonb_agg(jsonb_build_object(
        'id', r.id, 'uuid', r.uuid, 'name', r.name,
        'region', r.region, 'raw_influencer', r.raw_influencer, 'status', r.status
      ) order by r.created_at), '[]'::jsonb)
      from (
        select * from indique_ganhe_influencer.attribution_reviews
        where status = 'open' order by created_at, id limit 50
      ) r
    ),
    'reviewCount', (
      select count(*) from indique_ganhe_influencer.attribution_reviews r where r.status = 'open'
    ),
    'members', (
      select coalesce(jsonb_agg(jsonb_build_object(
        'user_id', m.user_id, 'email', m.email, 'role', m.role,
        'display_name', m.display_name,
        'influencer_id', m.influencer_id, 'influencer_name', i.name
      ) order by m.role, m.email), '[]'::jsonb)
      from indique_ganhe_influencer.account_members m
      left join indique_ganhe_influencer.influencers i on i.id = m.influencer_id
    ),
    'invites', (
      select coalesce(jsonb_agg(jsonb_build_object(
        'id', a.id, 'email', a.email, 'role', a.role,
        'influencer_id', a.influencer_id, 'influencer_name', i.name,
        'created_at', a.created_at
      ) order by a.created_at desc), '[]'::jsonb)
      from indique_ganhe_influencer.account_invites a
      left join indique_ganhe_influencer.influencers i on i.id = a.influencer_id
      where a.status = 'pending'
    ),
    'referralCount', (
      select count(*) from indique_ganhe_influencer.referrals r where r.influencer_id is not null
    ),
    'contributionTotal', (
      select coalesce(sum(t.route_count), 0)
      from indique_ganhe_influencer.performance_totals t
    )
  );
end;
$$;

create or replace function indique_ganhe_influencer.update_admin_display_name(
  p_user_id uuid,
  p_display_name text
)
returns jsonb language plpgsql security definer
set search_path = pg_catalog, indique_ganhe_influencer
as $$
declare
  v_display_name text := nullif(btrim(p_display_name), '');
begin
  if not indique_ganhe_influencer.is_admin() then
    raise exception 'Apenas a administração pode alterar nomes de conta.';
  end if;
  if p_user_id is null then
    raise exception 'Selecione uma conta administrativa.';
  end if;
  if v_display_name is not null and (
    char_length(v_display_name) > 80 or v_display_name ~ '[[:cntrl:]]'
  ) then
    raise exception 'O nome deve ter até 80 caracteres em uma única linha.';
  end if;

  update indique_ganhe_influencer.account_members m
  set display_name = v_display_name
  where m.user_id = p_user_id and m.role = 'admin';
  if not found then
    raise exception 'Conta administrativa não encontrada.';
  end if;

  return jsonb_build_object('userId', p_user_id, 'displayName', v_display_name);
end;
$$;

create or replace function indique_ganhe_influencer.admin_referrals_page(
  p_limit integer default 50,
  p_offset integer default 0,
  p_influencer_id text default 'all',
  p_search text default ''
)
returns jsonb language plpgsql stable security definer
set search_path = pg_catalog, indique_ganhe_influencer
as $$
declare
  v_influencer_id text := coalesce(nullif(btrim(p_influencer_id), ''), 'all');
  v_search text := lower(btrim(coalesce(p_search, '')));
begin
  if not indique_ganhe_influencer.is_admin() then
    raise exception 'Apenas a administração pode consultar todos os indicados.';
  end if;
  if p_limit is null or p_limit < 1 or p_limit > 100 then
    raise exception 'A quantidade por página deve ficar entre 1 e 100.';
  end if;
  if p_offset is null or p_offset < 0 then
    raise exception 'A página solicitada é inválida.';
  end if;
  if char_length(v_search) > 120 then
    raise exception 'A busca deve ter até 120 caracteres.';
  end if;
  if v_influencer_id <> 'all' and not exists (
    select 1 from indique_ganhe_influencer.influencers i
    where i.id = v_influencer_id and not i.is_demo
  ) then
    raise exception 'Influenciador não encontrado.';
  end if;

  return (
    with filtered as (
      select
        r.uuid,
        r.name,
        r.region,
        r.phone,
        r.cpf,
        i.id as influencer_id,
        i.name as influencer_name,
        coalesce(t.route_count, 0)::bigint as routes,
        i.route_goal,
        i.prize_cents,
        coalesce(t.route_count, 0)::bigint >= i.route_goal as prize_unlocked,
        greatest(i.route_goal::bigint - coalesce(t.route_count, 0)::bigint, 0::bigint) as routes_remaining,
        i.sort_order as influencer_order
      from indique_ganhe_influencer.referrals r
      join indique_ganhe_influencer.influencers i on i.id = r.influencer_id
      left join indique_ganhe_influencer.performance_totals t on t.uuid = r.uuid
      where r.influencer_id is not null
        and not i.is_demo
        and (v_influencer_id = 'all' or i.id = v_influencer_id)
        and (
          v_search = ''
          or strpos(lower(concat_ws(' ', r.name, r.uuid::text, r.region, r.phone, r.cpf, i.name)), v_search) > 0
        )
    ),
    paged as (
      select * from filtered
      order by influencer_order, name, uuid
      limit p_limit offset p_offset
    )
    select jsonb_build_object(
      'items', coalesce((
        select jsonb_agg(to_jsonb(p) - 'influencer_order' order by p.influencer_order, p.name, p.uuid)
        from paged p
      ), '[]'::jsonb),
      'total', (select count(*) from filtered),
      'totalRoutes', (select coalesce(sum(f.routes), 0) from filtered f),
      'unlockedCount', (select count(*) from filtered f where f.prize_unlocked),
      'unlockedPrizeCents', (select coalesce(sum(f.prize_cents), 0) from filtered f where f.prize_unlocked)
    )
  );
end;
$$;

revoke execute on function indique_ganhe_influencer.current_profile() from public, anon;
revoke execute on function indique_ganhe_influencer.admin_overview() from public, anon;
revoke execute on function indique_ganhe_influencer.update_admin_display_name(uuid, text) from public, anon;
revoke execute on function indique_ganhe_influencer.admin_referrals_page(integer, integer, text, text) from public, anon;
grant execute on function indique_ganhe_influencer.current_profile() to authenticated;
grant execute on function indique_ganhe_influencer.admin_overview() to authenticated;
grant execute on function indique_ganhe_influencer.update_admin_display_name(uuid, text) to authenticated;
grant execute on function indique_ganhe_influencer.admin_referrals_page(integer, integer, text, text) to authenticated;

commit;
