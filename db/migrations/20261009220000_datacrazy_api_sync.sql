begin;

-- API snapshots are separate from uploaded files, but share the existing audit log.
alter table indique_ganhe_influencer.import_batches
  alter column created_by drop not null;
alter table indique_ganhe_influencer.import_batches
  add column if not exists source text not null default 'file';
alter table indique_ganhe_influencer.import_batches
  add constraint import_batches_source_check check (source in ('file', 'api'));
alter table indique_ganhe_influencer.import_batches
  add constraint import_batches_api_owner_check check (source <> 'api' or created_by is null);

-- An upload started before deployment must not overwrite a newer API snapshot.
with stopped as (
  update indique_ganhe_influencer.import_batches b
  set status = 'cancelled', finished_at = now(),
    error_message = 'A importação por arquivo foi substituída pela sincronização via API.'
  where b.kind = 'data_crazy' and b.source = 'file' and b.status = 'staging'
  returning b.id, b.created_by
)
insert into indique_ganhe_influencer.import_activity
  (batch_id, actor_id, event_type, message, details)
select s.id, s.created_by, 'cancelled',
  'Importação por arquivo encerrada na migração para a API.',
  '{"source":"file","reason":"api_migration"}'::jsonb
from stopped s;
delete from indique_ganhe_influencer.import_rows r
using indique_ganhe_influencer.import_batches b
where r.batch_id = b.id and b.kind = 'data_crazy' and b.source = 'file'
  and b.status = 'cancelled'
  and b.error_message = 'A importação por arquivo foi substituída pela sincronização via API.';

create table indique_ganhe_influencer.data_crazy_sync_runs (
  id uuid primary key default gen_random_uuid(),
  batch_id uuid not null unique references indique_ganhe_influencer.import_batches(id),
  actor_id uuid references auth.users(id) on delete set null,
  trigger_kind text not null check (trigger_kind in ('manual', 'scheduled')),
  phase text not null default 'businesses'
    check (phase in ('businesses', 'leads', 'ready', 'completed', 'failed')),
  businesses_skip integer not null default 0 check (businesses_skip >= 0),
  leads_skip integer not null default 0 check (leads_skip >= 0),
  business_total integer check (business_total >= 0),
  lead_total integer check (lead_total >= 0),
  businesses_fetched integer not null default 0 check (businesses_fetched >= 0),
  leads_fetched integer not null default 0 check (leads_fetched >= 0),
  lease_token uuid,
  lease_until timestamptz,
  error_message text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  completed_at timestamptz
);
create unique index data_crazy_only_one_active_sync
  on indique_ganhe_influencer.data_crazy_sync_runs ((true))
  where phase in ('businesses', 'leads', 'ready');
create index data_crazy_sync_recent_idx
  on indique_ganhe_influencer.data_crazy_sync_runs (created_at desc);

create table indique_ganhe_influencer.data_crazy_sync_businesses (
  run_id uuid not null references indique_ganhe_influencer.data_crazy_sync_runs(id) on delete cascade,
  business_id text not null,
  lead_id text not null,
  influencer_id text not null references indique_ganhe_influencer.influencers(id),
  primary key (run_id, business_id),
  check (length(business_id) between 1 and 128),
  check (length(lead_id) between 1 and 128)
);
create index data_crazy_sync_business_lead_idx
  on indique_ganhe_influencer.data_crazy_sync_businesses (run_id, lead_id);

create table indique_ganhe_influencer.data_crazy_sync_leads (
  run_id uuid not null references indique_ganhe_influencer.data_crazy_sync_runs(id) on delete cascade,
  lead_id text not null,
  uuid uuid,
  name text not null default '',
  region text,
  released_at date,
  phone text,
  cpf text,
  phone_unavailable boolean not null default false,
  primary key (run_id, lead_id),
  check (length(lead_id) between 1 and 128)
);
create index data_crazy_sync_lead_uuid_idx
  on indique_ganhe_influencer.data_crazy_sync_leads (run_id, uuid)
  where uuid is not null;

