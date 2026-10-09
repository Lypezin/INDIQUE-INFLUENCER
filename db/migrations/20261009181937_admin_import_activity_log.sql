alter table indique_ganhe_influencer.import_batches
  add column if not exists error_message text,
  add column if not exists finished_at timestamptz;

alter table indique_ganhe_influencer.import_batches
  drop constraint if exists import_batches_status_check;
alter table indique_ganhe_influencer.import_batches
  add constraint import_batches_status_check
  check (status in ('staging', 'completed', 'failed', 'cancelled'));

update indique_ganhe_influencer.import_batches
set finished_at = completed_at
where status = 'completed' and finished_at is null;

create table indique_ganhe_influencer.import_activity (
  id bigint generated always as identity primary key,
  batch_id uuid not null references indique_ganhe_influencer.import_batches(id) on delete cascade,
  actor_id uuid references auth.users(id) on delete set null,
  event_type text not null check (event_type in ('started', 'progress', 'completed', 'failed', 'cancelled', 'legacy')),
  message text not null,
  details jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);

create index import_activity_batch_timeline_idx
  on indique_ganhe_influencer.import_activity (batch_id, created_at, id);

alter table indique_ganhe_influencer.import_activity enable row level security;
revoke all on indique_ganhe_influencer.import_activity from public, anon, authenticated;

insert into indique_ganhe_influencer.import_activity
  (batch_id, actor_id, event_type, message, details, created_at)
select b.id, b.created_by, 'legacy',
  case b.status
    when 'completed' then 'Importação concluída. As etapas detalhadas ainda não eram registradas.'
    when 'failed' then 'Tentativa marcada como falha. O motivo não era registrado.'
    when 'cancelled' then 'Importação cancelada antes da ativação do log detalhado.'
    else 'Lote iniciado antes da ativação do log detalhado.'
  end,
  jsonb_build_object(
    'legacy', true,
    'status', b.status,
    'expected_rows', b.expected_rows,
    'staged_rows', b.staged_rows,
    'metrics', b.metrics
  ),
  coalesce(b.completed_at, b.created_at)
from indique_ganhe_influencer.import_batches b
where not exists (
  select 1 from indique_ganhe_influencer.import_activity a where a.batch_id = b.id
);

create or replace function indique_ganhe_influencer.start_import(
  p_kind text, p_file_name text, p_file_hash text, p_metrics jsonb, p_total_rows integer
)
returns jsonb language plpgsql security definer
set search_path = pg_catalog, indique_ganhe_influencer
as $$
declare
  v_id uuid;
  v_duplicate boolean;
  v_metrics jsonb := coalesce(p_metrics, '{}'::jsonb);
begin
  if not indique_ganhe_influencer.is_admin() then
    raise exception 'Apenas a administração pode importar arquivos.';
  end if;
  if p_kind not in ('data_crazy', 'performance') then
    raise exception 'Tipo de importação inválido.';
  end if;
  if p_total_rows is null or p_total_rows < 1 or p_total_rows > 100000 then
    raise exception 'Quantidade de registros inválida.';
  end if;
  if p_file_hash !~ '^[0-9a-f]{64}$' then
    raise exception 'Hash do arquivo inválido.';
  end if;
  select exists (
    select 1 from indique_ganhe_influencer.import_batches b
    where b.kind = p_kind and b.file_hash = p_file_hash and b.status = 'completed'
  ) into v_duplicate;

  insert into indique_ganhe_influencer.import_batches
    (kind, file_name, file_hash, metrics, expected_rows, created_by)
  values (
    p_kind, left(coalesce(p_file_name, 'arquivo'), 255), p_file_hash,
    v_metrics, p_total_rows, auth.uid()
  )
  returning id into v_id;

  insert into indique_ganhe_influencer.import_activity
    (batch_id, actor_id, event_type, message, details)
  values (
    v_id, auth.uid(), 'started',
    case when p_kind = 'data_crazy' then 'Importação Data Crazy iniciada.'
      else 'Importação de Performance iniciada.' end,
    jsonb_build_object(
      'expected_rows', p_total_rows,
      'metrics', v_metrics,
      'duplicate_file', v_duplicate
    )
  );
  return jsonb_build_object('batchId', v_id, 'duplicateFile', v_duplicate);
end;
$$;

