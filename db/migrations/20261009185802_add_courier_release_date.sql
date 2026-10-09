begin;

alter table indique_ganhe_influencer.referrals
  add column if not exists released_at date;

create or replace function indique_ganhe_influencer.complete_import(p_batch_id uuid)
returns jsonb language plpgsql security definer
set search_path = pg_catalog, indique_ganhe_influencer
as $$
declare
  v_batch indique_ganhe_influencer.import_batches%rowtype;
  v_rows integer;
  v_result jsonb;
begin
  if not indique_ganhe_influencer.is_admin() then
    raise exception 'Apenas a administração pode importar arquivos.';
  end if;
  select * into v_batch
  from indique_ganhe_influencer.import_batches b
  where b.id = p_batch_id and b.created_by = auth.uid()
  for update;
  if not found or v_batch.status <> 'staging' then
    raise exception 'Importação não encontrada ou já finalizada.';
  end if;

  select count(*)::integer into v_rows
  from indique_ganhe_influencer.import_rows r
  where r.batch_id = p_batch_id;
  if v_rows <> v_batch.expected_rows or v_rows <> v_batch.staged_rows then
    raise exception 'A importação recebeu % de % registros. Nada foi aplicado.', v_rows, v_batch.expected_rows;
  end if;

  perform pg_advisory_xact_lock(hashtext('indique_ganhe:' || v_batch.kind));
  if v_batch.kind = 'data_crazy' then
    if exists (
      select 1 from indique_ganhe_influencer.import_rows r
      where r.batch_id = p_batch_id
        and coalesce(r.payload->>'uuid', '') !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
    ) then
      raise exception 'Há UUID inválido no lote Data Crazy.';
    end if;

    update indique_ganhe_influencer.attribution_reviews
    set status = 'superseded'
    where status = 'open';
    delete from indique_ganhe_influencer.referrals where uuid is not null;
    insert into indique_ganhe_influencer.referrals
      (uuid, name, region, released_at, phone, cpf, phone_unavailable, influencer_id, raw_influencer, source_batch_id)
    select (r.payload->>'uuid')::uuid,
      coalesce(r.payload->>'name', ''), nullif(r.payload->>'region', ''),
      nullif(r.payload->>'releasedAt', '')::date,
      nullif(r.payload->>'phone', ''),
      case when coalesce(r.payload->>'cpf', '') ~ '^[0-9]{11}$' then r.payload->>'cpf' else null end,
      coalesce((r.payload->>'phoneUnavailable')::boolean, false),
      case when i.id is not null then i.id else null end,
      coalesce(r.payload->>'rawInfluencer', ''), p_batch_id
    from indique_ganhe_influencer.import_rows r
    left join indique_ganhe_influencer.influencers i on i.id = r.payload->>'influencerId'
    where r.batch_id = p_batch_id;

    insert into indique_ganhe_influencer.attribution_reviews (batch_id, uuid, name, region, raw_influencer)
    select p_batch_id, (r.payload->>'uuid')::uuid, coalesce(r.payload->>'name', ''),
      nullif(r.payload->>'region', ''), coalesce(r.payload->>'rawInfluencer', '')
    from indique_ganhe_influencer.import_rows r
    where r.batch_id = p_batch_id and nullif(r.payload->>'influencerId', '') is null;
    v_result := jsonb_build_object('imported', v_rows, 'kind', 'data_crazy');
  else
    if exists (
      select 1 from indique_ganhe_influencer.import_rows r
      where r.batch_id = p_batch_id and (
        coalesce(r.payload->>'uuid', '') !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
        or coalesce(r.payload->>'routes', '') !~ '^[0-9]+$'
      )
    ) then
      raise exception 'Há UUID ou quantidade de corridas inválida no lote Performance.';
    end if;

    insert into indique_ganhe_influencer.performance_contributions
      (batch_id, uuid, route_count, fallback_name, fallback_region)
    select p_batch_id, (r.payload->>'uuid')::uuid, (r.payload->>'routes')::integer,
      nullif(r.payload->>'name', ''), nullif(r.payload->>'region', '')
    from indique_ganhe_influencer.import_rows r
    where r.batch_id = p_batch_id;

    insert into indique_ganhe_influencer.performance_totals (uuid, route_count, fallback_name, fallback_region)
    select (r.payload->>'uuid')::uuid,
      sum((r.payload->>'routes')::integer)::bigint,
      max(nullif(r.payload->>'name', '')),
      max(nullif(r.payload->>'region', ''))
    from indique_ganhe_influencer.import_rows r
    where r.batch_id = p_batch_id
    group by (r.payload->>'uuid')::uuid
    on conflict (uuid) do update set
      route_count = indique_ganhe_influencer.performance_totals.route_count + excluded.route_count,
      fallback_name = greatest(indique_ganhe_influencer.performance_totals.fallback_name, excluded.fallback_name),
      fallback_region = greatest(indique_ganhe_influencer.performance_totals.fallback_region, excluded.fallback_region),
      updated_at = now();

    v_result := jsonb_build_object('imported', v_rows, 'kind', 'performance');
  end if;

  update indique_ganhe_influencer.import_batches
  set status = 'completed', completed_at = now(), finished_at = now(), error_message = null
  where id = p_batch_id;
  insert into indique_ganhe_influencer.import_activity
    (batch_id, actor_id, event_type, message, details)
  values (
    p_batch_id, auth.uid(), 'completed',
    case when v_batch.kind = 'data_crazy' then 'Data Crazy substituiu a lista atual com sucesso.'
      else 'Importação de Performance concluída e corridas somadas.' end,
    jsonb_build_object('rows_processed', v_rows, 'kind', v_batch.kind, 'metrics', v_batch.metrics)
  );
  delete from indique_ganhe_influencer.import_rows where batch_id = p_batch_id;
  return v_result;
