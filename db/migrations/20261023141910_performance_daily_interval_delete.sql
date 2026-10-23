begin;

alter table indique_ganhe_influencer.import_batches
  add column if not exists performance_detail_ready boolean not null default false;

create table indique_ganhe_influencer.performance_daily_contributions (
  batch_id uuid not null references indique_ganhe_influencer.import_batches(id),
  uuid uuid not null,
  source_date date not null,
  city text not null check (length(trim(city)) > 0),
  route_count integer not null check (route_count >= 0),
  row_count integer not null check (row_count > 0),
  primary key (batch_id, uuid, source_date, city),
  foreign key (batch_id, uuid) references indique_ganhe_influencer.performance_contributions(batch_id, uuid)
);
create index performance_daily_date_city_idx
  on indique_ganhe_influencer.performance_daily_contributions(source_date, city);
create index performance_daily_uuid_idx
  on indique_ganhe_influencer.performance_daily_contributions(uuid);
alter table indique_ganhe_influencer.performance_daily_contributions enable row level security;
create policy performance_daily_admin_read on indique_ganhe_influencer.performance_daily_contributions
  for select to authenticated using (indique_ganhe_influencer.is_admin());
revoke all on indique_ganhe_influencer.performance_daily_contributions from public, anon, authenticated;
grant select on indique_ganhe_influencer.performance_daily_contributions to authenticated;

create table indique_ganhe_influencer.performance_detail_staging (
  actor_id uuid not null references auth.users(id),
  file_hash text not null,
  uuid uuid not null,
  source_date date not null,
  city text not null,
  route_count integer not null check (route_count >= 0),
  row_count integer not null check (row_count > 0),
  primary key (actor_id, file_hash, uuid, source_date, city)
);
alter table indique_ganhe_influencer.performance_detail_staging enable row level security;
revoke all on indique_ganhe_influencer.performance_detail_staging from public, anon, authenticated;

create table indique_ganhe_influencer.performance_deletions (
  id uuid primary key default gen_random_uuid(),
  actor_id uuid not null references auth.users(id),
  deleted_at timestamptz not null default now(),
  date_from date not null,
  date_to date not null,
  city text,
  route_count bigint not null,
  row_count bigint not null,
  affected_couriers integer not null,
  affected_imports integer not null
);
create table indique_ganhe_influencer.performance_deleted_rows (
  deletion_id uuid not null references indique_ganhe_influencer.performance_deletions(id),
  batch_id uuid not null references indique_ganhe_influencer.import_batches(id),
  uuid uuid not null,
  source_date date not null,
  city text not null,
  route_count integer not null,
  row_count integer not null,
  primary key (deletion_id, batch_id, uuid, source_date, city)
);
alter table indique_ganhe_influencer.performance_deletions enable row level security;
alter table indique_ganhe_influencer.performance_deleted_rows enable row level security;
create policy performance_deletions_admin_read on indique_ganhe_influencer.performance_deletions
  for select to authenticated using (indique_ganhe_influencer.is_admin());
create policy performance_deleted_rows_admin_read on indique_ganhe_influencer.performance_deleted_rows
  for select to authenticated using (indique_ganhe_influencer.is_admin());
revoke all on indique_ganhe_influencer.performance_deletions,
  indique_ganhe_influencer.performance_deleted_rows from public, anon, authenticated;
grant select on indique_ganhe_influencer.performance_deletions,
  indique_ganhe_influencer.performance_deleted_rows to authenticated;

create or replace function indique_ganhe_influencer.performance_coverage_for_batch(p_batch_id uuid)
returns jsonb language sql stable security definer
set search_path = pg_catalog, indique_ganhe_influencer
as $$
  with entries as (
    select source_date, city, row_count
    from indique_ganhe_influencer.performance_daily_contributions
    where batch_id = p_batch_id
  ), cities as (
    select city, min(source_date) first_date, max(source_date) last_date,
      sum(row_count) row_count from entries group by city
  ), summary as (
    select min(source_date) first_date, max(source_date) last_date,
      coalesce(sum(row_count), 0) row_count from entries
  )
  select case when summary.first_date is null then '{}'::jsonb else jsonb_build_object(
    'firstDate', summary.first_date, 'lastDate', summary.last_date,
    'rowCount', summary.row_count,
    'cities', (select coalesce(jsonb_agg(jsonb_build_object(
      'city', city, 'firstDate', first_date, 'lastDate', last_date,
      'rowCount', row_count) order by city), '[]'::jsonb) from cities)
  ) end from summary;