create or replace function indique_ganhe_influencer.append_import_rows(p_batch_id uuid, p_rows jsonb)
returns integer language plpgsql security definer
set search_path = pg_catalog, indique_ganhe_influencer
as $$
declare
  v_expected integer;
  v_staged integer;
  v_added integer;
  v_total integer;
  v_percent integer;
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
  if not found then
    raise exception 'Importação não encontrada ou já finalizada.';
  end if;

  v_added := jsonb_array_length(p_rows);
  if v_staged + v_added > v_expected then
    raise exception 'O lote excedeu a quantidade prevista.';
  end if;

  insert into indique_ganhe_influencer.import_rows (batch_id, payload)
  select p_batch_id, item from jsonb_array_elements(p_rows) item;

  update indique_ganhe_influencer.import_batches
  set staged_rows = staged_rows + v_added
  where id = p_batch_id
  returning staged_rows into v_total;
  v_percent := round(v_total::numeric * 100 / v_expected)::integer;

  insert into indique_ganhe_influencer.import_activity
    (batch_id, actor_id, event_type, message, details)
  values (
    p_batch_id, auth.uid(), 'progress',
    format('Lote recebido: %s de %s linhas (%s%%).', v_total, v_expected, v_percent),
    jsonb_build_object(
      'chunk_rows', v_added,
      'rows_received', v_total,
      'expected_rows', v_expected,
      'progress_percent', v_percent
    )
  );
  return v_total;
end;
$$;

create or replace function indique_ganhe_influencer.cancel_import(p_batch_id uuid)
returns boolean language plpgsql security definer
set search_path = pg_catalog, indique_ganhe_influencer
as $$
declare
  v_batch indique_ganhe_influencer.import_batches%rowtype;
begin
  if not indique_ganhe_influencer.is_admin() then
    raise exception 'Apenas a administração pode cancelar importações.';
  end if;
  select * into v_batch
  from indique_ganhe_influencer.import_batches b
  where b.id = p_batch_id and b.created_by = auth.uid() and b.status = 'staging'
  for update;
  if not found then
    return false;
  end if;

  delete from indique_ganhe_influencer.import_rows where batch_id = p_batch_id;
  update indique_ganhe_influencer.import_batches
  set status = 'cancelled', finished_at = now(), error_message = null
  where id = p_batch_id;
  insert into indique_ganhe_influencer.import_activity
    (batch_id, actor_id, event_type, message, details)
  values (
    p_batch_id, auth.uid(), 'cancelled', 'Importação cancelada pelo administrador.',
    jsonb_build_object('rows_received', v_batch.staged_rows, 'expected_rows', v_batch.expected_rows)
  );
  return true;
end;
$$;

create or replace function indique_ganhe_influencer.fail_import(p_batch_id uuid, p_error_message text)
returns boolean language plpgsql security definer
set search_path = pg_catalog, indique_ganhe_influencer
as $$
declare
  v_batch indique_ganhe_influencer.import_batches%rowtype;
  v_message text;
begin
  if not indique_ganhe_influencer.is_admin() then
    raise exception 'Apenas a administração pode registrar uma falha de importação.';
  end if;
  select * into v_batch
  from indique_ganhe_influencer.import_batches b
  where b.id = p_batch_id and b.created_by = auth.uid() and b.status = 'staging'
  for update;
  if not found then
    return false;
  end if;

  v_message := left(
    regexp_replace(
      coalesce(nullif(btrim(p_error_message), ''), 'A importação não foi concluída.'),
      '[[:cntrl:]]', ' ', 'g'
    ),
    1000
  );
  delete from indique_ganhe_influencer.import_rows where batch_id = p_batch_id;
  update indique_ganhe_influencer.import_batches
  set status = 'failed', finished_at = now(), error_message = v_message
  where id = p_batch_id;
  insert into indique_ganhe_influencer.import_activity
    (batch_id, actor_id, event_type, message, details)
  values (
    p_batch_id, auth.uid(), 'failed', v_message,
    jsonb_build_object('rows_received', v_batch.staged_rows, 'expected_rows', v_batch.expected_rows)
  );
  return true;
end;
$$;

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
    delete from indique_ganhe_influencer.referrals where uuid is not null;
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
  set status = 'completed', completed_at = now(), finished_at = now(), error_message = null
  where id = p_batch_id;
  insert into indique_ganhe_influencer.import_activity
    (batch_id, actor_id, event_type, message, details)
  values (
    p_batch_id, auth.uid(), 'completed',
    case when v_batch.kind = 'data_crazy' then 'Data Crazy substituiu a lista atual com sucesso.'
      else 'Importação de Performance concluída e corridas somadas.' end,
    jsonb_build_object('rows_processed', v_rows, 'kind', v_batch.kind, 'metrics', v_batch.metrics)
  );
  delete from indique_ganhe_influencer.import_rows where batch_id = p_batch_id;
  return v_result;
