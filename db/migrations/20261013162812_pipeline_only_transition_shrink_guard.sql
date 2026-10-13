CREATE OR REPLACE FUNCTION indique_ganhe_influencer.publish_data_crazy_sync_core(p_run_id uuid, p_lease_token uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'indique_ganhe_influencer'
AS $function$
declare
  v_run indique_ganhe_influencer.data_crazy_sync_runs%rowtype;
  v_count integer;
  v_ambiguous integer;
  v_missing integer;
  v_actor uuid;
  v_prior_api_count integer;
  v_prior_indication_total integer := 0;
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
  select coalesce(max(
    case
      when b.metrics->>'indicationTotal' ~ '^[0-9]+$'
        then (b.metrics->>'indicationTotal')::integer
      else 0
    end
  ), 0)
  into v_prior_indication_total
  from indique_ganhe_influencer.referrals r
  join indique_ganhe_influencer.import_batches b on b.id = r.source_batch_id
  where b.source = 'api';
  -- Exempt only the first publication after retiring lead-based attribution.
  -- The new pipeline-only batch stores indicationTotal = 0, restoring this guard.
  if v_prior_api_count >= 20
    and v_prior_indication_total = 0
    and v_count < v_prior_api_count * 0.5 then
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
    'Data Crazy API publicou a lista usando somente a pipeline do influenciador.',
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
$function$
