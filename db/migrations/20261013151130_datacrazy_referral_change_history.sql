begin;

create table indique_ganhe_influencer.data_crazy_referral_changes (
  id bigint generated always as identity primary key,
  batch_id uuid not null references indique_ganhe_influencer.import_batches(id) on delete cascade,
  uuid uuid not null,
  change_type text not null check (change_type in ('added', 'updated', 'removed')),
  changed_fields text[] not null default '{}'::text[],
  previous_influencer_id text references indique_ganhe_influencer.influencers(id) on delete set null,
  new_influencer_id text references indique_ganhe_influencer.influencers(id) on delete set null,
  created_at timestamptz not null default now(),
  unique (batch_id, uuid),
  check (cardinality(changed_fields) > 0)
);
create index data_crazy_referral_changes_recent_idx
  on indique_ganhe_influencer.data_crazy_referral_changes (created_at desc, id desc);

alter table indique_ganhe_influencer.data_crazy_referral_changes enable row level security;
revoke all on indique_ganhe_influencer.data_crazy_referral_changes from public, anon, authenticated;
grant select on indique_ganhe_influencer.data_crazy_referral_changes to authenticated;
grant select, insert, update, delete on indique_ganhe_influencer.data_crazy_referral_changes to service_role;
grant usage, select on sequence indique_ganhe_influencer.data_crazy_referral_changes_id_seq to service_role;
create policy data_crazy_referral_changes_admin_read
  on indique_ganhe_influencer.data_crazy_referral_changes
  for select to authenticated using (indique_ganhe_influencer.is_admin());

-- Preserve the existing atomic publisher as a private core. A wrapper snapshots
-- the prior API state, invokes it, and records only changed field names and
-- attribution IDs; it never stores old phone, CPF, name, or region values.
alter function indique_ganhe_influencer.publish_data_crazy_sync(uuid, uuid)
  rename to publish_data_crazy_sync_core;
revoke all on function indique_ganhe_influencer.publish_data_crazy_sync_core(uuid, uuid)
  from public, anon, authenticated;

create or replace function indique_ganhe_influencer.publish_data_crazy_sync(
  p_run_id uuid, p_lease_token uuid
)
returns jsonb language plpgsql security definer
set search_path = pg_catalog, indique_ganhe_influencer
as $$
declare
  v_run indique_ganhe_influencer.data_crazy_sync_runs%rowtype;
  v_result jsonb;
  v_added integer := 0;
  v_updated integer := 0;
  v_removed integer := 0;
begin
  select * into v_run from indique_ganhe_influencer.data_crazy_sync_runs r
    where r.id = p_run_id;
  if not found then raise exception 'Execução Data Crazy não encontrada.'; end if;
  perform pg_advisory_xact_lock(hashtext('indique_ganhe:data_crazy'));

  create temp table dc_sync_before on commit drop as
    select r.uuid, r.name, r.region, r.released_at, r.phone, r.cpf,
      r.phone_unavailable, r.influencer_id, r.raw_influencer
    from indique_ganhe_influencer.referrals r
    join indique_ganhe_influencer.import_batches b on b.id = r.source_batch_id
    where b.source = 'api';

  v_result := indique_ganhe_influencer.publish_data_crazy_sync_core(p_run_id, p_lease_token);

  create temp table dc_sync_after on commit drop as
    select r.uuid, r.name, r.region, r.released_at, r.phone, r.cpf,
      r.phone_unavailable, r.influencer_id, r.raw_influencer
    from indique_ganhe_influencer.referrals r
    where r.source_batch_id = v_run.batch_id;

  insert into indique_ganhe_influencer.data_crazy_referral_changes
    (batch_id, uuid, change_type, changed_fields, new_influencer_id)
  select v_run.batch_id, a.uuid, 'added', array['record']::text[], a.influencer_id
  from dc_sync_after a
  where not exists (select 1 from dc_sync_before b where b.uuid = a.uuid);

  insert into indique_ganhe_influencer.data_crazy_referral_changes
    (batch_id, uuid, change_type, changed_fields, previous_influencer_id)
  select v_run.batch_id, b.uuid, 'removed', array['record']::text[], b.influencer_id
  from dc_sync_before b
  where not exists (select 1 from dc_sync_after a where a.uuid = b.uuid);

  insert into indique_ganhe_influencer.data_crazy_referral_changes
    (batch_id, uuid, change_type, changed_fields, previous_influencer_id, new_influencer_id)
  select v_run.batch_id, b.uuid, 'updated', changes.changed_fields,
    b.influencer_id, a.influencer_id
  from dc_sync_before b
  join dc_sync_after a on a.uuid = b.uuid
  cross join lateral (
    select array_remove(array[
      case when b.name is distinct from a.name then 'name'::text end,
      case when b.region is distinct from a.region then 'region'::text end,
      case when b.released_at is distinct from a.released_at then 'released_at'::text end,
      case when b.phone is distinct from a.phone
        or b.phone_unavailable is distinct from a.phone_unavailable then 'phone'::text end,
      case when b.cpf is distinct from a.cpf then 'cpf'::text end,
      case when b.influencer_id is distinct from a.influencer_id then 'influencer'::text end,
      case when b.raw_influencer is distinct from a.raw_influencer then 'attribution'::text end
    ], null) as changed_fields
  ) changes
  where cardinality(changes.changed_fields) > 0;

  select count(*) filter (where change_type = 'added'),
    count(*) filter (where change_type = 'updated'),
    count(*) filter (where change_type = 'removed')
  into v_added, v_updated, v_removed
  from indique_ganhe_influencer.data_crazy_referral_changes c
  where c.batch_id = v_run.batch_id;

  update indique_ganhe_influencer.import_batches
  set metrics = metrics || jsonb_build_object(
    'changeAdded', coalesce(v_added, 0),
    'changeUpdated', coalesce(v_updated, 0),
    'changeRemoved', coalesce(v_removed, 0))
  where id = v_run.batch_id;

  insert into indique_ganhe_influencer.import_activity
    (batch_id, actor_id, event_type, message, details)
  values (v_run.batch_id, v_run.actor_id, 'progress',
    'Rastreio de alterações da lista Data Crazy concluído.',
    jsonb_build_object('added', coalesce(v_added, 0), 'updated', coalesce(v_updated, 0),
      'removed', coalesce(v_removed, 0), 'storedValues', false));

  return v_result || jsonb_build_object('changes', jsonb_build_object(
    'added', coalesce(v_added, 0), 'updated', coalesce(v_updated, 0),
    'removed', coalesce(v_removed, 0)));
