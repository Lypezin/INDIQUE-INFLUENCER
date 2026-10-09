begin;

-- Data Crazy stops returning records after an offset around 10,100 even when
-- more records exist. Scan calendar months and fail safely if one month also
-- reaches that limit. The 2020 floor is checked against the API by the worker.
alter table indique_ganhe_influencer.data_crazy_sync_runs
  add column snapshot_until timestamptz not null default now(),
  add column business_month date not null default date '2020-01-01',
  add column lead_month date not null default date '2020-01-01';

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
    'leadsSkip', v_run.leads_skip, 'businessMonth', v_run.business_month,
    'leadMonth', v_run.lead_month, 'snapshotUntil', v_run.snapshot_until,
    'businessTotal', v_run.business_total, 'leadTotal', v_run.lead_total);
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
  v_rows integer; v_expected_cursor integer; v_actor uuid; v_month date;
  v_last_month date; v_delta integer; v_new_phase text; v_new_cursor integer;
begin
  if p_phase not in ('businesses', 'leads') or p_cursor is null or p_cursor < 0
    or p_next_cursor is null or p_next_cursor < p_cursor
    or (p_total is not null and p_total < 0) or p_done is null
    or jsonb_typeof(p_rows) is distinct from 'array' then raise exception 'Página Data Crazy inválida.'; end if;
  v_rows := jsonb_array_length(p_rows);
  v_delta := p_next_cursor - p_cursor;
  if v_rows > 300 or v_delta > 300 or (v_delta = 0 and not p_done)
    or v_rows > v_delta then raise exception 'Tamanho da página inválido.'; end if;
  if p_next_cursor >= 10000 and not p_done then
    raise exception 'A página mensal atingiu o limite da API. Lista atual preservada.';
  end if;
  if p_total is not null and p_next_cursor > p_total then raise exception 'Página excedeu o total informado.'; end if;
  if p_done and (p_total is null or p_next_cursor <> p_total) then
    raise exception 'Coleta declarada completa antes do total.'; end if;
  select * into v_run from indique_ganhe_influencer.data_crazy_sync_runs r
    where r.id = p_run_id for update;
  if not found or v_run.phase <> p_phase or v_run.lease_token is distinct from p_lease_token
    or v_run.lease_until <= now() then raise exception 'Execução ou autorização expirada.'; end if;
  v_expected_cursor := case when p_phase = 'businesses' then v_run.businesses_skip else v_run.leads_skip end;
  v_month := case when p_phase = 'businesses' then v_run.business_month else v_run.lead_month end;
  v_last_month := date_trunc('month', v_run.snapshot_until at time zone 'UTC')::date;
  if p_cursor <> v_expected_cursor or v_month > v_last_month then raise exception 'Página fora de ordem.'; end if;
  v_new_cursor := case when p_done then 0 else p_next_cursor end;
  v_new_phase := case when p_done and v_month >= v_last_month
    then case when p_phase = 'businesses' then 'leads' else 'ready' end
    else p_phase end;
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
      set businesses_skip = v_new_cursor,
        businesses_fetched = businesses_fetched + v_delta,
        business_month = case when p_done and v_month < v_last_month
          then (v_month + interval '1 month')::date else v_month end,
        business_total = case when v_new_phase = 'leads' then businesses_fetched + v_delta else null end,
        phase = v_new_phase, updated_at = now(), lease_until = now() + interval '110 seconds'
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
      set leads_skip = v_new_cursor,
        leads_fetched = leads_fetched + v_delta,
        lead_month = case when p_done and v_month < v_last_month
          then (v_month + interval '1 month')::date else v_month end,
        lead_total = case when v_new_phase = 'ready' then leads_fetched + v_delta else null end,
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
      'staged_rows', v_rows, 'window_total', p_total));
  return jsonb_build_object('runId', p_run_id, 'phase', v_new_phase,
    'cursor', p_next_cursor, 'total', p_total);
end;
$$;

notify pgrst, 'reload schema';
commit;
