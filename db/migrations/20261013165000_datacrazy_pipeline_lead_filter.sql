begin;

alter table indique_ganhe_influencer.data_crazy_sync_runs
  add column lead_stage_ids text[] not null default '{}'::text[],
  add column lead_filter_fallback boolean not null default false;

create or replace function indique_ganhe_influencer.claim_data_crazy_sync(
  p_run_id uuid default null
)
returns jsonb language plpgsql security definer
set search_path = pg_catalog, indique_ganhe_influencer
as $$
declare
  v_run indique_ganhe_influencer.data_crazy_sync_runs%rowtype;
  v_token uuid := gen_random_uuid();
begin
  select * into v_run
  from indique_ganhe_influencer.data_crazy_sync_runs r
  where (p_run_id is null or r.id = p_run_id)
    and r.phase in ('businesses', 'leads', 'ready')
    and (r.lease_until is null or r.lease_until <= now())
  order by r.created_at
  limit 1
  for update skip locked;

  if not found then
    return null;
  end if;

  update indique_ganhe_influencer.data_crazy_sync_runs
  set lease_token = v_token, lease_until = now() + interval '110 seconds', updated_at = now()
  where id = v_run.id;

  return jsonb_build_object(
    'runId', v_run.id,
    'batchId', v_run.batch_id,
    'leaseToken', v_token,
    'phase', v_run.phase,
    'businessesSkip', v_run.businesses_skip,
    'leadsSkip', v_run.leads_skip,
    'businessMonth', v_run.business_month,
    'leadMonth', v_run.lead_month,
    'snapshotUntil', v_run.snapshot_until,
    'businessTotal', v_run.business_total,
    'leadTotal', v_run.lead_total,
    'leadStageIds', to_jsonb(coalesce(v_run.lead_stage_ids, '{}'::text[])),
    'leadFilterFallback', v_run.lead_filter_fallback
  );
end;
$$;

create or replace function indique_ganhe_influencer.record_data_crazy_sync_stages(
  p_run_id uuid,
  p_lease_token uuid,
  p_stage_ids jsonb,
  p_force_full_scan boolean
)
returns jsonb language plpgsql security definer
set search_path = pg_catalog, indique_ganhe_influencer
as $$
declare
  v_run indique_ganhe_influencer.data_crazy_sync_runs%rowtype;
  v_new_ids text[];
begin
  if jsonb_typeof(p_stage_ids) is distinct from 'array'
    or jsonb_array_length(p_stage_ids) > 300
    or p_force_full_scan is null
    or exists (
      select 1
      from jsonb_array_elements_text(p_stage_ids) as input(stage_id)
      where stage_id !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
    ) then
    raise exception 'Etapas da Data Crazy inválidas.';
  end if;

  select * into v_run
  from indique_ganhe_influencer.data_crazy_sync_runs r
  where r.id = p_run_id
  for update;

  if not found or v_run.phase not in ('businesses', 'leads')
    or v_run.lease_token is distinct from p_lease_token
    or v_run.lease_until <= now() then
    raise exception 'Execução ou autorização expirada.';
  end if;

  select coalesce(array_agg(distinct stage_id order by stage_id), '{}'::text[])
  into v_new_ids
  from jsonb_array_elements_text(p_stage_ids) as input(stage_id);

  update indique_ganhe_influencer.data_crazy_sync_runs
  set lead_stage_ids = array(
        select distinct stage_id
        from unnest(coalesce(v_run.lead_stage_ids, '{}'::text[]) || v_new_ids) as stages(stage_id)
        order by stage_id
      ),
      lead_filter_fallback = v_run.lead_filter_fallback or p_force_full_scan,
      updated_at = now()
  where id = p_run_id
  returning * into v_run;

  return jsonb_build_object(
    'leadStageIds', to_jsonb(coalesce(v_run.lead_stage_ids, '{}'::text[])),
    'leadFilterFallback', v_run.lead_filter_fallback
  );