end;
$$;

create or replace function indique_ganhe_influencer.list_recent_data_crazy_changes(
  p_limit integer default 50, p_offset integer default 0
)
returns jsonb language plpgsql stable security invoker
set search_path = pg_catalog, indique_ganhe_influencer
as $$
declare
  v_limit integer := greatest(1, least(coalesce(p_limit, 50), 100));
  v_offset integer := greatest(coalesce(p_offset, 0), 0);
  v_total integer;
  v_items jsonb;
begin
  if not indique_ganhe_influencer.is_admin() then
    raise exception 'Apenas administradores podem consultar o rastreio da Data Crazy.';
  end if;
  select count(*)::integer into v_total
  from indique_ganhe_influencer.data_crazy_referral_changes;
  select coalesce(jsonb_agg(jsonb_build_object(
    'id', rows.id,
    'batch_id', rows.batch_id,
    'uuid', rows.uuid,
    'change_type', rows.change_type,
    'changed_fields', rows.changed_fields,
    'previous_influencer_name', rows.previous_influencer_name,
    'new_influencer_name', rows.new_influencer_name,
    'actor_display_name', rows.actor_display_name,
    'actor_email', rows.actor_email,
    'created_at', rows.created_at
  ) order by rows.created_at desc, rows.id desc), '[]'::jsonb)
  into v_items
  from (
    select c.id, c.batch_id, c.uuid, c.change_type, c.changed_fields,
      old_i.name as previous_influencer_name,
      new_i.name as new_influencer_name,
      coalesce(nullif(m.display_name, ''), nullif(m.email, ''), 'Sistema') as actor_display_name,
      m.email as actor_email, c.created_at
    from indique_ganhe_influencer.data_crazy_referral_changes c
    join indique_ganhe_influencer.data_crazy_sync_runs r on r.batch_id = c.batch_id
    left join indique_ganhe_influencer.account_members m on m.user_id = r.actor_id
    left join indique_ganhe_influencer.influencers old_i on old_i.id = c.previous_influencer_id
    left join indique_ganhe_influencer.influencers new_i on new_i.id = c.new_influencer_id
    order by c.created_at desc, c.id desc
    limit v_limit offset v_offset
  ) rows;
  return jsonb_build_object('items', v_items, 'total', v_total);
end;
$$;

revoke all on function indique_ganhe_influencer.publish_data_crazy_sync(uuid, uuid)
  from public, anon, authenticated;
revoke all on function indique_ganhe_influencer.list_recent_data_crazy_changes(integer, integer)
  from public, anon;
grant execute on function indique_ganhe_influencer.publish_data_crazy_sync(uuid, uuid)
  to service_role;
grant execute on function indique_ganhe_influencer.list_recent_data_crazy_changes(integer, integer)
  to authenticated;

notify pgrst, 'reload schema';
commit;
