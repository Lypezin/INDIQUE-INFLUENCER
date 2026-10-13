begin;

-- Keep pipeline leads that do not yet have the courier UUID. The Data Crazy
-- lead ID is the stable key for this subset; Performance remains UUID keyed.
create table indique_ganhe_influencer.data_crazy_unidentified_referrals (
  lead_id text primary key,
  record_id uuid not null default gen_random_uuid() unique,
  name text not null default '',
  region text,
  released_at date,
  phone text,
  cpf text,
  phone_unavailable boolean not null default false,
  pipeline_influencer_id text references indique_ganhe_influencer.influencers(id),
  influencer_id text references indique_ganhe_influencer.influencers(id),
  assignment_overridden boolean not null default false,
  needs_review boolean not null default false,
  raw_influencer text not null default '',
  source_batch_id uuid not null references indique_ganhe_influencer.import_batches(id),
  updated_at timestamptz not null default now(),
  check (length(lead_id) between 1 and 128)
);
create index data_crazy_unidentified_influencer_idx
  on indique_ganhe_influencer.data_crazy_unidentified_referrals(influencer_id, name, lead_id)
  where influencer_id is not null and not needs_review;
create index data_crazy_unidentified_review_idx
  on indique_ganhe_influencer.data_crazy_unidentified_referrals(lead_id)
  where needs_review;

create table indique_ganhe_influencer.data_crazy_unidentified_referral_events (
  id bigint generated always as identity primary key,
  lead_id text not null,
  event_type text not null check (event_type = 'assignment_changed'),
  actor_user_id uuid,
  actor_display_name text not null,
  actor_email text not null,
  old_influencer_id text,
  new_influencer_id text,
  occurred_at timestamptz not null default now()
);
create index data_crazy_unidentified_referral_events_idx
  on indique_ganhe_influencer.data_crazy_unidentified_referral_events(lead_id, occurred_at desc, id desc);

alter table indique_ganhe_influencer.data_crazy_unidentified_referrals enable row level security;
alter table indique_ganhe_influencer.data_crazy_unidentified_referral_events enable row level security;
revoke all on indique_ganhe_influencer.data_crazy_unidentified_referrals,
  indique_ganhe_influencer.data_crazy_unidentified_referral_events from public, anon;
revoke all on indique_ganhe_influencer.data_crazy_unidentified_referrals,
  indique_ganhe_influencer.data_crazy_unidentified_referral_events from authenticated;
grant select on indique_ganhe_influencer.data_crazy_unidentified_referrals,
  indique_ganhe_influencer.data_crazy_unidentified_referral_events to authenticated;
grant select, insert, update, delete on indique_ganhe_influencer.data_crazy_unidentified_referrals,
  indique_ganhe_influencer.data_crazy_unidentified_referral_events to service_role;
grant usage, select on sequence indique_ganhe_influencer.data_crazy_unidentified_referral_events_id_seq to service_role;

create policy data_crazy_unidentified_owner_or_admin_read
  on indique_ganhe_influencer.data_crazy_unidentified_referrals for select to authenticated
  using (
    indique_ganhe_influencer.is_admin()
    or (not needs_review and influencer_id = indique_ganhe_influencer.current_influencer_id())
  );
create policy data_crazy_unidentified_events_admin_read
  on indique_ganhe_influencer.data_crazy_unidentified_referral_events for select to authenticated
  using (indique_ganhe_influencer.is_admin());

-- Preserve UUID assignments that an administrator already resolved. This also
-- keeps the confirmed Brocador assignment when the same lead appears in more
-- than one pipeline on a later sync.
insert into indique_ganhe_influencer.referral_admin_state
  (courier_uuid, influencer_override_id, updated_by, updated_at)
select r.uuid, resolved.influencer_id, resolved.reviewed_by,
  coalesce(resolved.reviewed_at, now())
from indique_ganhe_influencer.referrals r
join lateral (
  select ar.influencer_id, ar.reviewed_by, ar.reviewed_at
  from indique_ganhe_influencer.attribution_reviews ar
  where ar.uuid = r.uuid and ar.status = 'resolved'
    and ar.influencer_id is not null and ar.reviewed_by is not null
  order by ar.reviewed_at desc nulls last, ar.id desc
  limit 1
) resolved on resolved.influencer_id = r.influencer_id
on conflict (courier_uuid) do nothing;