end;
$$;

create or replace function indique_ganhe_influencer.list_import_history(
  p_limit integer default 25,
  p_offset integer default 0,
  p_status text default 'all',
  p_kind text default 'all'
)
returns jsonb language plpgsql stable security definer
set search_path = pg_catalog, indique_ganhe_influencer
as $$
declare
  v_status text := coalesce(nullif(p_status, ''), 'all');
  v_kind text := coalesce(nullif(p_kind, ''), 'all');
begin
  if not indique_ganhe_influencer.is_admin() then
    raise exception 'Apenas a administração pode consultar o histórico.';
  end if;
  if p_limit is null or p_limit < 1 or p_limit > 100 then
    raise exception 'A quantidade por página deve ficar entre 1 e 100.';
  end if;
  if p_offset is null or p_offset < 0 then
    raise exception 'A página solicitada é inválida.';
  end if;
  if v_status not in ('all', 'staging', 'completed', 'failed', 'cancelled') then
    raise exception 'Filtro de status inválido.';
  end if;
  if v_kind not in ('all', 'data_crazy', 'performance') then
    raise exception 'Filtro de tipo inválido.';
  end if;

  return (
    with filtered as (
      select b.id, b.kind, b.file_name, left(b.file_hash, 12) as file_hash_prefix,
        b.status, b.metrics, b.expected_rows, b.staged_rows, b.created_at,
        b.completed_at, b.finished_at, b.error_message,
        coalesce(m.email, 'Conta sem vínculo') as actor_email,
        greatest(0, extract(epoch from (
          coalesce(b.finished_at, b.completed_at, now()) - b.created_at
        ))::integer) as duration_seconds,
        last_event.message as last_event_message
      from indique_ganhe_influencer.import_batches b
      left join indique_ganhe_influencer.account_members m on m.user_id = b.created_by
      left join lateral (
        select e.message
        from indique_ganhe_influencer.import_activity e
        where e.batch_id = b.id
        order by e.created_at desc, e.id desc
        limit 1
      ) last_event on true
      where (v_status = 'all' or b.status = v_status)
        and (v_kind = 'all' or b.kind = v_kind)
    ),
    paged as (
      select * from filtered order by created_at desc, id desc limit p_limit offset p_offset
    )
    select jsonb_build_object(
      'items', coalesce((select jsonb_agg(to_jsonb(p) order by p.created_at desc, p.id desc) from paged p), '[]'::jsonb),
      'total', (select count(*) from filtered),
      'summary', (
        select jsonb_build_object(
          'total', count(*),
          'staging', count(*) filter (where b.status = 'staging'),
          'completed', count(*) filter (where b.status = 'completed'),
          'failed', count(*) filter (where b.status = 'failed'),
          'cancelled', count(*) filter (where b.status = 'cancelled')
        )
        from indique_ganhe_influencer.import_batches b
      )
    )
  );
end;
$$;

create or replace function indique_ganhe_influencer.list_import_events(p_batch_id uuid)
returns jsonb language plpgsql stable security definer
set search_path = pg_catalog, indique_ganhe_influencer
as $$
declare
  v_events jsonb;
begin
  if not indique_ganhe_influencer.is_admin() then
    raise exception 'Apenas a administração pode consultar o histórico.';
  end if;
  if not exists (
    select 1 from indique_ganhe_influencer.import_batches b where b.id = p_batch_id
  ) then
    raise exception 'Importação não encontrada.';
  end if;

  select coalesce(jsonb_agg(jsonb_build_object(
    'id', e.id,
    'event_type', e.event_type,
    'message', e.message,
    'details', e.details,
    'created_at', e.created_at,
    'actor_email', coalesce(m.email, 'Conta sem vínculo')
  ) order by e.created_at, e.id), '[]'::jsonb)
  into v_events
  from indique_ganhe_influencer.import_activity e
  left join indique_ganhe_influencer.account_members m on m.user_id = e.actor_id
  where e.batch_id = p_batch_id;
  return v_events;
end;
$$;

revoke execute on function indique_ganhe_influencer.fail_import(uuid, text) from public, anon;
revoke execute on function indique_ganhe_influencer.list_import_history(integer, integer, text, text) from public, anon;
revoke execute on function indique_ganhe_influencer.list_import_events(uuid) from public, anon;
grant execute on function indique_ganhe_influencer.fail_import(uuid, text) to authenticated;
grant execute on function indique_ganhe_influencer.list_import_history(integer, integer, text, text) to authenticated;
grant execute on function indique_ganhe_influencer.list_import_events(uuid) to authenticated;

