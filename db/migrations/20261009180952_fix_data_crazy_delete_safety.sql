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
  set status = 'completed', completed_at = now()
  where id = p_batch_id;
  delete from indique_ganhe_influencer.import_rows where batch_id = p_batch_id;
  return v_result;
end;
$$;