create or replace function indique_ganhe_influencer.publish_data_crazy_sync_core(
  p_run_id uuid, p_lease_token uuid
)
returns jsonb language plpgsql security definer
set search_path = pg_catalog, indique_ganhe_influencer
as $$
declare
  v_run indique_ganhe_influencer.data_crazy_sync_runs%rowtype;
  v_count integer;
  v_unidentified_count integer;
  v_ambiguous integer;
  v_missing integer;
  v_invalid_uuid integer;
  v_actor uuid;
  v_prior_api_count integer;
  v_prior_indication_total integer := 0;
begin
  select * into v_run from indique_ganhe_influencer.data_crazy_sync_runs r
  where r.id = p_run_id for update;
  if not found or v_run.phase <> 'ready' or v_run.lease_token is distinct from p_lease_token
    or v_run.lease_until <= now() then
    raise exception 'Execução não está pronta ou autorização expirada.';
  end if;
  if v_run.business_total is null or v_run.lead_total is null
    or v_run.businesses_fetched <> v_run.business_total
    or v_run.leads_fetched <> v_run.lead_total then
    raise exception 'Coleta incompleta. Lista atual preservada.';
  end if;
  perform pg_advisory_xact_lock(hashtext('indique_ganhe:data_crazy'));

  create temporary table dc_sync_candidates on commit drop as
  select l.uuid, l.name, l.region, l.released_at, l.phone, l.cpf,
    l.phone_unavailable, l.lead_id, b.business_id,
    b.influencer_id as pipeline_influencer_id, b.pipeline_name,
    concat('Pipeline: ', coalesce(nullif(i.name, ''), nullif(b.pipeline_name, ''), 'sem atribuição')) as evidence
  from indique_ganhe_influencer.data_crazy_sync_leads l
  join indique_ganhe_influencer.data_crazy_sync_businesses b
    on b.run_id = l.run_id and b.lead_id = l.lead_id
  left join indique_ganhe_influencer.influencers i on i.id = b.influencer_id
  where l.run_id = p_run_id and l.uuid is not null and b.influencer_id is not null;

  create temporary table dc_sync_assignments on commit drop as
  select grouped.uuid, grouped.pipeline_count,
    grouped.pipeline_influencer_id, state.influencer_override_id,
    coalesce(state.influencer_override_id,
      case when grouped.pipeline_count = 1 then grouped.pipeline_influencer_id end) as influencer_id,
    (grouped.pipeline_count > 1 and state.influencer_override_id is null) as needs_review,
    grouped.raw_influencer
  from (
    select c.uuid, count(distinct c.pipeline_influencer_id)::integer as pipeline_count,
      min(c.pipeline_influencer_id) as pipeline_influencer_id,
      string_agg(distinct c.evidence, ' | ' order by c.evidence) as raw_influencer
    from dc_sync_candidates c group by c.uuid
  ) grouped
  left join indique_ganhe_influencer.referral_admin_state state on state.courier_uuid = grouped.uuid;

  create temporary table dc_sync_unidentified_candidates on commit drop as
  select l.lead_id, l.name, l.region, l.released_at, l.phone, l.cpf,
    l.phone_unavailable, b.business_id, b.influencer_id as pipeline_influencer_id,
    b.pipeline_name,
    concat('Pipeline: ', coalesce(nullif(i.name, ''), nullif(b.pipeline_name, ''), 'sem atribuição')) as evidence
  from indique_ganhe_influencer.data_crazy_sync_leads l
  join indique_ganhe_influencer.data_crazy_sync_businesses b
    on b.run_id = l.run_id and b.lead_id = l.lead_id
  left join indique_ganhe_influencer.influencers i on i.id = b.influencer_id
  where l.run_id = p_run_id and l.uuid is null and b.influencer_id is not null;

  create temporary table dc_sync_unidentified_assignments on commit drop as
  select grouped.lead_id, grouped.pipeline_count, grouped.pipeline_influencer_id,
    grouped.raw_influencer,
    coalesce(existing_row.influencer_id,
      case when grouped.pipeline_count = 1 then grouped.pipeline_influencer_id end) as influencer_id,
    coalesce(existing_row.assignment_overridden, false) as assignment_overridden,
    (grouped.pipeline_count > 1 and not coalesce(existing_row.assignment_overridden, false)) as needs_review
  from (
    select c.lead_id, count(distinct c.pipeline_influencer_id)::integer as pipeline_count,
      min(c.pipeline_influencer_id) as pipeline_influencer_id,
      string_agg(distinct c.evidence, ' | ' order by c.evidence) as raw_influencer
    from dc_sync_unidentified_candidates c group by c.lead_id
  ) grouped
  left join indique_ganhe_influencer.data_crazy_unidentified_referrals existing_row
    on existing_row.lead_id = grouped.lead_id;

  select count(*) into v_count from dc_sync_assignments;
  select count(*) into v_unidentified_count from dc_sync_unidentified_assignments;
  if v_count + v_unidentified_count < 1 then
    raise exception 'A API não retornou leads nas pipelines dos influenciadores. Lista atual preservada.';
  end if;

  select
    (select count(*) from indique_ganhe_influencer.referrals r
      join indique_ganhe_influencer.import_batches b on b.id = r.source_batch_id where b.source = 'api')
    + (select count(*) from indique_ganhe_influencer.data_crazy_unidentified_referrals u
      join indique_ganhe_influencer.import_batches b on b.id = u.source_batch_id where b.source = 'api')
  into v_prior_api_count;
  select coalesce(max(case when b.metrics->>'indicationTotal' ~ '^[0-9]+$'
    then (b.metrics->>'indicationTotal')::integer else 0 end), 0)
  into v_prior_indication_total
  from indique_ganhe_influencer.referrals r
  join indique_ganhe_influencer.import_batches b on b.id = r.source_batch_id where b.source = 'api';

  if v_prior_api_count >= 20 and v_prior_indication_total = 0
    and v_count + v_unidentified_count < v_prior_api_count * 0.5 then
    raise exception 'A coleta reduziu a lista da API em mais de 50%%. Lista atual preservada para revisão.';
  end if;

  select (select count(*) from dc_sync_assignments where needs_review)
    + (select count(*) from dc_sync_unidentified_assignments where needs_review)
  into v_ambiguous;
  select count(*) into v_invalid_uuid
  from indique_ganhe_influencer.data_crazy_sync_leads l
  where l.run_id = p_run_id and l.uuid is null;
  select greatest(v_run.leads_fetched - v_count - v_unidentified_count, 0)
    into v_missing;

  update indique_ganhe_influencer.attribution_reviews set status = 'superseded' where status = 'open';
  delete from indique_ganhe_influencer.referrals where uuid is not null;
  insert into indique_ganhe_influencer.referrals
    (uuid, name, region, released_at, phone, cpf, phone_unavailable,
      influencer_id, raw_influencer, source_batch_id)
  select distinct on (c.uuid) c.uuid, c.name, c.region, c.released_at,
    c.phone, c.cpf, c.phone_unavailable, a.influencer_id, a.raw_influencer, v_run.batch_id
  from dc_sync_candidates c join dc_sync_assignments a on a.uuid = c.uuid
  order by c.uuid, c.released_at desc nulls last, c.business_id desc, c.lead_id desc;

  insert into indique_ganhe_influencer.attribution_reviews
    (batch_id, uuid, name, region, raw_influencer)
  select v_run.batch_id, r.uuid, r.name, r.region, r.raw_influencer
  from indique_ganhe_influencer.referrals r
  join dc_sync_assignments a on a.uuid = r.uuid
  where r.source_batch_id = v_run.batch_id and a.needs_review;

  insert into indique_ganhe_influencer.data_crazy_unidentified_referrals
    (lead_id, name, region, released_at, phone, cpf, phone_unavailable,
      pipeline_influencer_id, influencer_id, assignment_overridden, needs_review,
      raw_influencer, source_batch_id, updated_at)
  select distinct on (c.lead_id) c.lead_id, c.name, c.region, c.released_at,
    c.phone, c.cpf, c.phone_unavailable, a.pipeline_influencer_id, a.influencer_id,
    a.assignment_overridden, a.needs_review, a.raw_influencer, v_run.batch_id, now()
  from dc_sync_unidentified_candidates c
  join dc_sync_unidentified_assignments a on a.lead_id = c.lead_id
  order by c.lead_id, c.released_at desc nulls last, c.business_id desc
  on conflict (lead_id) do update set
    name = excluded.name, region = excluded.region, released_at = excluded.released_at,
    phone = excluded.phone, cpf = excluded.cpf, phone_unavailable = excluded.phone_unavailable,
    pipeline_influencer_id = excluded.pipeline_influencer_id,
    influencer_id = excluded.influencer_id,
    assignment_overridden = excluded.assignment_overridden,
    needs_review = excluded.needs_review, raw_influencer = excluded.raw_influencer,
    source_batch_id = excluded.source_batch_id, updated_at = now();

  delete from indique_ganhe_influencer.data_crazy_unidentified_referrals current
  where not exists (
    select 1 from dc_sync_unidentified_assignments incoming where incoming.lead_id = current.lead_id
  );

  update indique_ganhe_influencer.import_batches
  set status = 'completed', completed_at = now(), finished_at = now(),
    expected_rows = v_count + v_unidentified_count,
    staged_rows = v_count + v_unidentified_count,
    metrics = metrics || jsonb_build_object(
      'businesses', v_run.businesses_fetched, 'leads', v_run.leads_fetched,
      'referrals', v_count + v_unidentified_count, 'uuidReferrals', v_count,
      'unidentified', v_unidentified_count, 'ambiguous', v_ambiguous,
      'invalid_uuid', v_invalid_uuid,
      'excludedNoPipeline', v_missing, 'indicationTotal', 0),
    error_message = null
  where id = v_run.batch_id;

  v_actor := v_run.actor_id;
  update indique_ganhe_influencer.data_crazy_sync_runs
  set phase = 'completed', completed_at = now(), updated_at = now(),
    lease_token = null, lease_until = null where id = p_run_id;
  insert into indique_ganhe_influencer.import_activity
    (batch_id, actor_id, event_type, message, details)
  values (v_run.batch_id, v_actor, 'completed',
    'Data Crazy publicou os leads das pipelines dos influenciadores, inclusive os sem UUID.',
    jsonb_build_object('referrals', v_count + v_unidentified_count, 'uuid_referrals', v_count,
      'unidentified', v_unidentified_count, 'ambiguous', v_ambiguous,
      'excluded_no_pipeline', v_missing, 'businesses', v_run.businesses_fetched,
      'leads', v_run.leads_fetched));

  delete from indique_ganhe_influencer.data_crazy_sync_businesses where run_id = p_run_id;
  delete from indique_ganhe_influencer.data_crazy_sync_leads where run_id = p_run_id;
  return jsonb_build_object('imported', v_count + v_unidentified_count,
    'uuidReferrals', v_count, 'unidentified', v_unidentified_count,
    'ambiguous', v_ambiguous, 'invalidUuid', v_invalid_uuid,
    'kind', 'data_crazy');
