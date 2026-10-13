begin;

-- Administrative assignment and payment state must outlive a Data Crazy snapshot replacement.
create table if not exists indique_ganhe_influencer.referral_admin_state (
  courier_uuid uuid primary key,
  influencer_override_id text references indique_ganhe_influencer.influencers(id),
  paid_at timestamptz,
  paid_by uuid,
  paid_influencer_id text references indique_ganhe_influencer.influencers(id),
  paid_amount_cents integer,
  updated_at timestamptz not null default now(),
  updated_by uuid,
  constraint referral_admin_state_payment_consistency check (
    (paid_at is null and paid_influencer_id is null and paid_amount_cents is null)
    or (paid_at is not null and paid_influencer_id is not null and paid_amount_cents >= 0)
  )
);

create index if not exists referral_admin_state_override_idx
  on indique_ganhe_influencer.referral_admin_state (influencer_override_id)
  where influencer_override_id is not null;

create table if not exists indique_ganhe_influencer.referral_admin_events (
  id bigint generated always as identity primary key,
  courier_uuid uuid not null,
  event_type text not null check (event_type in ('assignment_changed', 'reward_paid', 'payment_reopened')),
  actor_user_id uuid,
  actor_display_name text not null,
  actor_email text not null,
  old_influencer_id text,
  new_influencer_id text,
  amount_cents integer,
  occurred_at timestamptz not null default now()
);

create index if not exists referral_admin_events_courier_idx
  on indique_ganhe_influencer.referral_admin_events (courier_uuid, occurred_at desc, id desc);

alter table indique_ganhe_influencer.referral_admin_state enable row level security;
alter table indique_ganhe_influencer.referral_admin_events enable row level security;

drop policy if exists referral_admin_state_admin_read on indique_ganhe_influencer.referral_admin_state;
create policy referral_admin_state_admin_read
  on indique_ganhe_influencer.referral_admin_state
  for select to authenticated
  using (indique_ganhe_influencer.is_admin());

drop policy if exists referral_admin_events_admin_read on indique_ganhe_influencer.referral_admin_events;
create policy referral_admin_events_admin_read
  on indique_ganhe_influencer.referral_admin_events
  for select to authenticated
  using (indique_ganhe_influencer.is_admin());

revoke all on indique_ganhe_influencer.referral_admin_state,
  indique_ganhe_influencer.referral_admin_events from public, anon;
revoke insert, update, delete on indique_ganhe_influencer.referral_admin_state,
  indique_ganhe_influencer.referral_admin_events from authenticated;
grant select on indique_ganhe_influencer.referral_admin_state,
  indique_ganhe_influencer.referral_admin_events to authenticated;

create or replace function indique_ganhe_influencer.set_admin_referral_assignment(
  p_courier_uuid uuid,
  p_influencer_id text
)
returns jsonb
language plpgsql
security definer
set search_path = pg_catalog, indique_ganhe_influencer
as $$
declare
  v_pipeline_influencer_id text;
  v_current_influencer_id text;
  v_target_influencer_id text;
  v_actor_name text;
  v_actor_email text;
