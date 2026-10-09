begin;

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
    'windowMonth', case when r.phase = 'businesses' then r.business_month
      when r.phase = 'leads' then r.lead_month else null end,
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

notify pgrst, 'reload schema';
commit;