end;
$$;

-- Persist reviewed UUID attribution across future Data Crazy snapshots.
create or replace function indique_ganhe_influencer.assign_review(p_review_id uuid, p_influencer_id text)
returns boolean language plpgsql security definer
set search_path = pg_catalog, indique_ganhe_influencer
as $$
declare v_uuid uuid;
begin
  if not indique_ganhe_influencer.is_admin() then
    raise exception 'Apenas a administração pode revisar atribuições.';
  end if;
  if not exists (select 1 from indique_ganhe_influencer.influencers i
    where i.id = p_influencer_id and not i.is_demo) then
    raise exception 'Influenciador não encontrado.';
  end if;
  select r.uuid into v_uuid from indique_ganhe_influencer.attribution_reviews r
  where r.id = p_review_id and r.status = 'open' for update;
  if v_uuid is null then raise exception 'A revisão não está mais pendente.'; end if;
  update indique_ganhe_influencer.referrals set influencer_id = p_influencer_id, updated_at = now()
  where uuid = v_uuid;
  if not found then raise exception 'Este UUID não está na lista atual. Sincronize a Data Crazy para atualizar.'; end if;
  insert into indique_ganhe_influencer.referral_admin_state
    (courier_uuid, influencer_override_id, updated_by, updated_at)
  values (v_uuid, p_influencer_id, auth.uid(), now())
  on conflict (courier_uuid) do update set influencer_override_id = excluded.influencer_override_id,
    updated_by = excluded.updated_by, updated_at = excluded.updated_at;
  update indique_ganhe_influencer.attribution_reviews set status = 'resolved', influencer_id = p_influencer_id,
    reviewed_by = auth.uid(), reviewed_at = now() where id = p_review_id;
  return true;