$$;
revoke all on function indique_ganhe_influencer.performance_coverage_for_batch(uuid)
  from public, anon, authenticated;

create or replace function indique_ganhe_influencer.capture_performance_daily_import()
returns trigger language plpgsql security definer
set search_path = pg_catalog, indique_ganhe_influencer
as $$
declare
  v_today date := (now() at time zone 'America/Sao_Paulo')::date;
begin
  if new.kind <> 'performance' or new.status <> 'completed' or old.status = 'completed' then
    return new;
  end if;
  if exists (
    select 1 from indique_ganhe_influencer.import_rows r
    where r.batch_id = new.id and (
      coalesce(jsonb_typeof(r.payload->'daily'), '') <> 'array'
      or (jsonb_typeof(r.payload->'daily') = 'array' and jsonb_array_length(r.payload->'daily') = 0)
      or exists (
        select 1 from jsonb_array_elements(r.payload->'daily') d(value)
        where coalesce(d.value->>'date', '') !~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}$'
          or coalesce(d.value->>'routes', '') !~ '^[0-9]+$'
          or coalesce(d.value->>'rowCount', '') !~ '^[1-9][0-9]*$'
          or length(trim(coalesce(d.value->>'city', ''))) = 0
      )
      or (select coalesce(sum((d.value->>'routes')::bigint), 0)
          from jsonb_array_elements(r.payload->'daily') d(value)) <> (r.payload->>'routes')::bigint
    )
  ) then
    raise exception 'Detalhamento diário da Performance ausente ou incompatível com as corridas.';
  end if;
  if exists (
    select 1 from indique_ganhe_influencer.import_rows r,
      lateral jsonb_array_elements(r.payload->'daily') d(value)
    where r.batch_id = new.id and (d.value->>'date')::date > v_today
  ) then
    raise exception 'A Performance contém uma data futura.';
  end if;

  insert into indique_ganhe_influencer.performance_daily_contributions
    (batch_id, uuid, source_date, city, route_count, row_count)
  select new.id, (r.payload->>'uuid')::uuid, (d.value->>'date')::date,
    d.value->>'city', (d.value->>'routes')::integer,
    (d.value->>'rowCount')::integer
  from indique_ganhe_influencer.import_rows r,
    lateral jsonb_array_elements(r.payload->'daily') d(value)
  where r.batch_id = new.id;
  new.performance_detail_ready := true;
  new.data_coverage := indique_ganhe_influencer.performance_coverage_for_batch(new.id);
  return new;
end;
$$;
revoke all on function indique_ganhe_influencer.capture_performance_daily_import()
  from public, anon, authenticated;
create trigger capture_performance_daily_import
  before update of status on indique_ganhe_influencer.import_batches
  for each row execute function indique_ganhe_influencer.capture_performance_daily_import();

create or replace function indique_ganhe_influencer.begin_performance_detail_backfill(p_file_hash text)
returns jsonb language plpgsql security definer
set search_path = pg_catalog, indique_ganhe_influencer
as $$
declare v_count integer;
begin
  if not indique_ganhe_influencer.is_admin() then raise exception 'Acesso restrito.'; end if;
  if p_file_hash !~ '^[0-9a-f]{64}$' then raise exception 'Hash inválido.'; end if;
  select count(*) into v_count from indique_ganhe_influencer.import_batches
  where kind = 'performance' and status = 'completed' and file_hash = p_file_hash;
  if v_count = 0 then raise exception 'Nenhuma importação concluída corresponde a esse arquivo.'; end if;
  delete from indique_ganhe_influencer.performance_detail_staging
    where actor_id = auth.uid() and file_hash = p_file_hash;
  return jsonb_build_object('imports', v_count);
end;
$$;