end;
$$;

create or replace function indique_ganhe_influencer.fallback_data_crazy_lead_filter(
  p_run_id uuid,
  p_lease_token uuid,
  p_reason text
)
returns jsonb language plpgsql security definer
set search_path = pg_catalog, indique_ganhe_influencer
as $$
declare
  v_run indique_ganhe_influencer.data_crazy_sync_runs%rowtype;
  v_missing bigint := 0;
begin
  if p_reason not in ('filter_error', 'coverage_check') then
    raise exception 'Motivo de retomada inválido.';
  end if;

  select * into v_run
  from indique_ganhe_influencer.data_crazy_sync_runs r
  where r.id = p_run_id
  for update;

  if not found
    or v_run.lease_token is distinct from p_lease_token
    or v_run.lease_until <= now()
    or (p_reason = 'filter_error' and v_run.phase <> 'leads')
    or (p_reason = 'coverage_check' and v_run.phase <> 'ready') then
    raise exception 'Execução ou autorização expirada.';
  end if;

  if p_reason = 'coverage_check'
    and (v_run.lead_filter_fallback or cardinality(coalesce(v_run.lead_stage_ids, '{}'::text[])) = 0) then
    return jsonb_build_object('phase', 'ready', 'fallback', v_run.lead_filter_fallback);
  end if;

  if p_reason = 'coverage_check' then
    select count(distinct b.lead_id)
    into v_missing
    from indique_ganhe_influencer.data_crazy_sync_businesses b
    left join indique_ganhe_influencer.data_crazy_sync_leads l
      on l.run_id = b.run_id and l.lead_id = b.lead_id
    where b.run_id = p_run_id and l.lead_id is null;

    if v_missing = 0 then
      return jsonb_build_object('phase', 'ready', 'fallback', false);
    end if;
  end if;

  delete from indique_ganhe_influencer.data_crazy_sync_leads
  where run_id = p_run_id;

  update indique_ganhe_influencer.data_crazy_sync_runs
  set phase = 'leads',
      leads_skip = 0,
      lead_total = null,
      leads_fetched = 0,
      lead_month = date '2026-01-01',
      lead_filter_fallback = true,
      lease_until = now() + interval '110 seconds',
      updated_at = now()
  where id = p_run_id;

  insert into indique_ganhe_influencer.import_activity
    (batch_id, actor_id, event_type, message, details)
  values (
    v_run.batch_id,
    v_run.actor_id,
    'progress',
    case when p_reason = 'filter_error'
      then 'O filtro de etapas da Data Crazy não foi aceito; a consulta completa de leads será usada.'
      else 'O filtro de etapas não retornou todos os leads vinculados; a consulta completa será usada para preservar a lista.'
    end,
    jsonb_build_object(
      'phase', 'leads',
      'fallback', true,
      'reason', p_reason,
      'missing_leads', v_missing,
      'stage_count', cardinality(coalesce(v_run.lead_stage_ids, '{}'::text[]))
    )
  );

  return jsonb_build_object('phase', 'leads', 'fallback', true, 'missingLeads', v_missing);
end;
$$;

revoke all on function indique_ganhe_influencer.record_data_crazy_sync_stages(uuid, uuid, jsonb, boolean)
  from public, anon, authenticated;
revoke all on function indique_ganhe_influencer.fallback_data_crazy_lead_filter(uuid, uuid, text)
  from public, anon, authenticated;
grant execute on function indique_ganhe_influencer.record_data_crazy_sync_stages(uuid, uuid, jsonb, boolean)
  to service_role;
grant execute on function indique_ganhe_influencer.fallback_data_crazy_lead_filter(uuid, uuid, text)
  to service_role;
grant execute on function indique_ganhe_influencer.claim_data_crazy_sync(uuid)
  to service_role;

notify pgrst, 'reload schema';
commit;