end;
$$;

create or replace function indique_ganhe_influencer.set_admin_unidentified_referral_assignment(
  p_lead_id text, p_influencer_id text
)
returns jsonb language plpgsql security definer
set search_path = pg_catalog, indique_ganhe_influencer
as $$
declare
  v_pipeline_id text;
  v_current_id text;
  v_target_id text;
  v_overridden boolean;
  v_actor_name text;
  v_actor_email text;
begin
  if not indique_ganhe_influencer.is_admin() then
    raise exception 'Apenas a administração pode transferir indicados.';
  end if;
  select pipeline_influencer_id, influencer_id, assignment_overridden
  into v_pipeline_id, v_current_id, v_overridden
  from indique_ganhe_influencer.data_crazy_unidentified_referrals
  where lead_id = p_lead_id for update;
  if not found then raise exception 'Este lead não está na lista atual.'; end if;
  if p_influencer_id is not null and not exists (
    select 1 from indique_ganhe_influencer.influencers i where i.id = p_influencer_id and not i.is_demo
  ) then raise exception 'Selecione um influenciador válido.'; end if;
  if p_influencer_id is null and v_pipeline_id is null then
    raise exception 'Este lead aparece em mais de uma pipeline. Escolha manualmente o influenciador.';
  end if;
  v_target_id := coalesce(p_influencer_id, v_pipeline_id);
  if v_target_id = v_current_id and not (select needs_review
    from indique_ganhe_influencer.data_crazy_unidentified_referrals where lead_id = p_lead_id) then
    return jsonb_build_object('changed', false, 'influencer_id', v_current_id);
  end if;
  select coalesce(nullif(m.display_name, ''), nullif(split_part(m.email, '@', 1), ''), 'Administrador'), m.email
  into v_actor_name, v_actor_email
  from indique_ganhe_influencer.account_members m where m.user_id = auth.uid() and m.role = 'admin';
  update indique_ganhe_influencer.data_crazy_unidentified_referrals
  set influencer_id = v_target_id,
    assignment_overridden = (v_target_id is distinct from v_pipeline_id),
    needs_review = false, updated_at = now()
  where lead_id = p_lead_id;
  insert into indique_ganhe_influencer.data_crazy_unidentified_referral_events
    (lead_id, event_type, actor_user_id, actor_display_name, actor_email, old_influencer_id, new_influencer_id)
  values (p_lead_id, 'assignment_changed', auth.uid(), coalesce(v_actor_name, 'Administrador'),
    coalesce(v_actor_email, ''), v_current_id, v_target_id);
  return jsonb_build_object('changed', true, 'influencer_id', v_target_id);