create or replace function indique_ganhe_influencer.append_performance_detail_backfill(
  p_file_hash text, p_rows jsonb
) returns jsonb language plpgsql security definer
set search_path = pg_catalog, indique_ganhe_influencer
as $$
declare v_today date := (now() at time zone 'America/Sao_Paulo')::date;
begin
  if not indique_ganhe_influencer.is_admin() then raise exception 'Acesso restrito.'; end if;
  if p_file_hash !~ '^[0-9a-f]{64}$' or jsonb_typeof(p_rows) <> 'array'
    or jsonb_array_length(p_rows) < 1 or jsonb_array_length(p_rows) > 300 then
    raise exception 'Lote de datas inválido.';
  end if;
  if exists (select 1 from jsonb_array_elements(p_rows) r(value)
    where coalesce(r.value->>'uuid', '') !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
      or coalesce(r.value->>'date', '') !~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}$'
      or coalesce(r.value->>'routes', '') !~ '^[0-9]+$'
      or coalesce(r.value->>'rowCount', '') !~ '^[1-9][0-9]*$'
      or length(trim(coalesce(r.value->>'city', ''))) = 0
  ) then raise exception 'Linha de data inválida.'; end if;
  if exists (select 1 from jsonb_array_elements(p_rows) r(value)
    where (r.value->>'date')::date > v_today) then
    raise exception 'O arquivo contém data futura.';
  end if;
  insert into indique_ganhe_influencer.performance_detail_staging
    (actor_id, file_hash, uuid, source_date, city, route_count, row_count)
  select auth.uid(), p_file_hash, (r.value->>'uuid')::uuid,
    (r.value->>'date')::date, r.value->>'city',
    (r.value->>'routes')::integer, (r.value->>'rowCount')::integer
  from jsonb_array_elements(p_rows) r(value)
  on conflict (actor_id, file_hash, uuid, source_date, city) do update
    set route_count = excluded.route_count, row_count = excluded.row_count;
  return jsonb_build_object('received', jsonb_array_length(p_rows));
end;
$$;

create or replace function indique_ganhe_influencer.finish_performance_detail_backfill(
  p_file_hash text, p_expected_rows integer
) returns jsonb language plpgsql security definer
set search_path = pg_catalog, indique_ganhe_influencer
as $$
declare v_batch record; v_count integer := 0; v_row_count bigint;
begin
  if not indique_ganhe_influencer.is_admin() then raise exception 'Acesso restrito.'; end if;
  if p_file_hash !~ '^[0-9a-f]{64}$' or p_expected_rows < 1 then
    raise exception 'Arquivo inválido.';
  end if;
  perform pg_advisory_xact_lock(hashtext('indique_ganhe:performance'));
  select coalesce(sum(row_count), 0) into v_row_count
    from indique_ganhe_influencer.performance_detail_staging
    where actor_id = auth.uid() and file_hash = p_file_hash;
  if v_row_count <> p_expected_rows then
    raise exception 'O detalhamento recebido tem % de % linhas esperadas.', v_row_count, p_expected_rows;
  end if;
  for v_batch in select id from indique_ganhe_influencer.import_batches
    where kind = 'performance' and status = 'completed'
      and file_hash = p_file_hash and not performance_detail_ready
    for update
  loop
    if exists (
      with expected as (
        select uuid, route_count from indique_ganhe_influencer.performance_contributions
        where batch_id = v_batch.id
      ), actual as (
        select uuid, sum(route_count) as route_count
        from indique_ganhe_influencer.performance_detail_staging
        where actor_id = auth.uid() and file_hash = p_file_hash group by uuid
      )
      select 1 from expected e full join actual a using (uuid)
      where e.uuid is null or a.uuid is null or e.route_count <> a.route_count
    ) then
      raise exception 'As corridas do arquivo não correspondem ao lote original. Nenhum dado foi alterado.';
    end if;
    insert into indique_ganhe_influencer.performance_daily_contributions
      (batch_id, uuid, source_date, city, route_count, row_count)
    select v_batch.id, uuid, source_date, city, route_count, row_count
    from indique_ganhe_influencer.performance_detail_staging
    where actor_id = auth.uid() and file_hash = p_file_hash;
    update indique_ganhe_influencer.import_batches
      set performance_detail_ready = true,
        data_coverage = indique_ganhe_influencer.performance_coverage_for_batch(v_batch.id)
      where id = v_batch.id;
    insert into indique_ganhe_influencer.import_activity
      (batch_id, actor_id, event_type, message, details)
    values (v_batch.id, auth.uid(), 'coverage_updated',
      'Datas de cada corrida recuperadas do arquivo original, sem somar corridas.',
      jsonb_build_object('row_count', v_row_count));
    v_count := v_count + 1;
  end loop;
  if v_count = 0 then raise exception 'Todas as importações deste arquivo já têm datas detalhadas.'; end if;
  delete from indique_ganhe_influencer.performance_detail_staging
    where actor_id = auth.uid() and file_hash = p_file_hash;
  return jsonb_build_object('updatedImports', v_count);
end;
$$;