alter table indique_ganhe_influencer.data_crazy_sync_runs enable row level security;
alter table indique_ganhe_influencer.data_crazy_sync_businesses enable row level security;
alter table indique_ganhe_influencer.data_crazy_sync_leads enable row level security;
revoke all on indique_ganhe_influencer.data_crazy_sync_runs,
  indique_ganhe_influencer.data_crazy_sync_businesses,
  indique_ganhe_influencer.data_crazy_sync_leads from public, anon, authenticated;
grant usage on schema indique_ganhe_influencer to service_role;
grant select, insert, update, delete on indique_ganhe_influencer.data_crazy_sync_runs,
  indique_ganhe_influencer.data_crazy_sync_businesses,
  indique_ganhe_influencer.data_crazy_sync_leads to service_role;
create policy data_crazy_sync_admin_read
  on indique_ganhe_influencer.data_crazy_sync_runs
  for select to authenticated using (indique_ganhe_influencer.is_admin());
grant select on indique_ganhe_influencer.data_crazy_sync_runs to authenticated;
grant select on indique_ganhe_influencer.import_batches to service_role;

create or replace function indique_ganhe_influencer.start_data_crazy_sync(
  p_trigger text, p_actor_id uuid default null
)
returns jsonb language plpgsql security definer
set search_path = pg_catalog, indique_ganhe_influencer
as $$
declare v_run_id uuid; v_batch_id uuid; v_existing indique_ganhe_influencer.data_crazy_sync_runs%rowtype;
begin
  if p_trigger not in ('manual', 'scheduled') then raise exception 'Origem inválida.'; end if;
  if p_trigger = 'manual' and not exists (
    select 1 from indique_ganhe_influencer.account_members m
    where m.user_id = p_actor_id and m.role = 'admin'
  ) then raise exception 'Apenas um administrador pode iniciar a sincronização.'; end if;
  if p_trigger = 'scheduled' and p_actor_id is not null then raise exception 'Execução agendada não usa conta pessoal.'; end if;
  perform pg_advisory_xact_lock(hashtext('indique_ganhe:dc_sync_start'));
  select * into v_existing from indique_ganhe_influencer.data_crazy_sync_runs r
    where r.phase in ('businesses', 'leads', 'ready') order by r.created_at desc limit 1;
  if found then
    return jsonb_build_object('runId', v_existing.id, 'batchId', v_existing.batch_id,
      'phase', v_existing.phase, 'alreadyRunning', true);
  end if;
  insert into indique_ganhe_influencer.import_batches
    (kind, file_name, file_hash, status, expected_rows, staged_rows, metrics, created_by, source)
  values ('data_crazy', 'Sincronização Data Crazy API', repeat('0', 64), 'staging', 0, 0,
    jsonb_build_object('source', 'api', 'trigger', p_trigger), null, 'api')
  returning id into v_batch_id;
  insert into indique_ganhe_influencer.data_crazy_sync_runs (batch_id, trigger_kind, actor_id)
    values (v_batch_id, p_trigger, p_actor_id) returning id into v_run_id;
  insert into indique_ganhe_influencer.import_activity
    (batch_id, actor_id, event_type, message, details)
  values (v_batch_id, p_actor_id, 'started', 'Sincronização Data Crazy iniciada.',
    jsonb_build_object('source', 'api', 'trigger', p_trigger, 'run_id', v_run_id));
  return jsonb_build_object('runId', v_run_id, 'batchId', v_batch_id,
    'phase', 'businesses', 'alreadyRunning', false);
end;
$$;

create or replace function indique_ganhe_influencer.claim_data_crazy_sync(
  p_run_id uuid default null
)
returns jsonb language plpgsql security definer
set search_path = pg_catalog, indique_ganhe_influencer
as $$
declare v_run indique_ganhe_influencer.data_crazy_sync_runs%rowtype; v_token uuid := gen_random_uuid();
begin
  select * into v_run from indique_ganhe_influencer.data_crazy_sync_runs r
  where (p_run_id is null or r.id = p_run_id)
    and r.phase in ('businesses', 'leads', 'ready')
    and (r.lease_until is null or r.lease_until <= now())
  order by r.created_at limit 1 for update skip locked;
  if not found then return null; end if;
  update indique_ganhe_influencer.data_crazy_sync_runs
    set lease_token = v_token, lease_until = now() + interval '110 seconds', updated_at = now()
    where id = v_run.id;
  return jsonb_build_object('runId', v_run.id, 'batchId', v_run.batch_id,
    'leaseToken', v_token, 'phase', v_run.phase, 'businessesSkip', v_run.businesses_skip,
    'leadsSkip', v_run.leads_skip, 'businessTotal', v_run.business_total,
    'leadTotal', v_run.lead_total);