end;
$$;
revoke all on function indique_ganhe_influencer.set_admin_unidentified_referral_assignment(text, text)
  from public, anon;
grant execute on function indique_ganhe_influencer.set_admin_unidentified_referral_assignment(text, text)
  to authenticated;

create or replace view indique_ganhe_influencer.referral_progress
with (security_invoker = true) as
select r.uuid as referral_id, r.uuid,
  coalesce(nullif(r.name, ''), t.fallback_name, '') as name,
  coalesce(nullif(r.region, ''), t.fallback_region) as region,
  r.phone, r.cpf,
  coalesce(t.route_count, 0)::bigint as routes,
  i.route_goal, i.prize_cents,
  (coalesce(t.route_count, 0) >= i.route_goal) as prize_unlocked,
  greatest(i.route_goal::bigint - coalesce(t.route_count, 0), 0)::bigint as routes_remaining,
  i.name as influencer_name, r.released_at, null::text as lead_id, false as is_unidentified,
  r.influencer_id as pipeline_influencer_id
from indique_ganhe_influencer.referrals r
join indique_ganhe_influencer.influencers i on i.id = r.influencer_id
left join indique_ganhe_influencer.performance_totals t on t.uuid = r.uuid
where r.influencer_id is not null and not i.is_demo
union all
select d.uuid as referral_id, d.uuid, d.name, d.region,
  null::text as phone, null::text as cpf, d.routes,
  i.route_goal, i.prize_cents, (d.routes >= i.route_goal),
  greatest(i.route_goal::bigint - d.routes, 0)::bigint, i.name, null::date as released_at,
  null::text as lead_id, false as is_unidentified, null::text as pipeline_influencer_id
