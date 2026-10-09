alter table indique_ganhe_influencer.import_batches
  add column if not exists data_coverage jsonb not null default '{}'::jsonb;

alter table indique_ganhe_influencer.import_activity
  drop constraint if exists import_activity_event_type_check;
alter table indique_ganhe_influencer.import_activity
  add constraint import_activity_event_type_check
  check (event_type in ('started', 'progress', 'completed', 'failed', 'cancelled', 'coverage_updated', 'legacy'));

create or replace function indique_ganhe_influencer.validate_performance_data_coverage(p_data_coverage jsonb)
returns void
language plpgsql
immutable
security invoker
set search_path = pg_catalog, indique_ganhe_influencer
as $$
declare
  v_first_date date;
  v_last_date date;
  v_city jsonb;
  v_city_first date;
  v_city_last date;
  v_city_count bigint;
  v_total_city_count bigint := 0;
begin
  if p_data_coverage is null or jsonb_typeof(p_data_coverage) is distinct from 'object' then
    raise exception 'O intervalo dos dados de Performance está inválido.';
  end if;
  if p_data_coverage = '{}'::jsonb then
    return;
  end if;
  if coalesce(p_data_coverage->>'firstDate', '') !~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}$'
    or coalesce(p_data_coverage->>'lastDate', '') !~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}$'
    or coalesce(p_data_coverage->>'rowCount', '') !~ '^[0-9]+$'
    or jsonb_typeof(p_data_coverage->'cities') is distinct from 'array' then
    raise exception 'O intervalo dos dados de Performance está incompleto.';
  end if;
  if jsonb_array_length(p_data_coverage->'cities') < 1
    or jsonb_array_length(p_data_coverage->'cities') > 500 then
    raise exception 'A cobertura da Performance precisa conter entre 1 e 500 cidades.';
  end if;

  begin
    v_first_date := (p_data_coverage->>'firstDate')::date;
    v_last_date := (p_data_coverage->>'lastDate')::date;
    v_city_count := (p_data_coverage->>'rowCount')::bigint;
  exception when others then
    raise exception 'A data ou a quantidade de linhas da Performance é inválida.';
  end;
  if to_char(v_first_date, 'YYYY-MM-DD') <> p_data_coverage->>'firstDate'
    or to_char(v_last_date, 'YYYY-MM-DD') <> p_data_coverage->>'lastDate'
    or v_first_date > v_last_date
    or v_city_count < 1
    or v_city_count > 100000 then
    raise exception 'O intervalo geral da Performance não é válido.';
  end if;

  for v_city in select value from jsonb_array_elements(p_data_coverage->'cities') as cities(value)
  loop
    if jsonb_typeof(v_city) is distinct from 'object'
      or length(btrim(coalesce(v_city->>'city', ''))) < 1
      or length(btrim(v_city->>'city')) > 120
      or coalesce(v_city->>'firstDate', '') !~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}$'
      or coalesce(v_city->>'lastDate', '') !~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}$'
      or coalesce(v_city->>'rowCount', '') !~ '^[0-9]+$' then
      raise exception 'Uma cidade tem dados de cobertura inválidos.';
    end if;
    begin
      v_city_first := (v_city->>'firstDate')::date;
      v_city_last := (v_city->>'lastDate')::date;
      v_city_count := (v_city->>'rowCount')::bigint;
    exception when others then
      raise exception 'Uma cidade tem data ou quantidade de linhas inválida.';
    end;
    if to_char(v_city_first, 'YYYY-MM-DD') <> v_city->>'firstDate'
      or to_char(v_city_last, 'YYYY-MM-DD') <> v_city->>'lastDate'
      or v_city_first > v_city_last
      or v_city_count < 1
      or v_city_count > 100000 then
      raise exception 'O intervalo de uma cidade não é válido.';
    end if;
    v_total_city_count := v_total_city_count + v_city_count;
  end loop;

  if v_total_city_count <> (p_data_coverage->>'rowCount')::bigint then
    raise exception 'A quantidade de linhas por cidade não corresponde ao total.';
  end if;
end;
$$;

revoke all on function indique_ganhe_influencer.validate_performance_data_coverage(jsonb) from public, anon, authenticated;