end;
$$;

create or replace function indique_ganhe_influencer.append_data_crazy_sync_page(
  p_run_id uuid, p_lease_token uuid, p_phase text, p_cursor integer,
  p_rows jsonb, p_next_cursor integer, p_total integer, p_done boolean
)
returns jsonb language plpgsql security definer
set search_path = pg_catalog, indique_ganhe_influencer
as $$
declare v_run indique_ganhe_influencer.data_crazy_sync_runs%rowtype;
  v_rows integer; v_expected_cursor integer; v_actor uuid;
begin
  if p_phase not in ('businesses', 'leads') or p_cursor is null or p_cursor < 0
    or p_next_cursor is null or p_next_cursor < p_cursor
    or (p_total is not null and p_total < 0) or p_done is null
    or jsonb_typeof(p_rows) is distinct from 'array' then raise exception 'Página Data Crazy inválida.'; end if;
  v_rows := jsonb_array_length(p_rows);
  if v_rows > 300 or p_next_cursor - p_cursor > 300
    or (p_next_cursor = p_cursor and not p_done)
    or v_rows > p_next_cursor - p_cursor then raise exception 'Tamanho da página inválido.'; end if;
  select * into v_run from indique_ganhe_influencer.data_crazy_sync_runs r
    where r.id = p_run_id for update;
  if not found or v_run.phase <> p_phase or v_run.lease_token is distinct from p_lease_token
    or v_run.lease_until <= now() then raise exception 'Execução ou autorização expirada.'; end if;
  v_expected_cursor := case when p_phase = 'businesses' then v_run.businesses_skip else v_run.leads_skip end;
  if p_cursor <> v_expected_cursor then raise exception 'Página fora de ordem.'; end if;
  if p_total is not null and p_next_cursor > p_total then raise exception 'Página excedeu o total informado.'; end if;
  if p_done and (p_total is null or p_next_cursor <> p_total) then
    raise exception 'Coleta declarada completa antes do total.'; end if;
  if p_phase = 'businesses' then
    if exists (select 1 from jsonb_array_elements(p_rows) x
      where nullif(btrim(x->>'businessId'), '') is null or nullif(btrim(x->>'leadId'), '') is null
      or not exists (select 1 from indique_ganhe_influencer.influencers i
        where i.id = x->>'influencerId' and not i.is_demo)) then
      raise exception 'Negócio sem lead ou pipeline conhecida.';
    end if;
    insert into indique_ganhe_influencer.data_crazy_sync_businesses
      (run_id, business_id, lead_id, influencer_id)
    select p_run_id, x->>'businessId', x->>'leadId', x->>'influencerId'
      from jsonb_array_elements(p_rows) x
    on conflict (run_id, business_id) do update set
      lead_id = excluded.lead_id, influencer_id = excluded.influencer_id;
    update indique_ganhe_influencer.data_crazy_sync_runs
      set businesses_skip = p_next_cursor,
        businesses_fetched = businesses_fetched + (p_next_cursor - p_cursor),
        business_total = coalesce(p_total, business_total), phase = case when p_done then 'leads' else phase end,
        updated_at = now(), lease_until = now() + interval '110 seconds'
      where id = p_run_id;
  else
    if exists (select 1 from jsonb_array_elements(p_rows) x
      where nullif(btrim(x->>'leadId'), '') is null
        or (nullif(x->>'uuid', '') is not null and
          (x->>'uuid') !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$')
        or (nullif(x->>'releasedAt', '') is not null and
          (x->>'releasedAt') !~ '^\d{4}-\d{2}-\d{2}$')) then
      raise exception 'Lead com ID, UUID ou data inválida.';
    end if;
    insert into indique_ganhe_influencer.data_crazy_sync_leads
      (run_id, lead_id, uuid, name, region, released_at, phone, cpf, phone_unavailable)
    select p_run_id, x->>'leadId', nullif(x->>'uuid', '')::uuid,
      left(coalesce(x->>'name', ''), 500), nullif(left(coalesce(x->>'region', ''), 300), ''),
      nullif(x->>'releasedAt', '')::date,
      nullif(left(coalesce(x->>'phone', ''), 30), ''),
      case when coalesce(x->>'cpf', '') ~ '^[0-9]{11}$' then x->>'cpf' else null end,
      coalesce((x->>'phoneUnavailable')::boolean, false)
    from jsonb_array_elements(p_rows) x
    on conflict (run_id, lead_id) do update set
      uuid = excluded.uuid, name = excluded.name, region = excluded.region,
      released_at = excluded.released_at, phone = excluded.phone,
      cpf = excluded.cpf, phone_unavailable = excluded.phone_unavailable;
    update indique_ganhe_influencer.data_crazy_sync_runs
      set leads_skip = p_next_cursor,
        leads_fetched = leads_fetched + (p_next_cursor - p_cursor),
        lead_total = coalesce(p_total, lead_total), phase = case when p_done then 'ready' else phase end,
        updated_at = now(), lease_until = now() + interval '110 seconds'
      where id = p_run_id;
  end if;
  v_actor := v_run.actor_id;
  insert into indique_ganhe_influencer.import_activity
    (batch_id, actor_id, event_type, message, details)
  values (v_run.batch_id, v_actor, 'progress',
    format('Data Crazy: %s, %s registros de origem percorridos.',
      case when p_phase = 'businesses' then 'negócios' else 'leads' end, p_next_cursor),
    jsonb_build_object('phase', p_phase, 'source_received', p_next_cursor,
      'staged_rows', v_rows, 'total', p_total));
  return jsonb_build_object('runId', p_run_id,
    'phase', case when p_done then (case when p_phase = 'businesses' then 'leads' else 'ready' end) else p_phase end,
    'cursor', p_next_cursor, 'total', p_total);
end;
$$;

create or replace function indique_ganhe_influencer.publish_data_crazy_sync(
  p_run_id uuid, p_lease_token uuid
)
returns jsonb language plpgsql security definer
set search_path = pg_catalog, indique_ganhe_influencer
as $$
declare v_run indique_ganhe_influencer.data_crazy_sync_runs%rowtype;
  v_count integer; v_ambiguous integer; v_missing integer; v_actor uuid;
begin
  select * into v_run from indique_ganhe_influencer.data_crazy_sync_runs r
    where r.id = p_run_id for update;
  if not found or v_run.phase <> 'ready' or v_run.lease_token is distinct from p_lease_token
    or v_run.lease_until <= now() then raise exception 'Execução não está pronta ou autorização expirada.'; end if;
  if v_run.business_total is null or v_run.lead_total is null
    or v_run.businesses_fetched <> v_run.business_total
    or v_run.leads_fetched <> v_run.lead_total then
    raise exception 'Coleta incompleta. Lista atual preservada.';
  end if;
  perform pg_advisory_xact_lock(hashtext('indique_ganhe:data_crazy'));
  create temporary table dc_sync_candidates on commit drop as
    select l.uuid, l.name, l.region, l.released_at, l.phone, l.cpf,
      l.phone_unavailable, l.lead_id, b.influencer_id, b.business_id
    from indique_ganhe_influencer.data_crazy_sync_leads l
    join indique_ganhe_influencer.data_crazy_sync_businesses b
      on b.run_id = l.run_id and b.lead_id = l.lead_id
    where l.run_id = p_run_id and l.uuid is not null;
  create temporary table dc_sync_assignments on commit drop as
    select c.uuid, count(distinct c.influencer_id) as influencer_count,
      min(c.influencer_id) as influencer_id,
      string_agg(distinct i.name, ', ' order by i.name) as raw_influencer
    from dc_sync_candidates c
    join indique_ganhe_influencer.influencers i on i.id = c.influencer_id
    group by c.uuid;
  select count(*) into v_count from dc_sync_assignments;
  if v_count < 1 then raise exception 'A API não retornou indicados com UUID válido. Lista atual preservada.'; end if;
  if (select count(*) from indique_ganhe_influencer.referrals) >= 20
    and v_count < (select count(*)::numeric * 0.2 from indique_ganhe_influencer.referrals) then
    raise exception 'A coleta reduziu a lista em mais de 80%%. Lista atual preservada para revisão.';
  end if;
  select count(*) into v_ambiguous from dc_sync_assignments where influencer_count > 1;
  select greatest(v_run.leads_fetched - count(*)::integer, 0) into v_missing
    from indique_ganhe_influencer.data_crazy_sync_leads l where l.run_id = p_run_id;

  update indique_ganhe_influencer.attribution_reviews set status = 'superseded' where status = 'open';
  delete from indique_ganhe_influencer.referrals where uuid is not null;
  insert into indique_ganhe_influencer.referrals
    (uuid, name, region, released_at, phone, cpf, phone_unavailable,
      influencer_id, raw_influencer, source_batch_id)
  select distinct on (c.uuid) c.uuid, c.name, c.region, c.released_at,
    c.phone, c.cpf, c.phone_unavailable,
    case when a.influencer_count = 1 then a.influencer_id else null end,
    a.raw_influencer, v_run.batch_id
  from dc_sync_candidates c join dc_sync_assignments a on a.uuid = c.uuid
  order by c.uuid, c.released_at desc nulls last, c.business_id desc, c.lead_id desc;
  insert into indique_ganhe_influencer.attribution_reviews
    (batch_id, uuid, name, region, raw_influencer)
  select v_run.batch_id, r.uuid, r.name, r.region, r.raw_influencer
  from indique_ganhe_influencer.referrals r
  join dc_sync_assignments a on a.uuid = r.uuid
  where r.source_batch_id = v_run.batch_id and a.influencer_count > 1;

  update indique_ganhe_influencer.import_batches
    set status = 'completed', completed_at = now(), finished_at = now(),
      expected_rows = v_count, staged_rows = v_count,
      metrics = metrics || jsonb_build_object('businesses', v_run.businesses_fetched,
        'leads', v_run.leads_fetched, 'referrals', v_count,
        'ambiguous', v_ambiguous, 'invalid_uuid', v_missing),
      error_message = null
    where id = v_run.batch_id;
  v_actor := v_run.actor_id;
  update indique_ganhe_influencer.data_crazy_sync_runs
    set phase = 'completed', completed_at = now(), updated_at = now(),
      lease_token = null, lease_until = null where id = p_run_id;
  insert into indique_ganhe_influencer.import_activity
    (batch_id, actor_id, event_type, message, details)
  values (v_run.batch_id, v_actor, 'completed',
    'Data Crazy API substituiu a lista atual com sucesso.',
    jsonb_build_object('referrals', v_count, 'ambiguous', v_ambiguous,
      'invalid_uuid', v_missing, 'businesses', v_run.businesses_fetched,
      'leads', v_run.leads_fetched));
  delete from indique_ganhe_influencer.data_crazy_sync_businesses where run_id = p_run_id;
  delete from indique_ganhe_influencer.data_crazy_sync_leads where run_id = p_run_id;
  return jsonb_build_object('imported', v_count, 'ambiguous', v_ambiguous,
    'invalidUuid', v_missing, 'kind', 'data_crazy');
end;
$$;

create or replace function indique_ganhe_influencer.fail_data_crazy_sync(
  p_run_id uuid, p_lease_token uuid, p_message text
)
returns boolean language plpgsql security definer
set search_path = pg_catalog, indique_ganhe_influencer
as $$
declare v_run indique_ganhe_influencer.data_crazy_sync_runs%rowtype;
  v_actor uuid; v_message text;
begin
  select * into v_run from indique_ganhe_influencer.data_crazy_sync_runs r
    where r.id = p_run_id for update;
  if not found or v_run.phase in ('completed', 'failed') then return false; end if;
  if v_run.lease_token is distinct from p_lease_token then raise exception 'Autorização inválida.'; end if;
  v_message := left(regexp_replace(coalesce(nullif(btrim(p_message), ''),
    'Falha na sincronização Data Crazy.'), '[[:cntrl:]]', ' ', 'g'), 1000);
  update indique_ganhe_influencer.data_crazy_sync_runs
    set phase = 'failed', error_message = v_message, completed_at = now(),
      updated_at = now(), lease_token = null, lease_until = null where id = p_run_id;
  update indique_ganhe_influencer.import_batches
    set status = 'failed', finished_at = now(), error_message = v_message,
      expected_rows = greatest(coalesce(v_run.business_total, 0), coalesce(v_run.lead_total, 0)),
      staged_rows = greatest(v_run.businesses_fetched, v_run.leads_fetched)
    where id = v_run.batch_id;
  v_actor := v_run.actor_id;
  insert into indique_ganhe_influencer.import_activity
    (batch_id, actor_id, event_type, message, details)
  values (v_run.batch_id, v_actor, 'failed', v_message,
    jsonb_build_object('phase', v_run.phase, 'businesses_received', v_run.businesses_fetched,
      'leads_received', v_run.leads_fetched));
  delete from indique_ganhe_influencer.data_crazy_sync_businesses where run_id = p_run_id;
  delete from indique_ganhe_influencer.data_crazy_sync_leads where run_id = p_run_id;
  return true;
end;
$$;

create or replace function indique_ganhe_influencer.defer_data_crazy_sync(
  p_run_id uuid, p_lease_token uuid, p_delay_seconds integer
)
returns boolean language plpgsql security definer
set search_path = pg_catalog, indique_ganhe_influencer
as $$
declare v_run indique_ganhe_influencer.data_crazy_sync_runs%rowtype;
  v_delay integer := greatest(1, least(coalesce(p_delay_seconds, 60), 3600));
begin
  select * into v_run from indique_ganhe_influencer.data_crazy_sync_runs r
    where r.id = p_run_id and r.phase in ('businesses', 'leads', 'ready')
      and r.lease_token = p_lease_token for update;
  if not found then raise exception 'Execução ou autorização inválida.'; end if;
  update indique_ganhe_influencer.data_crazy_sync_runs
    set lease_token = null,
      lease_until = now() + make_interval(secs => v_delay),
      updated_at = now()
    where id = p_run_id;
  insert into indique_ganhe_influencer.import_activity
    (batch_id, actor_id, event_type, message, details)
  values (v_run.batch_id, v_run.actor_id, 'progress',
    'API Data Crazy indisponível ou limitada; retomada agendada.',
    jsonb_build_object('phase', v_run.phase, 'retry_after_seconds', v_delay));
  return true;
end;
$$;

create or replace function indique_ganhe_influencer.get_data_crazy_sync_status(
  p_run_id uuid default null
)
returns jsonb language plpgsql stable security invoker
set search_path = pg_catalog, indique_ganhe_influencer
as $$
declare v_status jsonb;
begin
  if current_user <> 'service_role' then
    if not indique_ganhe_influencer.is_admin() then
      raise exception 'Apenas a administração pode consultar a sincronização.';
    end if;
  end if;
  select jsonb_build_object('id', r.id, 'status',
    case when r.phase in ('businesses', 'leads', 'ready') then 'running' else r.phase end,
    'phase', r.phase,
    'processed', case when r.phase = 'businesses' then r.businesses_fetched else r.leads_fetched end,
    'total', case when r.phase = 'businesses' then r.business_total else r.lead_total end,
    'metrics', b.metrics || jsonb_build_object('businessesReceived', r.businesses_fetched,
      'leadsReceived', r.leads_fetched), 'errorMessage', coalesce(r.error_message, b.error_message),
    'startedAt', r.created_at, 'completedAt', r.completed_at)
  into v_status
  from indique_ganhe_influencer.data_crazy_sync_runs r
  join indique_ganhe_influencer.import_batches b on b.id = r.batch_id
  where p_run_id is null or r.id = p_run_id
  order by r.created_at desc limit 1;
  return v_status;
end;
$$;

-- Keep the historic e-mail field for existing clients and add a display label.
-- New Data Crazy snapshots may only arrive through the server-side API worker.
create or replace function indique_ganhe_influencer.start_import(
  p_kind text, p_file_name text, p_file_hash text, p_metrics jsonb, p_total_rows integer
)
returns jsonb language plpgsql security definer
set search_path = pg_catalog, indique_ganhe_influencer
as $$
declare v_id uuid; v_duplicate boolean; v_metrics jsonb := coalesce(p_metrics, '{}'::jsonb);
begin
  if not indique_ganhe_influencer.is_admin() then raise exception 'Apenas a administração pode importar arquivos.'; end if;
  if p_kind <> 'performance' then raise exception 'Data Crazy agora é sincronizado pela API.'; end if;
  if p_total_rows is null or p_total_rows < 1 or p_total_rows > 100000 then
    raise exception 'Quantidade de registros inválida.'; end if;
  if p_file_hash !~ '^[0-9a-f]{64}$' then raise exception 'Hash do arquivo inválido.'; end if;
  select exists (select 1 from indique_ganhe_influencer.import_batches b
    where b.kind = 'performance' and b.file_hash = p_file_hash and b.status = 'completed') into v_duplicate;
  insert into indique_ganhe_influencer.import_batches
    (kind, file_name, file_hash, metrics, expected_rows, created_by, source)
  values ('performance', left(coalesce(p_file_name, 'arquivo'), 255), p_file_hash,
    v_metrics, p_total_rows, auth.uid(), 'file') returning id into v_id;
  insert into indique_ganhe_influencer.import_activity
    (batch_id, actor_id, event_type, message, details)
  values (v_id, auth.uid(), 'started', 'Importação de Performance iniciada.',
    jsonb_build_object('expected_rows', p_total_rows, 'metrics', v_metrics,
      'duplicate_file', v_duplicate));
  return jsonb_build_object('batchId', v_id, 'duplicateFile', v_duplicate);
end;
$$;

create or replace function indique_ganhe_influencer.list_import_history(
  p_limit integer default 25, p_offset integer default 0,
  p_status text default 'all', p_kind text default 'all'
)
returns jsonb language plpgsql stable security definer
set search_path = pg_catalog, indique_ganhe_influencer
as $$
declare v_status text := coalesce(nullif(p_status, ''), 'all');
  v_kind text := coalesce(nullif(p_kind, ''), 'all');
begin
  if not indique_ganhe_influencer.is_admin() then raise exception 'Apenas a administração pode consultar o histórico.'; end if;
  if p_limit is null or p_limit < 1 or p_limit > 100 or p_offset is null or p_offset < 0 then
    raise exception 'Página solicitada inválida.'; end if;
  if v_status not in ('all', 'staging', 'completed', 'failed', 'cancelled') then raise exception 'Filtro de status inválido.'; end if;
  if v_kind not in ('all', 'data_crazy', 'performance') then raise exception 'Filtro de tipo inválido.'; end if;
  return (
    with filtered as (
      select b.id, b.kind, b.file_name, left(b.file_hash, 12) as file_hash_prefix,
        b.status, b.source, b.metrics, b.expected_rows, b.staged_rows, b.created_at,
        b.completed_at, b.finished_at, b.error_message,
        case when coalesce(r.actor_id, b.created_by) is null and b.source = 'api' then 'Sistema'
          else coalesce(m.email, 'Conta sem vínculo') end as actor_email,
        case when coalesce(r.actor_id, b.created_by) is null and b.source = 'api' then 'Sistema'
          else coalesce(nullif(btrim(m.display_name), ''), m.email, 'Conta sem vínculo') end as actor_display_name,
        greatest(0, extract(epoch from (coalesce(b.finished_at, b.completed_at, now()) - b.created_at))::integer) as duration_seconds,
        last_event.message as last_event_message
      from indique_ganhe_influencer.import_batches b
      left join indique_ganhe_influencer.data_crazy_sync_runs r on r.batch_id = b.id
      left join indique_ganhe_influencer.account_members m on m.user_id = coalesce(r.actor_id, b.created_by)
      left join lateral (
        select e.message from indique_ganhe_influencer.import_activity e
        where e.batch_id = b.id order by e.created_at desc, e.id desc limit 1
      ) last_event on true
      where (v_status = 'all' or b.status = v_status) and (v_kind = 'all' or b.kind = v_kind)
    ), paged as (
      select * from filtered order by created_at desc, id desc limit p_limit offset p_offset
    )
    select jsonb_build_object(
      'items', coalesce((select jsonb_agg(to_jsonb(p) order by p.created_at desc, p.id desc) from paged p), '[]'::jsonb),
      'total', (select count(*) from filtered),
      'summary', (select jsonb_build_object('total', count(*),
        'staging', count(*) filter (where b.status = 'staging'),
        'completed', count(*) filter (where b.status = 'completed'),
        'failed', count(*) filter (where b.status = 'failed'),
        'cancelled', count(*) filter (where b.status = 'cancelled'))
        from indique_ganhe_influencer.import_batches b)
    )
  );
end;
$$;

create or replace function indique_ganhe_influencer.list_import_events(p_batch_id uuid)
returns jsonb language plpgsql stable security definer
set search_path = pg_catalog, indique_ganhe_influencer
as $$
declare v_events jsonb;
begin
  if not indique_ganhe_influencer.is_admin() then raise exception 'Apenas a administração pode consultar o histórico.'; end if;
  if not exists (select 1 from indique_ganhe_influencer.import_batches b where b.id = p_batch_id) then
    raise exception 'Importação não encontrada.'; end if;
  select coalesce(jsonb_agg(jsonb_build_object(
    'id', e.id, 'event_type', e.event_type, 'message', e.message,
    'details', e.details, 'created_at', e.created_at,
    'actor_email', case when e.actor_id is null and b.source = 'api' then 'Sistema'
      else coalesce(m.email, 'Conta sem vínculo') end,
    'actor_display_name', case when e.actor_id is null and b.source = 'api' then 'Sistema'
      else coalesce(nullif(btrim(m.display_name), ''), m.email, 'Conta sem vínculo') end
  ) order by e.created_at, e.id), '[]'::jsonb)
  into v_events
  from indique_ganhe_influencer.import_activity e
  join indique_ganhe_influencer.import_batches b on b.id = e.batch_id
  left join indique_ganhe_influencer.account_members m on m.user_id = e.actor_id
  where e.batch_id = p_batch_id;
  return v_events;
end;
$$;

revoke execute on function indique_ganhe_influencer.start_data_crazy_sync(text, uuid),
  indique_ganhe_influencer.claim_data_crazy_sync(uuid),
  indique_ganhe_influencer.append_data_crazy_sync_page(uuid, uuid, text, integer, jsonb, integer, integer, boolean),
  indique_ganhe_influencer.publish_data_crazy_sync(uuid, uuid),
  indique_ganhe_influencer.fail_data_crazy_sync(uuid, uuid, text),
  indique_ganhe_influencer.defer_data_crazy_sync(uuid, uuid, integer),
  indique_ganhe_influencer.get_data_crazy_sync_status(uuid)
  from public, anon, authenticated;
grant execute on function indique_ganhe_influencer.start_data_crazy_sync(text, uuid),
  indique_ganhe_influencer.claim_data_crazy_sync(uuid),
  indique_ganhe_influencer.append_data_crazy_sync_page(uuid, uuid, text, integer, jsonb, integer, integer, boolean),
  indique_ganhe_influencer.publish_data_crazy_sync(uuid, uuid),
  indique_ganhe_influencer.fail_data_crazy_sync(uuid, uuid, text),
  indique_ganhe_influencer.defer_data_crazy_sync(uuid, uuid, integer),
  indique_ganhe_influencer.get_data_crazy_sync_status(uuid) to service_role;
grant execute on function indique_ganhe_influencer.get_data_crazy_sync_status(uuid) to authenticated;

notify pgrst, 'reload schema';
commit;
