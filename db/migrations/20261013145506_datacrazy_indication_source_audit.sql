begin;

-- Keep the source pipeline and the lead's own indication as separate audit
-- signals so publication can compare them instead of silently trusting one.
alter table indique_ganhe_influencer.data_crazy_sync_businesses
  alter column influencer_id drop not null,
  add column if not exists pipeline_name text not null default '';

alter table indique_ganhe_influencer.data_crazy_sync_leads
  add column if not exists indication_raw text not null default '',
  add column if not exists indication_influencer_id text
    references indique_ganhe_influencer.influencers(id),
  add column if not exists indication_status text not null default 'empty';

alter table indique_ganhe_influencer.data_crazy_sync_leads
  add constraint data_crazy_sync_leads_indication_status_check
    check (indication_status in ('empty', 'matched', 'ignored', 'unknown')),
  add constraint data_crazy_sync_leads_indication_match_check
    check ((indication_status = 'matched') = (indication_influencer_id is not null));

create or replace function indique_ganhe_influencer.append_data_crazy_sync_page(
  p_run_id uuid, p_lease_token uuid, p_phase text, p_cursor integer,
  p_rows jsonb, p_next_cursor integer, p_total integer, p_done boolean
)
returns jsonb language plpgsql security definer
set search_path = pg_catalog, indique_ganhe_influencer
as $$
declare
  v_run indique_ganhe_influencer.data_crazy_sync_runs%rowtype;
  v_rows integer;
  v_expected_cursor integer;
  v_actor uuid;
  v_month date;
  v_last_month date;
  v_delta integer;
  v_new_phase text;
  v_new_cursor integer;
  v_indication_total integer := 0;
  v_indication_matched integer := 0;
