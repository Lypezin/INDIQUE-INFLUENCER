-- Bound import staging work and keep cumulative route reads independent of
-- the number of historical Performance imports.

alter table indique_ganhe_influencer.import_batches
  add column if not exists staged_rows integer not null default 0;

-- Preserve any import that was already in progress when this migration runs.
update indique_ganhe_influencer.import_batches b
set staged_rows = (
  select count(*)::integer
  from indique_ganhe_influencer.import_rows r
  where r.batch_id = b.id
)
where b.status = 'staging';

create or replace function indique_ganhe_influencer.append_import_rows(p_batch_id uuid, p_rows jsonb)
returns integer language plpgsql security definer
set search_path = pg_catalog, indique_ganhe_influencer
as $$
declare
  v_expected integer;
  v_staged integer;
  v_added integer;
begin
  if not indique_ganhe_influencer.is_admin() then
    raise exception 'Apenas a administração pode importar arquivos.';
  end if;
  if p_rows is null or jsonb_typeof(p_rows) is distinct from 'array' then
    raise exception 'Envie um lote entre 1 e 300 registros.';
  end if;
  if jsonb_array_length(p_rows) < 1 or jsonb_array_length(p_rows) > 300 then
    raise exception 'Envie um lote entre 1 e 300 registros.';
  end if;

  select b.expected_rows, b.staged_rows into v_expected, v_staged
  from indique_ganhe_influencer.import_batches b
  where b.id = p_batch_id and b.created_by = auth.uid() and b.status = 'staging'
  for update;
  if not found then raise exception 'Importação não encontrada ou já finalizada.'; end if;

  v_added := jsonb_array_length(p_rows);
  if v_staged + v_added > v_expected then
    raise exception 'O lote excedeu a quantidade prevista.';
  end if;

  insert into indique_ganhe_influencer.import_rows (batch_id, payload)
  select p_batch_id, item from jsonb_array_elements(p_rows) item;

  update indique_ganhe_influencer.import_batches
  set staged_rows = staged_rows + v_added
  where id = p_batch_id;

  return v_staged + v_added;
end;
$$;

-- A compact UUID-keyed rollup prevents referral_progress from re-aggregating
-- every historical contribution on each dashboard read. The append-only
-- contributions table remains available for audit/history.
create table if not exists indique_ganhe_influencer.performance_totals (
  uuid uuid primary key,
  route_count bigint not null check (route_count >= 0),
  fallback_name text,
  fallback_region text,
  updated_at timestamptz not null default now()
);

insert into indique_ganhe_influencer.performance_totals (uuid, route_count, fallback_name, fallback_region)
select p.uuid,
  sum(p.route_count)::bigint,
  max(nullif(p.fallback_name, '')),
  max(nullif(p.fallback_region, ''))
from indique_ganhe_influencer.performance_contributions p
group by p.uuid
on conflict (uuid) do update set
  route_count = excluded.route_count,
  fallback_name = excluded.fallback_name,
  fallback_region = excluded.fallback_region,
  updated_at = now();

alter table indique_ganhe_influencer.performance_totals enable row level security;
drop policy if exists performance_totals_owner_or_admin_read on indique_ganhe_influencer.performance_totals;
create policy performance_totals_owner_or_admin_read
on indique_ganhe_influencer.performance_totals
for select to authenticated
using (
  indique_ganhe_influencer.is_admin()
  or exists (
    select 1 from indique_ganhe_influencer.referrals r
    where r.uuid = performance_totals.uuid
      and r.influencer_id = indique_ganhe_influencer.current_influencer_id()
  )
);
revoke all on indique_ganhe_influencer.performance_totals from public, anon;
grant select on indique_ganhe_influencer.performance_totals to authenticated;

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

  -- Keep this exact count as a final integrity check; append_import_rows no
  -- longer recounts the growing batch after every chunk.
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
    delete from indique_ganhe_influencer.referrals;
    insert into indique_ganhe_influencer.referrals
      (uuid, name, region, phone, cpf, phone_unavailable, influencer_id, raw_influencer, source_batch_id)
    select (r.payload->>'uuid')::uuid,
      coalesce(r.payload->>'name', ''), nullif(r.payload->>'region', ''),
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
  set status = 'completed', completed_at = now()
  where id = p_batch_id;
  delete from indique_ganhe_influencer.import_rows where batch_id = p_batch_id;
  return v_result;
end;
$$;

create or replace view indique_ganhe_influencer.referral_progress
with (security_invoker = true) as
select r.uuid as referral_id, r.uuid,
  coalesce(nullif(r.name, ''), t.fallback_name, '') as name,
  coalesce(nullif(r.region, ''), t.fallback_region) as region,
  r.phone, r.cpf,
  coalesce(t.route_count, 0)::bigint as routes,
  i.route_goal, i.prize_cents,
  (coalesce(t.route_count, 0) >= i.route_goal) as prize_unlocked,
  greatest(i.route_goal::bigint - coalesce(t.route_count, 0), 0)::bigint as routes_remaining,
  i.name as influencer_name
from indique_ganhe_influencer.referrals r
join indique_ganhe_influencer.influencers i on i.id = r.influencer_id
left join indique_ganhe_influencer.performance_totals t on t.uuid = r.uuid
where r.influencer_id is not null;

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
        'id', a.id, 'email', a.email, 'influencer_id', a.influencer_id,
        'influencer_name', i.name, 'created_at', a.created_at
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
