begin;

-- A one-second defer is the normal handoff between successful worker chunks.
-- Only record a retry event when the API actually requests a longer pause.
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
  if v_delay > 1 then
    insert into indique_ganhe_influencer.import_activity
      (batch_id, actor_id, event_type, message, details)
    values (v_run.batch_id, v_run.actor_id, 'progress',
      'API Data Crazy indisponível ou limitada; retomada agendada.',
      jsonb_build_object('phase', v_run.phase, 'retry_after_seconds', v_delay));
  end if;
  return true;
end;
$$;

commit;