begin
  if p_phase not in ('businesses', 'leads') or p_cursor is null or p_cursor < 0
    or p_next_cursor is null or p_next_cursor < p_cursor
    or (p_total is not null and p_total < 0) or p_done is null
    or jsonb_typeof(p_rows) is distinct from 'array' then
    raise exception 'Página Data Crazy inválida.';
  end if;
  v_rows := jsonb_array_length(p_rows);
  v_delta := p_next_cursor - p_cursor;
  if v_rows > 300 or v_delta > 300 or (v_delta = 0 and not p_done)
    or v_rows > v_delta then
    raise exception 'Tamanho da página inválido.';
  end if;
  if p_next_cursor >= 10000 and not p_done then
    raise exception 'A página mensal atingiu o limite da API. Lista atual preservada.';
  end if;
  if p_total is not null and p_next_cursor > p_total then
    raise exception 'Página excedeu o total informado.';
  end if;
  if p_done and (p_total is null or p_next_cursor <> p_total) then
    raise exception 'Coleta declarada completa antes do total.';
  end if;

  select * into v_run
    from indique_ganhe_influencer.data_crazy_sync_runs r
    where r.id = p_run_id for update;
  if not found or v_run.phase <> p_phase
    or v_run.lease_token is distinct from p_lease_token
    or v_run.lease_until <= now() then
    raise exception 'Execução ou autorização expirada.';
  end if;

  v_expected_cursor := case when p_phase = 'businesses'
    then v_run.businesses_skip else v_run.leads_skip end;
  v_month := case when p_phase = 'businesses'
    then v_run.business_month else v_run.lead_month end;
  v_last_month := date_trunc('month', v_run.snapshot_until at time zone 'UTC')::date;
  if p_cursor <> v_expected_cursor or v_month > v_last_month then
    raise exception 'Página fora de ordem.';
  end if;
  v_new_cursor := case when p_done then 0 else p_next_cursor end;
  v_new_phase := case when p_done and v_month >= v_last_month
    then case when p_phase = 'businesses' then 'leads' else 'ready' end
    else p_phase end;

  if p_phase = 'businesses' then
    if exists (
      select 1 from jsonb_array_elements(p_rows) x
      where nullif(btrim(x->>'businessId'), '') is null
        or nullif(btrim(x->>'leadId'), '') is null
        or (nullif(x->>'influencerId', '') is not null and not exists (
          select 1 from indique_ganhe_influencer.influencers i
          where i.id = x->>'influencerId' and not i.is_demo
        ))
    ) then raise exception 'Negócio Data Crazy inválido.'; end if;

    insert into indique_ganhe_influencer.data_crazy_sync_businesses
      (run_id, business_id, lead_id, influencer_id, pipeline_name)
    select p_run_id, x->>'businessId', x->>'leadId',
      nullif(x->>'influencerId', ''), left(coalesce(x->>'pipelineName', ''), 300)
    from jsonb_array_elements(p_rows) x
    on conflict (run_id, business_id) do update set
      lead_id = excluded.lead_id,
      influencer_id = excluded.influencer_id,
      pipeline_name = excluded.pipeline_name;

    update indique_ganhe_influencer.data_crazy_sync_runs
    set businesses_skip = v_new_cursor,
      businesses_fetched = businesses_fetched + v_delta,
      business_month = case when p_done and v_month < v_last_month
        then (v_month + interval '1 month')::date else v_month end,
      business_total = case when v_new_phase = 'leads'
        then businesses_fetched + v_delta else null end,
      phase = v_new_phase, updated_at = now(), lease_until = now() + interval '110 seconds'
    where id = p_run_id;
  else
    if exists (
      select 1 from jsonb_array_elements(p_rows) x
      where nullif(btrim(x->>'leadId'), '') is null
        or (nullif(x->>'uuid', '') is not null and
          (x->>'uuid') !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$')
        or (nullif(x->>'releasedAt', '') is not null and
          (x->>'releasedAt') !~ '^\d{4}-\d{2}-\d{2}$')
        or coalesce(x->>'indicationStatus', '') not in ('empty', 'matched', 'ignored', 'unknown')
        or (coalesce(x->>'indicationStatus', '') = 'matched'
          and nullif(x->>'indicationInfluencerId', '') is null)
        or (coalesce(x->>'indicationStatus', '') <> 'matched'
          and nullif(x->>'indicationInfluencerId', '') is not null)
        or (nullif(x->>'indicationInfluencerId', '') is not null and not exists (
          select 1 from indique_ganhe_influencer.influencers i
          where i.id = x->>'indicationInfluencerId' and not i.is_demo
        ))
    ) then raise exception 'Lead com ID, UUID, indicação ou data inválida.'; end if;

    select count(*) filter (where nullif(x->>'indicationRaw', '') is not null),
      count(*) filter (where x->>'indicationStatus' = 'matched')
    into v_indication_total, v_indication_matched
    from jsonb_array_elements(p_rows) x;

    insert into indique_ganhe_influencer.data_crazy_sync_leads
      (run_id, lead_id, uuid, name, region, released_at, phone, cpf,
       phone_unavailable, indication_raw, indication_influencer_id, indication_status)
    select p_run_id, x->>'leadId', nullif(x->>'uuid', '')::uuid,
      left(coalesce(x->>'name', ''), 500), nullif(left(coalesce(x->>'region', ''), 300), ''),
      nullif(x->>'releasedAt', '')::date,
      nullif(left(coalesce(x->>'phone', ''), 30), ''),
      case when coalesce(x->>'cpf', '') ~ '^[0-9]{11}$' then x->>'cpf' else null end,
      coalesce((x->>'phoneUnavailable')::boolean, false),
      left(coalesce(x->>'indicationRaw', ''), 500),
      nullif(x->>'indicationInfluencerId', ''), x->>'indicationStatus'
    from jsonb_array_elements(p_rows) x
    on conflict (run_id, lead_id) do update set
      uuid = excluded.uuid, name = excluded.name, region = excluded.region,
      released_at = excluded.released_at, phone = excluded.phone,
      cpf = excluded.cpf, phone_unavailable = excluded.phone_unavailable,
      indication_raw = excluded.indication_raw,
      indication_influencer_id = excluded.indication_influencer_id,
      indication_status = excluded.indication_status;

    update indique_ganhe_influencer.data_crazy_sync_runs
    set leads_skip = v_new_cursor,
      leads_fetched = leads_fetched + v_delta,
      lead_month = case when p_done and v_month < v_last_month
        then (v_month + interval '1 month')::date else v_month end,
      lead_total = case when v_new_phase = 'ready'
        then leads_fetched + v_delta else null end,
      phase = v_new_phase, updated_at = now(), lease_until = now() + interval '110 seconds'
    where id = p_run_id;
  end if;

  v_actor := v_run.actor_id;
  insert into indique_ganhe_influencer.import_activity
    (batch_id, actor_id, event_type, message, details)
  values (v_run.batch_id, v_actor, 'progress',
    format('Data Crazy: %s, mês %s, %s registros de origem nesta página.',
      case when p_phase = 'businesses' then 'negócios' else 'leads' end,
      to_char(v_month, 'YYYY-MM'), v_delta),
    jsonb_build_object('phase', p_phase, 'month', v_month, 'window_received', p_next_cursor,
      'staged_rows', v_rows, 'window_total', p_total,
      'indication_filled', v_indication_total, 'indication_matched', v_indication_matched));
  return jsonb_build_object('runId', p_run_id, 'phase', v_new_phase,
    'cursor', p_next_cursor, 'total', p_total);
end;
$$;

create or replace function indique_ganhe_influencer.publish_data_crazy_sync(
  p_run_id uuid, p_lease_token uuid
)
returns jsonb language plpgsql security definer
set search_path = pg_catalog, indique_ganhe_influencer
as $$
declare
  v_run indique_ganhe_influencer.data_crazy_sync_runs%rowtype;
  v_count integer;
  v_ambiguous integer;
  v_missing integer;
  v_actor uuid;
  v_prior_api_count integer;
  v_indication_total integer;
  v_indication_matched integer;
  v_indication_agreed integer;
  v_pipeline_fallback integer;
  v_indication_conflicts integer;
  v_indication_unknown integer;
  v_indication_ignored integer;
begin
  select * into v_run from indique_ganhe_influencer.data_crazy_sync_runs r
    where r.id = p_run_id for update;
  if not found or v_run.phase <> 'ready' or v_run.lease_token is distinct from p_lease_token
    or v_run.lease_until <= now() then
    raise exception 'Execução não está pronta ou autorização expirada.';
  end if;
  if v_run.business_total is null or v_run.lead_total is null
    or v_run.businesses_fetched <> v_run.business_total
    or v_run.leads_fetched <> v_run.lead_total then
    raise exception 'Coleta incompleta. Lista atual preservada.';
  end if;
  perform pg_advisory_xact_lock(hashtext('indique_ganhe:data_crazy'));

  create temporary table dc_sync_candidates on commit drop as
    select l.uuid, l.name, l.region, l.released_at, l.phone, l.cpf,
      l.phone_unavailable, l.lead_id, b.business_id,
      b.influencer_id as pipeline_influencer_id,
      b.pipeline_name, l.indication_raw, l.indication_influencer_id,
      l.indication_status,
      case
        when l.indication_status = 'empty' then b.influencer_id
        when l.indication_status = 'matched' then l.indication_influencer_id
        else null
      end as resolved_influencer_id,
      (l.indication_status = 'unknown'
        or (l.indication_status = 'matched' and b.influencer_id is not null
          and b.influencer_id is distinct from l.indication_influencer_id)
        or (l.indication_status = 'ignored' and b.influencer_id is not null)) as signal_conflict,
      concat(
        'Pipeline: ', coalesce(nullif(pi.name, ''), nullif(b.pipeline_name, ''), 'sem atribuição'),
        case when l.indication_status = 'empty' then ''
          else concat(' · Indicação: ', coalesce(nullif(l.indication_raw, ''), 'vazia')) end
      ) as attribution_evidence
    from indique_ganhe_influencer.data_crazy_sync_leads l
    left join indique_ganhe_influencer.data_crazy_sync_businesses b
      on b.run_id = l.run_id and b.lead_id = l.lead_id
    left join indique_ganhe_influencer.influencers pi on pi.id = b.influencer_id
    where l.run_id = p_run_id and l.uuid is not null
      and (b.influencer_id is not null
        or l.indication_status in ('matched', 'unknown')
        or (l.indication_status = 'ignored' and b.influencer_id is not null));

  create temporary table dc_sync_assignments on commit drop as
    select aggregate.uuid, aggregate.influencer_count, aggregate.influencer_id,
      aggregate.signal_conflict, aggregate.indication_agreed,
      aggregate.pipeline_fallback, aggregate.indication_unknown,
      aggregate.indication_ignored, aggregate.raw_influencer,
      (aggregate.influencer_count > 1 or aggregate.signal_conflict) as needs_review
    from (
      select c.uuid,
        count(distinct c.resolved_influencer_id) filter (where c.resolved_influencer_id is not null) as influencer_count,
        min(c.resolved_influencer_id) filter (where c.resolved_influencer_id is not null) as influencer_id,
        bool_or(c.signal_conflict) as signal_conflict,
        bool_or(c.indication_status = 'matched'
          and c.pipeline_influencer_id is not null
          and c.pipeline_influencer_id = c.indication_influencer_id) as indication_agreed,
        (bool_and(c.indication_status = 'empty')
          and bool_or(c.pipeline_influencer_id is not null)) as pipeline_fallback,
        bool_or(c.indication_status = 'unknown') as indication_unknown,
        bool_or(c.indication_status = 'ignored') as indication_ignored,
        string_agg(distinct c.attribution_evidence, ' | ' order by c.attribution_evidence) as raw_influencer
      from dc_sync_candidates c
      group by c.uuid
    ) aggregate;

  select count(*) into v_count from dc_sync_assignments;
  if v_count < 1 then
    raise exception 'A API não retornou indicados com UUID e atribuição reconhecíveis. Lista atual preservada.';
  end if;
  select count(*) into v_prior_api_count
  from indique_ganhe_influencer.referrals r
  join indique_ganhe_influencer.import_batches b on b.id = r.source_batch_id
  where b.source = 'api';
  if v_prior_api_count >= 20 and v_count < v_prior_api_count * 0.5 then
    raise exception 'A coleta reduziu a lista da API em mais de 50%%. Lista atual preservada para revisão.';
  end if;

  select count(*) into v_ambiguous from dc_sync_assignments where needs_review;
  select greatest(v_run.leads_fetched - count(*)::integer, 0) into v_missing
    from indique_ganhe_influencer.data_crazy_sync_leads l where l.run_id = p_run_id;
  select count(distinct l.uuid) filter (where nullif(l.indication_raw, '') is not null),
    count(distinct l.uuid) filter (where l.indication_status = 'matched'),
    count(distinct l.uuid) filter (where l.indication_status = 'unknown'),
    count(distinct l.uuid) filter (where l.indication_status = 'ignored')
  into v_indication_total, v_indication_matched, v_indication_unknown, v_indication_ignored
  from indique_ganhe_influencer.data_crazy_sync_leads l
  where l.run_id = p_run_id and l.uuid is not null;
  select count(*) filter (where pipeline_fallback),
    count(*) filter (where signal_conflict or influencer_count > 1)
  into v_pipeline_fallback, v_indication_conflicts
  from dc_sync_assignments;
  select count(*) filter (where indication_agreed)
  into v_indication_agreed from dc_sync_assignments;

  update indique_ganhe_influencer.attribution_reviews set status = 'superseded' where status = 'open';
  delete from indique_ganhe_influencer.referrals where uuid is not null;
  insert into indique_ganhe_influencer.referrals
    (uuid, name, region, released_at, phone, cpf, phone_unavailable,
      influencer_id, raw_influencer, source_batch_id)
  select distinct on (c.uuid) c.uuid, c.name, c.region, c.released_at,
    c.phone, c.cpf, c.phone_unavailable,
    case when a.influencer_count = 1 and not a.needs_review then a.influencer_id else null end,
    a.raw_influencer, v_run.batch_id
  from dc_sync_candidates c join dc_sync_assignments a on a.uuid = c.uuid
  order by c.uuid, c.released_at desc nulls last, c.business_id desc nulls last, c.lead_id desc;

  insert into indique_ganhe_influencer.attribution_reviews
    (batch_id, uuid, name, region, raw_influencer)
  select v_run.batch_id, r.uuid, r.name, r.region, r.raw_influencer
  from indique_ganhe_influencer.referrals r
  join dc_sync_assignments a on a.uuid = r.uuid
  where r.source_batch_id = v_run.batch_id and a.needs_review;

  update indique_ganhe_influencer.import_batches
  set status = 'completed', completed_at = now(), finished_at = now(),
    expected_rows = v_count, staged_rows = v_count,
    metrics = metrics || jsonb_build_object('businesses', v_run.businesses_fetched,
      'leads', v_run.leads_fetched, 'referrals', v_count,
      'ambiguous', v_ambiguous, 'invalid_uuid', v_missing,
      'indicationTotal', coalesce(v_indication_total, 0),
      'indicationMatched', coalesce(v_indication_matched, 0),
      'indicationAgreed', coalesce(v_indication_agreed, 0),
      'pipelineFallback', coalesce(v_pipeline_fallback, 0),
      'indicationConflicts', coalesce(v_indication_conflicts, 0),
      'indicationUnknown', coalesce(v_indication_unknown, 0),
      'indicationIgnored', coalesce(v_indication_ignored, 0)),
    error_message = null
  where id = v_run.batch_id;

  v_actor := v_run.actor_id;
  update indique_ganhe_influencer.data_crazy_sync_runs
  set phase = 'completed', completed_at = now(), updated_at = now(),
    lease_token = null, lease_until = null where id = p_run_id;
  insert into indique_ganhe_influencer.import_activity
    (batch_id, actor_id, event_type, message, details)
  values (v_run.batch_id, v_actor, 'completed',
    'Data Crazy API publicou a lista após comparar pipeline e indicação do lead.',
    jsonb_build_object('referrals', v_count, 'ambiguous', v_ambiguous,
      'invalid_uuid', v_missing, 'businesses', v_run.businesses_fetched,
      'leads', v_run.leads_fetched, 'indication_total', v_indication_total,
      'indication_matched', v_indication_matched,
      'indication_agreed', v_indication_agreed,
      'pipeline_fallback', v_pipeline_fallback,
      'indication_conflicts', v_indication_conflicts,
      'indication_unknown', v_indication_unknown,
      'indication_ignored', v_indication_ignored));
  delete from indique_ganhe_influencer.data_crazy_sync_businesses where run_id = p_run_id;
  delete from indique_ganhe_influencer.data_crazy_sync_leads where run_id = p_run_id;
  return jsonb_build_object('imported', v_count, 'ambiguous', v_ambiguous,
    'invalidUuid', v_missing, 'kind', 'data_crazy',
    'indicationMatched', v_indication_matched,
    'indicationAgreed', v_indication_agreed,
    'indicationConflicts', v_indication_conflicts);
end;
$$;

notify pgrst, 'reload schema';
commit;
