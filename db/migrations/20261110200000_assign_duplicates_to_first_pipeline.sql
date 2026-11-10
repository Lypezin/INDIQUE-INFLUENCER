begin;

-- Multiple pipeline memberships are resolved automatically by influencer order.
-- Administrative UUID overrides and manual transfers for unidentified leads persist.
create or replace function indique_ganhe_influencer.publish_data_crazy_sync_core(
  p_run_id uuid, p_lease_token uuid
)
returns jsonb language plpgsql security definer
set search_path = pg_catalog, indique_ganhe_influencer
as $$
declare
  v_run indique_ganhe_influencer.data_crazy_sync_runs%rowtype;
  v_count integer;
  v_unidentified_count integer;
  v_ambiguous integer;
  v_auto_assigned integer;
  v_missing integer;
  v_invalid_uuid integer;
  v_actor uuid;
  v_prior_api_count integer;
  v_prior_indication_total integer := 0;
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
    b.influencer_id as pipeline_influencer_id, b.pipeline_name,
    coalesce(i.sort_order, 2147483647) as pipeline_order,
    concat('Pipeline: ', coalesce(nullif(i.name, ''), nullif(b.pipeline_name, ''), 'sem atribuição')) as evidence
  from indique_ganhe_influencer.data_crazy_sync_leads l
  join indique_ganhe_influencer.data_crazy_sync_businesses b
    on b.run_id = l.run_id and b.lead_id = l.lead_id
  left join indique_ganhe_influencer.influencers i on i.id = b.influencer_id
  where l.run_id = p_run_id and l.uuid is not null and b.influencer_id is not null;

  create temporary table dc_sync_assignments on commit drop as
  select grouped.uuid, grouped.pipeline_count,
    grouped.pipeline_influencer_id, state.influencer_override_id,
    coalesce(state.influencer_override_id, grouped.pipeline_influencer_id) as influencer_id,
    false as needs_review,
    grouped.raw_influencer
  from (
    select c.uuid, count(distinct c.pipeline_influencer_id)::integer as pipeline_count,
      (array_agg(c.pipeline_influencer_id order by c.pipeline_order, c.pipeline_influencer_id))[1] as pipeline_influencer_id,
      string_agg(distinct c.evidence, ' | ' order by c.evidence) as raw_influencer
    from dc_sync_candidates c group by c.uuid
  ) grouped
  left join indique_ganhe_influencer.referral_admin_state state on state.courier_uuid = grouped.uuid;

  create temporary table dc_sync_unidentified_candidates on commit drop as
  select l.lead_id, l.name, l.region, l.released_at, l.phone, l.cpf,
    l.phone_unavailable, b.business_id, b.influencer_id as pipeline_influencer_id,
    b.pipeline_name, coalesce(i.sort_order, 2147483647) as pipeline_order,
    concat('Pipeline: ', coalesce(nullif(i.name, ''), nullif(b.pipeline_name, ''), 'sem atribuição')) as evidence
  from indique_ganhe_influencer.data_crazy_sync_leads l
  join indique_ganhe_influencer.data_crazy_sync_businesses b
    on b.run_id = l.run_id and b.lead_id = l.lead_id
  left join indique_ganhe_influencer.influencers i on i.id = b.influencer_id
  where l.run_id = p_run_id and l.uuid is null and b.influencer_id is not null;

  create temporary table dc_sync_unidentified_assignments on commit drop as
  select grouped.lead_id, grouped.pipeline_count, grouped.pipeline_influencer_id,
    grouped.raw_influencer,
    coalesce(
      case when existing_row.assignment_overridden then existing_row.influencer_id end,
      grouped.pipeline_influencer_id
    ) as influencer_id,
    coalesce(existing_row.assignment_overridden, false) as assignment_overridden,
    false as needs_review
  from (
    select c.lead_id, count(distinct c.pipeline_influencer_id)::integer as pipeline_count,
      (array_agg(c.pipeline_influencer_id order by c.pipeline_order, c.pipeline_influencer_id))[1] as pipeline_influencer_id,
      string_agg(distinct c.evidence, ' | ' order by c.evidence) as raw_influencer
    from dc_sync_unidentified_candidates c group by c.lead_id
  ) grouped
  left join indique_ganhe_influencer.data_crazy_unidentified_referrals existing_row
    on existing_row.lead_id = grouped.lead_id;

  select count(*) into v_count from dc_sync_assignments;
  select count(*) into v_unidentified_count from dc_sync_unidentified_assignments;
  if v_count + v_unidentified_count < 1 then
    raise exception 'A API não retornou leads nas pipelines dos influenciadores. Lista atual preservada.';
  end if;

  select
    (select count(*) from indique_ganhe_influencer.referrals r
      join indique_ganhe_influencer.import_batches b on b.id = r.source_batch_id where b.source = 'api')
    + (select count(*) from indique_ganhe_influencer.data_crazy_unidentified_referrals u
      join indique_ganhe_influencer.import_batches b on b.id = u.source_batch_id where b.source = 'api')
  into v_prior_api_count;
  select coalesce(max(case when b.metrics->>'indicationTotal' ~ '^[0-9]+$'
    then (b.metrics->>'indicationTotal')::integer else 0 end), 0)
  into v_prior_indication_total
  from indique_ganhe_influencer.referrals r
  join indique_ganhe_influencer.import_batches b on b.id = r.source_batch_id where b.source = 'api';

  if v_prior_api_count >= 20 and v_prior_indication_total = 0
    and v_count + v_unidentified_count < v_prior_api_count * 0.5 then
    raise exception 'A coleta reduziu a lista da API em mais de 50%%. Lista atual preservada para revisão.';
  end if;

  select (select count(*) from dc_sync_assignments where needs_review)
    + (select count(*) from dc_sync_unidentified_assignments where needs_review)
  into v_ambiguous;
  select (select count(*) from dc_sync_assignments where pipeline_count > 1 and influencer_override_id is null)
    + (select count(*) from dc_sync_unidentified_assignments where pipeline_count > 1 and not assignment_overridden)
  into v_auto_assigned;
  select count(*) into v_invalid_uuid
  from indique_ganhe_influencer.data_crazy_sync_leads l
  where l.run_id = p_run_id and l.uuid is null;
  select greatest(v_run.leads_fetched - v_count - v_unidentified_count, 0)
    into v_missing;

  update indique_ganhe_influencer.attribution_reviews set status = 'superseded' where status = 'open';
  delete from indique_ganhe_influencer.referrals where uuid is not null;
  insert into indique_ganhe_influencer.referrals
    (uuid, name, region, released_at, phone, cpf, phone_unavailable,
      influencer_id, raw_influencer, source_batch_id)
  select distinct on (c.uuid) c.uuid, c.name, c.region, c.released_at,
    c.phone, c.cpf, c.phone_unavailable, a.influencer_id, a.raw_influencer, v_run.batch_id
  from dc_sync_candidates c join dc_sync_assignments a on a.uuid = c.uuid
  order by c.uuid, c.released_at desc nulls last, c.business_id desc, c.lead_id desc;

  insert into indique_ganhe_influencer.attribution_reviews
    (batch_id, uuid, name, region, raw_influencer)
  select v_run.batch_id, r.uuid, r.name, r.region, r.raw_influencer
  from indique_ganhe_influencer.referrals r
  join dc_sync_assignments a on a.uuid = r.uuid
  where r.source_batch_id = v_run.batch_id and a.needs_review;

  insert into indique_ganhe_influencer.data_crazy_unidentified_referrals
    (lead_id, name, region, released_at, phone, cpf, phone_unavailable,
      pipeline_influencer_id, influencer_id, assignment_overridden, needs_review,
      raw_influencer, source_batch_id, updated_at)
  select distinct on (c.lead_id) c.lead_id, c.name, c.region, c.released_at,
    c.phone, c.cpf, c.phone_unavailable, a.pipeline_influencer_id, a.influencer_id,
    a.assignment_overridden, a.needs_review, a.raw_influencer, v_run.batch_id, now()
  from dc_sync_unidentified_candidates c
  join dc_sync_unidentified_assignments a on a.lead_id = c.lead_id
  order by c.lead_id, c.released_at desc nulls last, c.business_id desc
  on conflict (lead_id) do update set
    name = excluded.name, region = excluded.region, released_at = excluded.released_at,
    phone = excluded.phone, cpf = excluded.cpf, phone_unavailable = excluded.phone_unavailable,
    pipeline_influencer_id = excluded.pipeline_influencer_id,
    influencer_id = excluded.influencer_id,
    assignment_overridden = excluded.assignment_overridden,
    needs_review = excluded.needs_review, raw_influencer = excluded.raw_influencer,
    source_batch_id = excluded.source_batch_id, updated_at = now();

  delete from indique_ganhe_influencer.data_crazy_unidentified_referrals current
  where not exists (
    select 1 from dc_sync_unidentified_assignments incoming where incoming.lead_id = current.lead_id
  );

  update indique_ganhe_influencer.import_batches
  set status = 'completed', completed_at = now(), finished_at = now(),
    expected_rows = v_count + v_unidentified_count,
    staged_rows = v_count + v_unidentified_count,
    metrics = metrics || jsonb_build_object(
      'businesses', v_run.businesses_fetched, 'leads', v_run.leads_fetched,
      'referrals', v_count + v_unidentified_count, 'uuidReferrals', v_count,
      'unidentified', v_unidentified_count, 'ambiguous', v_ambiguous,
      'autoAssignedFirstPipeline', v_auto_assigned,
      'invalid_uuid', v_invalid_uuid,
      'excludedNoPipeline', v_missing, 'indicationTotal', 0),
    error_message = null
  where id = v_run.batch_id;

  v_actor := v_run.actor_id;
  update indique_ganhe_influencer.data_crazy_sync_runs
  set phase = 'completed', completed_at = now(), updated_at = now(),
    lease_token = null, lease_until = null where id = p_run_id;
  insert into indique_ganhe_influencer.import_activity
    (batch_id, actor_id, event_type, message, details)
  values (v_run.batch_id, v_actor, 'completed',
    'Data Crazy publicou os leads das pipelines dos influenciadores, inclusive os sem UUID.',
    jsonb_build_object('referrals', v_count + v_unidentified_count, 'uuid_referrals', v_count,
      'unidentified', v_unidentified_count, 'ambiguous', v_ambiguous,
      'auto_assigned_first_pipeline', v_auto_assigned,
      'excluded_no_pipeline', v_missing, 'businesses', v_run.businesses_fetched,
      'leads', v_run.leads_fetched));

  delete from indique_ganhe_influencer.data_crazy_sync_businesses where run_id = p_run_id;
  delete from indique_ganhe_influencer.data_crazy_sync_leads where run_id = p_run_id;
  return jsonb_build_object('imported', v_count + v_unidentified_count,
    'uuidReferrals', v_count, 'unidentified', v_unidentified_count,
    'ambiguous', v_ambiguous, 'autoAssignedFirstPipeline', v_auto_assigned,
    'invalidUuid', v_invalid_uuid, 'kind', 'data_crazy');
end;
$$;

notify pgrst, 'reload schema';
commit;