from indique_ganhe_influencer.demo_referrals d
join indique_ganhe_influencer.influencers i on i.id = 'teste' and i.is_demo
union all
select u.record_id as referral_id, null::uuid as uuid, u.name, u.region,
  u.phone, u.cpf, 0::bigint as routes,
  i.route_goal, i.prize_cents, false as prize_unlocked,
  i.route_goal::bigint as routes_remaining, i.name, u.released_at, u.lead_id, true as is_unidentified,
  u.pipeline_influencer_id
from indique_ganhe_influencer.data_crazy_unidentified_referrals u
join indique_ganhe_influencer.influencers i on i.id = u.influencer_id
where u.influencer_id is not null and not u.needs_review and not i.is_demo;
revoke all on indique_ganhe_influencer.referral_progress from public, anon;
grant select on indique_ganhe_influencer.referral_progress to authenticated;

create or replace function indique_ganhe_influencer.admin_referrals_page_filtered(
  p_reward_status text, p_limit integer default 50, p_offset integer default 0,
  p_influencer_id text default 'all', p_search text default ''
)
returns jsonb language plpgsql stable security definer
set search_path = pg_catalog, indique_ganhe_influencer
as $$
declare
  v_influencer_id text := coalesce(nullif(btrim(p_influencer_id), ''), 'all');
  v_search text := lower(btrim(coalesce(p_search, '')));
  v_reward_status text := coalesce(nullif(btrim(p_reward_status), ''), 'all');
