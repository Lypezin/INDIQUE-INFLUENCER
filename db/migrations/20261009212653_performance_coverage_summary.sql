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

  with performance_rows as (
    select
      coalesce(nullif(btrim(p.fallback_region), ''), 'Praça não informada') as city,
      p.imported_at,
      p.batch_id
    from indique_ganhe_influencer.performance_contributions p
    join indique_ganhe_influencer.import_batches b on b.id = p.batch_id
    where b.kind = 'performance'
      and b.status = 'completed'
  ), totals as (
    select
      min(imported_at) as first_imported_at,
      max(imported_at) as last_imported_at,
      count(*) as record_count,
      count(distinct batch_id) as import_count
    from performance_rows
  ), cities as (
    select
      city,
      min(imported_at) as first_imported_at,
      max(imported_at) as last_imported_at,
      count(*) as record_count,
      count(distinct batch_id) as import_count
    from performance_rows
    group by city
  )
  select jsonb_build_object(
    'firstImportedAt', totals.first_imported_at,
    'lastImportedAt', totals.last_imported_at,
    'recordCount', totals.record_count,
    'importCount', totals.import_count,
    'cities', coalesce((
      select jsonb_agg(jsonb_build_object(
        'city', cities.city,
        'firstImportedAt', cities.first_imported_at,
        'lastImportedAt', cities.last_imported_at,
        'recordCount', cities.record_count,
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