end;
$$;

create or replace view indique_ganhe_influencer.referral_progress
with (security_invoker = true) as
select r.uuid as referral_id,
  r.uuid,
  coalesce(nullif(r.name, ''), t.fallback_name, '') as name,
  coalesce(nullif(r.region, ''), t.fallback_region) as region,
  r.phone,
  r.cpf,
  coalesce(t.route_count, 0::bigint) as routes,
  i.route_goal,
  i.prize_cents,
  coalesce(t.route_count, 0::bigint) >= i.route_goal as prize_unlocked,
  greatest(i.route_goal::bigint - coalesce(t.route_count, 0::bigint), 0::bigint) as routes_remaining,
  i.name as influencer_name,
  r.released_at
from indique_ganhe_influencer.referrals r
join indique_ganhe_influencer.influencers i on i.id = r.influencer_id
left join indique_ganhe_influencer.performance_totals t on t.uuid = r.uuid
where r.influencer_id is not null and not i.is_demo
union all
select d.uuid as referral_id,
  d.uuid,
  d.name,
  d.region,
  null::text as phone,
  null::text as cpf,
  d.routes,
  i.route_goal,
  i.prize_cents,
  d.routes >= i.route_goal as prize_unlocked,
  greatest(i.route_goal::bigint - d.routes, 0::bigint) as routes_remaining,
  i.name as influencer_name,
  null::date as released_at
from indique_ganhe_influencer.demo_referrals d
join indique_ganhe_influencer.influencers i on i.id = 'teste' and i.is_demo;

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
      select r.uuid, r.name, r.region, r.released_at, r.phone, r.cpf,
        i.id as influencer_id, i.name as influencer_name,
        coalesce(t.route_count, 0)::bigint as routes,
        i.route_goal, i.prize_cents,
        coalesce(t.route_count, 0)::bigint >= i.route_goal as prize_unlocked,
        greatest(i.route_goal::bigint - coalesce(t.route_count, 0)::bigint, 0::bigint) as routes_remaining,
        i.sort_order as influencer_order
      from indique_ganhe_influencer.referrals r
      join indique_ganhe_influencer.influencers i on i.id = r.influencer_id
      left join indique_ganhe_influencer.performance_totals t on t.uuid = r.uuid
      where r.influencer_id is not null and not i.is_demo
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

notify pgrst, 'reload schema';
commit;