begin
  if not indique_ganhe_influencer.is_admin() then
    raise exception 'Apenas a administração pode transferir indicados.';
  end if;
  if p_courier_uuid is null then raise exception 'Selecione um entregador.'; end if;

  select r.influencer_id into v_pipeline_influencer_id
  from indique_ganhe_influencer.referrals r
  where r.uuid = p_courier_uuid and r.influencer_id is not null
  for share;
  if v_pipeline_influencer_id is null then
    raise exception 'Este entregador não está na lista atual ou não tem influenciador atribuído.';
  end if;

  if p_influencer_id is not null and not exists (
    select 1 from indique_ganhe_influencer.influencers i
    where i.id = p_influencer_id and not i.is_demo
  ) then raise exception 'Selecione um influenciador válido.'; end if;

  insert into indique_ganhe_influencer.referral_admin_state (courier_uuid)
  values (p_courier_uuid) on conflict (courier_uuid) do nothing;
  select coalesce(s.influencer_override_id, v_pipeline_influencer_id)
  into v_current_influencer_id
  from indique_ganhe_influencer.referral_admin_state s
  where s.courier_uuid = p_courier_uuid
  for update;

  v_target_influencer_id := coalesce(p_influencer_id, v_pipeline_influencer_id);
  if v_current_influencer_id = v_target_influencer_id then
    return jsonb_build_object('changed', false, 'influencer_id', v_current_influencer_id);
  end if;

  select coalesce(nullif(m.display_name, ''), nullif(split_part(m.email, '@', 1), ''), 'Administrador'), m.email
  into v_actor_name, v_actor_email
  from indique_ganhe_influencer.account_members m
  where m.user_id = auth.uid() and m.role = 'admin';

  update indique_ganhe_influencer.referral_admin_state
  set influencer_override_id = case when v_target_influencer_id = v_pipeline_influencer_id then null else v_target_influencer_id end,
      updated_at = now(), updated_by = auth.uid()
  where courier_uuid = p_courier_uuid;

  insert into indique_ganhe_influencer.referral_admin_events (
    courier_uuid, event_type, actor_user_id, actor_display_name, actor_email,
    old_influencer_id, new_influencer_id
  ) values (
    p_courier_uuid, 'assignment_changed', auth.uid(), coalesce(v_actor_name, 'Administrador'), coalesce(v_actor_email, ''),
    v_current_influencer_id, v_target_influencer_id
  );

  return jsonb_build_object('changed', true, 'influencer_id', v_target_influencer_id);
end;
$$;

create or replace function indique_ganhe_influencer.mark_admin_referral_paid(p_courier_uuid uuid)
returns jsonb
language plpgsql
security definer
set search_path = pg_catalog, indique_ganhe_influencer
as $$
declare
  v_influencer_id text;
  v_route_goal integer;
  v_prize_cents integer;
  v_routes bigint;
  v_paid_at timestamptz := now();
  v_actor_name text;
  v_actor_email text;
begin
  if not indique_ganhe_influencer.is_admin() then
    raise exception 'Apenas a administração pode registrar pagamentos.';
  end if;
  if p_courier_uuid is null then raise exception 'Selecione um entregador.'; end if;

  insert into indique_ganhe_influencer.referral_admin_state (courier_uuid)
  values (p_courier_uuid) on conflict (courier_uuid) do nothing;
  select coalesce(s.influencer_override_id, r.influencer_id), i.route_goal, i.prize_cents,
         coalesce(t.route_count, 0)::bigint
  into v_influencer_id, v_route_goal, v_prize_cents, v_routes
  from indique_ganhe_influencer.referrals r
  join indique_ganhe_influencer.referral_admin_state s on s.courier_uuid = r.uuid
  join indique_ganhe_influencer.influencers i on i.id = coalesce(s.influencer_override_id, r.influencer_id)
  left join indique_ganhe_influencer.performance_totals t on t.uuid = r.uuid
  where r.uuid = p_courier_uuid and not i.is_demo
  for update of s;
  if v_influencer_id is null then raise exception 'Este entregador não está na lista atual.'; end if;
  if v_routes < v_route_goal then raise exception 'A meta de corridas ainda não foi atingida.'; end if;

  if exists (
    select 1 from indique_ganhe_influencer.referral_admin_state s
    where s.courier_uuid = p_courier_uuid and s.paid_at is not null
  ) then raise exception 'Este prêmio já está marcado como pago.'; end if;

  select coalesce(nullif(m.display_name, ''), nullif(split_part(m.email, '@', 1), ''), 'Administrador'), m.email
  into v_actor_name, v_actor_email
  from indique_ganhe_influencer.account_members m
  where m.user_id = auth.uid() and m.role = 'admin';

  update indique_ganhe_influencer.referral_admin_state
  set paid_at = v_paid_at, paid_by = auth.uid(), paid_influencer_id = v_influencer_id,
      paid_amount_cents = v_prize_cents, updated_at = v_paid_at, updated_by = auth.uid()
  where courier_uuid = p_courier_uuid and paid_at is null;
  if not found then raise exception 'Este prêmio já está marcado como pago.'; end if;

  insert into indique_ganhe_influencer.referral_admin_events (
    courier_uuid, event_type, actor_user_id, actor_display_name, actor_email,
    old_influencer_id, new_influencer_id, amount_cents
  ) values (
    p_courier_uuid, 'reward_paid', auth.uid(), coalesce(v_actor_name, 'Administrador'), coalesce(v_actor_email, ''),
    v_influencer_id, v_influencer_id, v_prize_cents
  );

  return jsonb_build_object('paid', true, 'paid_at', v_paid_at, 'amount_cents', v_prize_cents);