create or replace function indique_ganhe_influencer.preview_performance_period_delete(
  p_from date, p_to date, p_city text default null
) returns jsonb language plpgsql stable security definer
set search_path = pg_catalog, indique_ganhe_influencer
as $$
declare v_result jsonb; v_blockers integer;
begin
  if not indique_ganhe_influencer.is_admin() then raise exception 'Acesso restrito.'; end if;
  if p_from is null or p_to is null or p_from > p_to or
    p_to > (now() at time zone 'America/Sao_Paulo')::date then
    raise exception 'Informe um intervalo de datas válido, sem datas futuras.';
  end if;
  select count(*) into v_blockers from indique_ganhe_influencer.import_batches b
  where b.kind = 'performance' and b.status = 'completed'
    and not b.performance_detail_ready
    and exists (select 1 from indique_ganhe_influencer.performance_contributions c
      where c.batch_id = b.id);
  select jsonb_build_object(
    'legacyImports', v_blockers,
    'routes', coalesce(sum(route_count), 0),
    'rows', coalesce(sum(row_count), 0),
    'couriers', count(distinct uuid),
    'imports', count(distinct batch_id)
  ) into v_result
  from indique_ganhe_influencer.performance_daily_contributions
  where source_date between p_from and p_to
    and (nullif(trim(p_city), '') is null or lower(city) = lower(trim(p_city)));
  return v_result;
end;
$$;

create or replace function indique_ganhe_influencer.delete_performance_period(
  p_from date, p_to date, p_city text default null,
  p_expected_routes bigint default null, p_expected_rows bigint default null
) returns jsonb language plpgsql security definer
set search_path = pg_catalog, indique_ganhe_influencer
as $$
declare v_preview jsonb; v_id uuid; v_batch record;
begin
  if not indique_ganhe_influencer.is_admin() then raise exception 'Acesso restrito.'; end if;
  perform pg_advisory_xact_lock(hashtext('indique_ganhe:performance'));
  v_preview := indique_ganhe_influencer.preview_performance_period_delete(p_from, p_to, p_city);
  if (v_preview->>'legacyImports')::integer > 0 then
    raise exception 'Há importações antigas sem datas por corrida. Recupere o detalhamento dos arquivos originais antes de excluir.';
  end if;
  if p_expected_routes is null or p_expected_rows is null
    or (v_preview->>'routes')::bigint <> p_expected_routes
    or (v_preview->>'rows')::bigint <> p_expected_rows then
    raise exception 'A prévia mudou. Consulte novamente antes de excluir.';
  end if;
  if p_expected_rows = 0 then raise exception 'Nenhuma corrida encontrada nesse intervalo.'; end if;
  insert into indique_ganhe_influencer.performance_deletions
    (actor_id, date_from, date_to, city, route_count, row_count,
      affected_couriers, affected_imports)
  values (auth.uid(), p_from, p_to, nullif(trim(p_city), ''),
    p_expected_routes, p_expected_rows,
    (v_preview->>'couriers')::integer, (v_preview->>'imports')::integer)
  returning id into v_id;
  with removed as (
    delete from indique_ganhe_influencer.performance_daily_contributions
    where source_date between p_from and p_to
      and (nullif(trim(p_city), '') is null or lower(city) = lower(trim(p_city)))
    returning *
  )
  insert into indique_ganhe_influencer.performance_deleted_rows
    (deletion_id, batch_id, uuid, source_date, city, route_count, row_count)
  select v_id, batch_id, uuid, source_date, city, route_count, row_count from removed;

  update indique_ganhe_influencer.performance_contributions c
  set route_count = coalesce((select sum(d.route_count)::integer
    from indique_ganhe_influencer.performance_daily_contributions d
    where d.batch_id = c.batch_id and d.uuid = c.uuid), 0)
  where exists (select 1 from indique_ganhe_influencer.performance_deleted_rows r
    where r.deletion_id = v_id and r.batch_id = c.batch_id and r.uuid = c.uuid);
  update indique_ganhe_influencer.performance_totals t
  set route_count = coalesce((select sum(c.route_count)
    from indique_ganhe_influencer.performance_contributions c
    where c.uuid = t.uuid), 0), updated_at = now()
  where exists (select 1 from indique_ganhe_influencer.performance_deleted_rows r
    where r.deletion_id = v_id and r.uuid = t.uuid);
  for v_batch in select distinct batch_id from indique_ganhe_influencer.performance_deleted_rows
    where deletion_id = v_id
  loop
    update indique_ganhe_influencer.import_batches
    set data_coverage = indique_ganhe_influencer.performance_coverage_for_batch(v_batch.batch_id)
    where id = v_batch.batch_id;
    insert into indique_ganhe_influencer.import_activity
      (batch_id, actor_id, event_type, message, details)
    values (v_batch.batch_id, auth.uid(), 'coverage_updated',
      'Corridas removidas por intervalo de datas.',
      jsonb_build_object('deletion_id', v_id, 'from', p_from, 'to', p_to, 'city', p_city));
  end loop;
  return v_preview || jsonb_build_object('deletionId', v_id);