create or replace function indique_ganhe_influencer.start_import(
  p_kind text,
  p_file_name text,
  p_file_hash text,
  p_metrics jsonb,
  p_total_rows integer,
  p_data_coverage jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = pg_catalog, indique_ganhe_influencer
as $$
declare
  v_id uuid;
  v_duplicate boolean;
  v_metrics jsonb := coalesce(p_metrics, '{}'::jsonb);
  v_coverage jsonb := coalesce(p_data_coverage, '{}'::jsonb);
begin
  if not indique_ganhe_influencer.is_admin() then
    raise exception 'Apenas a administração pode importar arquivos.';
  end if;
  if p_kind is distinct from 'performance' then
    raise exception 'Data Crazy agora é sincronizado pela API.';
  end if;
  if p_total_rows is null or p_total_rows < 1 or p_total_rows > 100000 then
    raise exception 'Quantidade de registros inválida.';
  end if;
  if p_file_hash is null or p_file_hash !~ '^[0-9a-f]{64}$' then
    raise exception 'Hash do arquivo inválido.';
  end if;
  perform indique_ganhe_influencer.validate_performance_data_coverage(v_coverage);
  if v_coverage = '{}'::jsonb then
    raise exception 'O arquivo precisa conter as datas dos dados na coluna A.';
  end if;

  select exists (
    select 1
    from indique_ganhe_influencer.import_batches b
    where b.kind = 'performance'
      and b.file_hash = p_file_hash
      and b.status = 'completed'
  ) into v_duplicate;

  insert into indique_ganhe_influencer.import_batches
    (kind, file_name, file_hash, metrics, expected_rows, created_by, source, data_coverage)
  values (
    'performance', left(coalesce(p_file_name, 'arquivo'), 255), p_file_hash,
    v_metrics, p_total_rows, auth.uid(), 'file', v_coverage
  ) returning id into v_id;

  insert into indique_ganhe_influencer.import_activity
    (batch_id, actor_id, event_type, message, details)
  values (
    v_id, auth.uid(), 'started', 'Importação de Performance iniciada.',
    jsonb_build_object(
      'expected_rows', p_total_rows,
      'metrics', v_metrics,
      'data_coverage', v_coverage,
      'duplicate_file', v_duplicate
    )
  );
  return jsonb_build_object('batchId', v_id, 'duplicateFile', v_duplicate);
end;
$$;

revoke all on function indique_ganhe_influencer.start_import(text, text, text, jsonb, integer, jsonb) from public, anon;
grant execute on function indique_ganhe_influencer.start_import(text, text, text, jsonb, integer, jsonb) to authenticated;

create or replace function indique_ganhe_influencer.update_performance_data_coverage(
  p_file_hash text,
  p_data_coverage jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = pg_catalog, indique_ganhe_influencer
as $$
declare
  v_batch_id uuid;
  v_updated integer := 0;
  v_coverage jsonb := coalesce(p_data_coverage, '{}'::jsonb);
begin
  if not indique_ganhe_influencer.is_admin() then
    raise exception 'Apenas a administração pode atualizar os períodos.';
  end if;
  if p_file_hash is null or p_file_hash !~ '^[0-9a-f]{64}$' then
    raise exception 'Hash do arquivo inválido.';
  end if;
  perform indique_ganhe_influencer.validate_performance_data_coverage(v_coverage);
  if v_coverage = '{}'::jsonb then
    raise exception 'O arquivo não contém um período de dados válido.';
  end if;

  for v_batch_id in
    update indique_ganhe_influencer.import_batches b
    set data_coverage = v_coverage
    where b.kind = 'performance'
      and b.file_hash = p_file_hash
      and b.status = 'completed'
    returning b.id
  loop
    insert into indique_ganhe_influencer.import_activity
      (batch_id, actor_id, event_type, message, details)
    values (
      v_batch_id,
      auth.uid(),
      'coverage_updated',
      'Período da planilha recuperado sem somar corridas.',
      jsonb_build_object(
        'first_date', v_coverage->>'firstDate',
        'last_date', v_coverage->>'lastDate',
        'row_count', v_coverage->'rowCount',
        'city_count', jsonb_array_length(v_coverage->'cities')
      )
    );
    v_updated := v_updated + 1;
  end loop;

  if v_updated = 0 then
    raise exception 'Não encontramos uma importação concluída com o mesmo arquivo. Selecione o arquivo original que já foi importado.';
  end if;
  return jsonb_build_object('updatedImports', v_updated);
end;
$$;

revoke all on function indique_ganhe_influencer.update_performance_data_coverage(text, jsonb) from public, anon;
grant execute on function indique_ganhe_influencer.update_performance_data_coverage(text, jsonb) to authenticated;

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
    select b.id, b.data_coverage
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
    'uncapturedImportCount', (select count(*) from completed_batches b where b.data_coverage->>'firstDate' is null),
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

revoke execute on function indique_ganhe_influencer.performance_data_coverage() from public, anon;
grant execute on function indique_ganhe_influencer.performance_data_coverage() to authenticated;