begin
  if not indique_ganhe_influencer.is_admin() then
    raise exception 'Apenas a administração pode consultar todos os indicados.';
  end if;
  if v_reward_status not in ('all', 'progress', 'to_pay', 'paid') then
    raise exception 'Selecione uma situação válida para os indicados.';
  end if;
  if p_limit is null or p_limit < 1 or p_limit > 100 then
    raise exception 'A quantidade por página deve ficar entre 1 e 100.';
  end if;
  if p_offset is null or p_offset < 0 then raise exception 'A página solicitada é inválida.'; end if;
  if char_length(v_search) > 120 then raise exception 'A busca deve ter até 120 caracteres.'; end if;
  if v_influencer_id <> 'all' and not exists (
    select 1 from indique_ganhe_influencer.influencers i where i.id = v_influencer_id and not i.is_demo
  ) then raise exception 'Influenciador não encontrado.'; end if;

  return (
    with all_filtered as (
      select r.uuid as referral_id, r.uuid, null::text as lead_id, false as is_unidentified,
        r.name, r.region, r.released_at, r.phone, r.cpf,
        coalesce(s.influencer_override_id, r.influencer_id) as influencer_id,
        r.influencer_id as pipeline_influencer_id,
        (s.influencer_override_id is not null) as assignment_overridden,
        i.name as influencer_name, pi.name as pipeline_influencer_name,
        coalesce(t.route_count, 0)::bigint as routes, i.route_goal, i.prize_cents,
        coalesce(t.route_count, 0)::bigint >= i.route_goal as prize_unlocked,
        greatest(i.route_goal::bigint - coalesce(t.route_count, 0)::bigint, 0::bigint) as routes_remaining,
        case when s.paid_at is not null then 'paid'
          when coalesce(t.route_count, 0)::bigint >= i.route_goal then 'to_pay' else 'progress' end as reward_status,
        s.paid_at, s.paid_amount_cents, s.paid_influencer_id, paid_i.name as paid_influencer_name,
        i.sort_order as influencer_order
      from indique_ganhe_influencer.referrals r
      left join indique_ganhe_influencer.referral_admin_state s on s.courier_uuid = r.uuid
      join indique_ganhe_influencer.influencers i on i.id = coalesce(s.influencer_override_id, r.influencer_id)
      left join indique_ganhe_influencer.influencers pi on pi.id = r.influencer_id
      left join indique_ganhe_influencer.influencers paid_i on paid_i.id = s.paid_influencer_id
      left join indique_ganhe_influencer.performance_totals t on t.uuid = r.uuid
      where coalesce(s.influencer_override_id, r.influencer_id) is not null and not i.is_demo
        and (v_influencer_id = 'all' or i.id = v_influencer_id)
        and (v_search = '' or strpos(lower(concat_ws(' ', r.name, r.uuid::text, r.region, r.phone, r.cpf, i.name)), v_search) > 0)
      union all
      select u.record_id, null::uuid, u.lead_id, true,
        u.name, u.region, u.released_at, u.phone, u.cpf, u.influencer_id,
        u.pipeline_influencer_id, u.assignment_overridden,
        i.name, pi.name, 0::bigint, i.route_goal, i.prize_cents, false,
        i.route_goal::bigint, 'progress'::text, null::timestamptz, null::integer,
        null::text, null::text, i.sort_order
      from indique_ganhe_influencer.data_crazy_unidentified_referrals u
      join indique_ganhe_influencer.influencers i on i.id = u.influencer_id
      left join indique_ganhe_influencer.influencers pi on pi.id = u.pipeline_influencer_id
      where u.influencer_id is not null and not u.needs_review and not i.is_demo
        and (v_influencer_id = 'all' or i.id = v_influencer_id)
        and (v_search = '' or strpos(lower(concat_ws(' ', u.name, u.lead_id, u.region, u.phone, u.cpf, i.name)), v_search) > 0)
    ),
    selected as (
      select * from all_filtered where v_reward_status = 'all' or reward_status = v_reward_status
    ),
    paged as (
      select selected_row.*, coalesce(history.items, '[]'::jsonb) as recent_events
      from selected selected_row
      left join lateral (
        select jsonb_agg(jsonb_build_object(
          'event_type', e.event_type, 'actor_display_name', e.actor_display_name,
          'actor_email', e.actor_email, 'old_influencer_name', old_i.name,
          'new_influencer_name', new_i.name, 'amount_cents', e.amount_cents,
          'occurred_at', e.occurred_at
        ) order by e.occurred_at desc, e.id desc) as items
        from (
          select ev.id, ev.event_type, ev.actor_display_name, ev.actor_email,
            ev.old_influencer_id, ev.new_influencer_id, ev.amount_cents, ev.occurred_at
          from indique_ganhe_influencer.referral_admin_events ev
          where selected_row.uuid is not null and ev.courier_uuid = selected_row.uuid
          union all
          select ev.id, ev.event_type, ev.actor_display_name, ev.actor_email,
            ev.old_influencer_id, ev.new_influencer_id, null::integer, ev.occurred_at
          from indique_ganhe_influencer.data_crazy_unidentified_referral_events ev
          where selected_row.is_unidentified and ev.lead_id = selected_row.lead_id
          order by occurred_at desc, id desc limit 5
        ) e
        left join indique_ganhe_influencer.influencers old_i on old_i.id = e.old_influencer_id
        left join indique_ganhe_influencer.influencers new_i on new_i.id = e.new_influencer_id
      ) history on true
      order by selected_row.influencer_order, selected_row.name, selected_row.uuid nulls last, selected_row.lead_id
      limit p_limit offset p_offset
    )
    select jsonb_build_object(
      'items', coalesce((select jsonb_agg(to_jsonb(p) - 'influencer_order'
        order by p.influencer_order, p.name, p.uuid nulls last, p.lead_id) from paged p), '[]'::jsonb),
      'total', (select count(*) from selected),
      'totalRoutes', (select coalesce(sum(s.routes), 0) from selected s),
      'unlockedCount', (select count(*) from selected s where s.prize_unlocked),
      'unlockedPrizeCents', (select coalesce(sum(case when s.paid_at is not null then s.paid_amount_cents else s.prize_cents end), 0) from selected s where s.prize_unlocked),
      'statusCounts', jsonb_build_object(
        'progress', (select count(*) from all_filtered f where f.reward_status = 'progress'),
        'to_pay', (select count(*) from all_filtered f where f.reward_status = 'to_pay'),
        'paid', (select count(*) from all_filtered f where f.reward_status = 'paid')
      )
    )
  );
end;
$$;
revoke execute on function indique_ganhe_influencer.admin_referrals_page_filtered(text, integer, integer, text, text)
  from public, anon;
grant execute on function indique_ganhe_influencer.admin_referrals_page_filtered(text, integer, integer, text, text)
  to authenticated;

notify pgrst, 'reload schema';
commit;