end;
$$;

revoke all on function indique_ganhe_influencer.begin_performance_detail_backfill(text),
  indique_ganhe_influencer.append_performance_detail_backfill(text, jsonb),
  indique_ganhe_influencer.finish_performance_detail_backfill(text, integer),
  indique_ganhe_influencer.preview_performance_period_delete(date, date, text),
  indique_ganhe_influencer.delete_performance_period(date, date, text, bigint, bigint)
  from public, anon;
grant execute on function indique_ganhe_influencer.begin_performance_detail_backfill(text),
  indique_ganhe_influencer.append_performance_detail_backfill(text, jsonb),
  indique_ganhe_influencer.finish_performance_detail_backfill(text, integer),
  indique_ganhe_influencer.preview_performance_period_delete(date, date, text),
  indique_ganhe_influencer.delete_performance_period(date, date, text, bigint, bigint)
  to authenticated;

create or replace function indique_ganhe_influencer.performance_data_coverage()
returns jsonb
language plpgsql
stable
security invoker
set search_path = pg_catalog, indique_ganhe_influencer
as $$
declare
  v_result jsonb;
begin
  if not indique_ganhe_influencer.is_admin() then
    raise exception 'Apenas a administração pode consultar a cobertura da Performance.';
  end if;

  with completed_batches as (
    select b.id, b.data_coverage, b.performance_detail_ready
    from indique_ganhe_influencer.import_batches b
    where b.kind = 'performance'
      and b.status = 'completed'
  ), batch_ranges as (
    select
      b.id,
      case when b.data_coverage->>'firstDate' ~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}$'
        then (b.data_coverage->>'firstDate')::date end as first_date,
      case when b.data_coverage->>'lastDate' ~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}$'
        then (b.data_coverage->>'lastDate')::date end as last_date,
      case when b.data_coverage->>'rowCount' ~ '^[0-9]+$'
        then (b.data_coverage->>'rowCount')::bigint else 0 end as row_count
    from completed_batches b
  ), city_ranges as (
    select
      b.id,
      c.value->>'city' as city,
      case when c.value->>'firstDate' ~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}$'
        then (c.value->>'firstDate')::date end as first_date,
      case when c.value->>'lastDate' ~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}$'
        then (c.value->>'lastDate')::date end as last_date,
      case when c.value->>'rowCount' ~ '^[0-9]+$'
        then (c.value->>'rowCount')::bigint else 0 end as row_count
    from completed_batches b
    cross join lateral jsonb_array_elements(
      case when jsonb_typeof(b.data_coverage->'cities') = 'array'
        then b.data_coverage->'cities' else '[]'::jsonb end
    ) as c(value)
    where c.value->>'firstDate' ~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}$'
      and c.value->>'lastDate' ~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}$'
  ), totals as (
    select
      min(first_date) as first_date,
      max(last_date) as last_date,
      coalesce(sum(row_count), 0) as row_count,
      count(*) filter (where first_date is not null and last_date is not null) as import_count
    from batch_ranges
  ), cities as (
    select
      city,
      min(first_date) as first_date,
      max(last_date) as last_date,
      sum(row_count) as row_count,
      count(distinct id) as import_count
    from city_ranges
    where city is not null and first_date is not null and last_date is not null
    group by city
  )
  select jsonb_build_object(
    'firstDate', totals.first_date,
    'lastDate', totals.last_date,
    'rowCount', totals.row_count,
    'importCount', totals.import_count,
    'uncapturedImportCount', (select count(*) from completed_batches b where b.data_coverage->>'firstDate' is null and not b.performance_detail_ready),
    'cities', coalesce((
      select jsonb_agg(jsonb_build_object(
        'city', cities.city,
        'firstDate', cities.first_date,
        'lastDate', cities.last_date,
        'rowCount', cities.row_count,
        'importCount', cities.import_count
      ) order by cities.city)
      from cities
    ), '[]'::jsonb)
  ) into v_result
  from totals;

  return v_result;
end;
$$;


commit;