end;
$$;

create or replace function indique_ganhe_influencer.reopen_admin_referral_payment(p_courier_uuid uuid)
returns jsonb
language plpgsql
security definer
set search_path = pg_catalog, indique_ganhe_influencer
as $$
declare
  v_paid_influencer_id text;
  v_amount_cents integer;
  v_current_influencer_id text;
  v_pipeline_influencer_id text;
  v_actor_name text;
  v_actor_email text;
begin
  if not indique_ganhe_influencer.is_admin() then
    raise exception 'Apenas a administração pode reabrir pagamentos.';
  end if;
  if p_courier_uuid is null then raise exception 'Selecione um entregador.'; end if;

  select s.paid_influencer_id, s.paid_amount_cents, coalesce(s.influencer_override_id, r.influencer_id), r.influencer_id
  into v_paid_influencer_id, v_amount_cents, v_current_influencer_id, v_pipeline_influencer_id
  from indique_ganhe_influencer.referral_admin_state s
  join indique_ganhe_influencer.referrals r on r.uuid = s.courier_uuid
  where s.courier_uuid = p_courier_uuid and s.paid_at is not null
  for update of s;
  if v_paid_influencer_id is null then raise exception 'Este prêmio não está marcado como pago.'; end if;

  select coalesce(nullif(m.display_name, ''), nullif(split_part(m.email, '@', 1), ''), 'Administrador'), m.email
  into v_actor_name, v_actor_email
  from indique_ganhe_influencer.account_members m
  where m.user_id = auth.uid() and m.role = 'admin';

  update indique_ganhe_influencer.referral_admin_state
  set paid_at = null, paid_by = null, paid_influencer_id = null, paid_amount_cents = null,
      updated_at = now(), updated_by = auth.uid()
  where courier_uuid = p_courier_uuid;

  insert into indique_ganhe_influencer.referral_admin_events (
    courier_uuid, event_type, actor_user_id, actor_display_name, actor_email,
    old_influencer_id, new_influencer_id, amount_cents
  ) values (
    p_courier_uuid, 'payment_reopened', auth.uid(), coalesce(v_actor_name, 'Administrador'), coalesce(v_actor_email, ''),
    v_paid_influencer_id, v_current_influencer_id, v_amount_cents
  );

  return jsonb_build_object('reopened', true, 'influencer_id', v_current_influencer_id);
end;
$$;

