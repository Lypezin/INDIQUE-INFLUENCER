begin;

create or replace function indique_ganhe_influencer.publish_data_crazy_sync(
  p_run_id uuid, p_lease_token uuid
)
returns jsonb language plpgsql security definer
set search_path = pg_catalog, indique_ganhe_influencer
as $$
declare v_run indique_ganhe_influencer.data_crazy_sync_runs%rowtype;
  v_count integer; v_ambiguous integer; v_missing integer; v_actor uuid; v_prior_api_count integer;
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
  -- File imports used the old attribution field; compare shrinkage only with
  -- previous API snapshots that used the same pipeline and UUID rules.
  select count(*) into v_prior_api_count
  from indique_ganhe_influencer.referrals r
  join indique_ganhe_influencer.import_batches b on b.id = r.source_batch_id
  where b.source = 'api';
  if v_prior_api_count >= 20 and v_count < v_prior_api_count * 0.5 then
    raise exception 'A coleta reduziu a lista da API em mais de 50%%. Lista atual preservada para revisão.';
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

commit;
