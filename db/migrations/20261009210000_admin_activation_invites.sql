begin;

create or replace function indique_ganhe_influencer.issue_admin_activation_invite(
  p_email text,
  p_token_hash text,
  p_expires_at timestamptz
)
returns jsonb language plpgsql security definer
set search_path = pg_catalog, indique_ganhe_influencer
as $$
declare
  v_email text := lower(trim(coalesce(p_email, '')));
  v_invite indique_ganhe_influencer.account_invites%rowtype;
  v_invite_id uuid;
begin
  if auth.uid() is null or not indique_ganhe_influencer.is_admin() then
    raise exception 'Apenas a administração pode liberar acessos administrativos.';
  end if;
  if v_email !~* '^[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}$' then
    raise exception 'Informe um e-mail válido.';
  end if;
  if coalesce(p_token_hash, '') !~ '^[0-9a-f]{64}$' then
    raise exception 'Código de ativação inválido.';
  end if;
  if p_expires_at <= now() or p_expires_at > now() + interval '25 hours' then
    raise exception 'O prazo do convite é inválido.';
  end if;
  if exists (
    select 1 from indique_ganhe_influencer.account_members m
    where lower(m.email) = v_email
  ) then
    raise exception 'Este e-mail já está vinculado a uma conta.';
  end if;

  select * into v_invite
  from indique_ganhe_influencer.account_invites i
  where lower(i.email) = v_email
  for update;

  if found then
    if v_invite.status = 'redeeming' then
      raise exception 'Este convite já está sendo ativado. Tente novamente em alguns minutos.';
    end if;
    if v_invite.status = 'pending' and v_invite.activation_expires_at > now() then
      if v_invite.role = 'admin' then
        raise exception 'Este e-mail já possui um convite administrativo ativo.';
      else
        raise exception 'Este e-mail já possui um convite de influenciador ativo.';
      end if;
    end if;

    update indique_ganhe_influencer.account_invites
    set email = v_email,
        role = 'admin',
        influencer_id = null,
        status = 'pending',
        created_by = auth.uid(),
        claimed_by = null,
        claimed_at = null,
        activation_token_hash = p_token_hash,
        activation_expires_at = p_expires_at,
        activation_claim_id = null,
        activation_claim_started_at = null,
        activation_failed_attempts = 0,
        activation_failure_window_started_at = null
    where id = v_invite.id
    returning id into v_invite_id;
  else
    insert into indique_ganhe_influencer.account_invites (
      email, role, influencer_id, status, created_by,
      activation_token_hash, activation_expires_at, activation_failed_attempts
    ) values (
      v_email, 'admin', null, 'pending', auth.uid(),
      p_token_hash, p_expires_at, 0
    ) returning id into v_invite_id;
  end if;

  return jsonb_build_object(
    'invite_id', v_invite_id,
    'email', v_email,
    'role', 'admin',
    'expires_at', p_expires_at
  );
end;
$$;

revoke execute on function indique_ganhe_influencer.issue_admin_activation_invite(text, text, timestamptz) from public, anon;
grant execute on function indique_ganhe_influencer.issue_admin_activation_invite(text, text, timestamptz) to authenticated;

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

revoke execute on function indique_ganhe_influencer.admin_overview() from public, anon;
grant execute on function indique_ganhe_influencer.admin_overview() to authenticated;

commit;