create or replace function indique_ganhe_influencer.admin_referrals_page_filtered(
  p_reward_status text,
  p_limit integer default 50,
  p_offset integer default 0,
  p_influencer_id text default 'all',
  p_search text default ''
)
returns jsonb
language plpgsql
stable
security definer
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
      select r.uuid, r.name, r.region, r.released_at, r.phone, r.cpf,
        coalesce(s.influencer_override_id, r.influencer_id) as influencer_id,
        r.influencer_id as pipeline_influencer_id,
        (s.influencer_override_id is not null) as assignment_overridden,
        i.name as influencer_name, pi.name as pipeline_influencer_name,
        coalesce(t.route_count, 0)::bigint as routes,
        i.route_goal, i.prize_cents,
        coalesce(t.route_count, 0)::bigint >= i.route_goal as prize_unlocked,
        greatest(i.route_goal::bigint - coalesce(t.route_count, 0)::bigint, 0::bigint) as routes_remaining,
        case when s.paid_at is not null then 'paid'
             when coalesce(t.route_count, 0)::bigint >= i.route_goal then 'to_pay'
             else 'progress' end as reward_status,
        s.paid_at, s.paid_amount_cents, s.paid_influencer_id, paid_i.name as paid_influencer_name,
        i.sort_order as influencer_order
      from indique_ganhe_influencer.referrals r
      left join indique_ganhe_influencer.referral_admin_state s on s.courier_uuid = r.uuid
      join indique_ganhe_influencer.influencers i on i.id = coalesce(s.influencer_override_id, r.influencer_id)
      join indique_ganhe_influencer.influencers pi on pi.id = r.influencer_id
      left join indique_ganhe_influencer.influencers paid_i on paid_i.id = s.paid_influencer_id
      left join indique_ganhe_influencer.performance_totals t on t.uuid = r.uuid
      where r.influencer_id is not null and not i.is_demo
        and (v_influencer_id = 'all' or i.id = v_influencer_id)
        and (v_search = '' or strpos(lower(concat_ws(' ', r.name, r.uuid::text, r.region, r.phone, r.cpf, i.name)), v_search) > 0)
    ),
    selected as (
      select * from all_filtered where v_reward_status = 'all' or reward_status = v_reward_status
    ),
    paged as (
      select s.*, coalesce(history.items, '[]'::jsonb) as recent_events
      from selected s
      left join lateral (
        select jsonb_agg(jsonb_build_object(
          'event_type', e.event_type,
          'actor_display_name', e.actor_display_name,
          'actor_email', e.actor_email,
          'old_influencer_name', old_i.name,
          'new_influencer_name', new_i.name,
          'amount_cents', e.amount_cents,
          'occurred_at', e.occurred_at
        ) order by e.occurred_at desc, e.id desc) as items
        from (
          select ev.* from indique_ganhe_influencer.referral_admin_events ev
          where ev.courier_uuid = s.uuid order by ev.occurred_at desc, ev.id desc limit 5
        ) e
        left join indique_ganhe_influencer.influencers old_i on old_i.id = e.old_influencer_id
        left join indique_ganhe_influencer.influencers new_i on new_i.id = e.new_influencer_id
      ) history on true
      order by s.influencer_order, s.name, s.uuid
      limit p_limit offset p_offset
    )
    select jsonb_build_object(
      'items', coalesce((select jsonb_agg(to_jsonb(p) - 'influencer_order' order by p.influencer_order, p.name, p.uuid) from paged p), '[]'::jsonb),
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

create or replace function indique_ganhe_influencer.admin_referrals_page(
  p_limit integer default 50,
  p_offset integer default 0,
  p_influencer_id text default 'all',
  p_search text default ''
)
returns jsonb
language sql
stable
security invoker
set search_path = pg_catalog, indique_ganhe_influencer
as $$
  select indique_ganhe_influencer.admin_referrals_page_filtered('all', p_limit, p_offset, p_influencer_id, p_search);
$$;

revoke execute on function indique_ganhe_influencer.set_admin_referral_assignment(uuid, text) from public, anon;
revoke execute on function indique_ganhe_influencer.mark_admin_referral_paid(uuid) from public, anon;
revoke execute on function indique_ganhe_influencer.reopen_admin_referral_payment(uuid) from public, anon;
revoke execute on function indique_ganhe_influencer.admin_referrals_page_filtered(text, integer, integer, text, text) from public, anon;
revoke execute on function indique_ganhe_influencer.admin_referrals_page(integer, integer, text, text) from public, anon;
grant execute on function indique_ganhe_influencer.set_admin_referral_assignment(uuid, text) to authenticated;
grant execute on function indique_ganhe_influencer.mark_admin_referral_paid(uuid) to authenticated;
grant execute on function indique_ganhe_influencer.reopen_admin_referral_payment(uuid) to authenticated;
grant execute on function indique_ganhe_influencer.admin_referrals_page_filtered(text, integer, integer, text, text) to authenticated;
grant execute on function indique_ganhe_influencer.admin_referrals_page(integer, integer, text, text) to authenticated;

commit;
