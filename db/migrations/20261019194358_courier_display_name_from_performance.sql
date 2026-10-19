-- Keep the Data Crazy courier name unless it is blank or is clearly an identifier.
-- For identifier-like names, use the UUID-matched Performance name when it is usable.
create or replace function indique_ganhe_influencer.courier_name_is_identifier(p_value text)
returns boolean
language sql
immutable
parallel safe
set search_path = pg_catalog
as $$
  select coalesce(
    btrim(coalesce(p_value, '')) ~* '^(cpf|id)[[:space:]:#-]*[[:alnum:]./_-]+$'
    or btrim(coalesce(p_value, '')) ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
    or btrim(coalesce(p_value, '')) ~* '^[0-9a-f]{32}$'
    or (
      btrim(coalesce(p_value, '')) ~ '^[0-9][0-9 ./-]*$'
      and length(regexp_replace(coalesce(p_value, ''), '[^0-9]', '', 'g')) between 6 and 20
    ),
    false
  );
$$;

create or replace function indique_ganhe_influencer.resolve_courier_name(
  p_datacrazy_name text,
  p_performance_name text
)
returns text
language sql
immutable
parallel safe
set search_path = pg_catalog, indique_ganhe_influencer
as $$
  select case
    when nullif(btrim(p_datacrazy_name), '') is null
      then coalesce(nullif(btrim(p_performance_name), ''), '')
    when indique_ganhe_influencer.courier_name_is_identifier(p_datacrazy_name)
      and nullif(btrim(p_performance_name), '') is not null
      and not indique_ganhe_influencer.courier_name_is_identifier(p_performance_name)
      then btrim(p_performance_name)
    else btrim(p_datacrazy_name)
  end;
$$;

revoke all on function indique_ganhe_influencer.courier_name_is_identifier(text) from public, anon;
revoke all on function indique_ganhe_influencer.resolve_courier_name(text, text) from public, anon;
grant execute on function indique_ganhe_influencer.courier_name_is_identifier(text) to authenticated;
grant execute on function indique_ganhe_influencer.resolve_courier_name(text, text) to authenticated;

create or replace view indique_ganhe_influencer.referral_progress
with (security_invoker = true) as
select r.uuid as referral_id, r.uuid,
  indique_ganhe_influencer.resolve_courier_name(r.name, t.fallback_name) as name,
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

create or replace function indique_ganhe_influencer.admin_referrals_page_filtered_v2(
  p_reward_status text, p_limit integer default 50, p_offset integer default 0,
  p_influencer_id text default 'all', p_search text default '', p_id_filter text default 'all'
)
returns jsonb language plpgsql stable security definer
set search_path = pg_catalog, indique_ganhe_influencer
as $$
declare
  v_influencer_id text := coalesce(nullif(btrim(p_influencer_id), ''), 'all');
  v_search text := lower(btrim(coalesce(p_search, '')));
  v_reward_status text := coalesce(nullif(btrim(p_reward_status), ''), 'all');
  v_id_filter text := coalesce(nullif(btrim(p_id_filter), ''), 'all');
begin
  if not indique_ganhe_influencer.is_admin() then
    raise exception 'Apenas a administração pode consultar todos os indicados.';
  end if;
  if v_reward_status not in ('all', 'progress', 'to_pay', 'paid') then
    raise exception 'Selecione uma situação válida para os indicados.';
  end if;
  if v_id_filter not in ('all', 'missing') then raise exception 'Selecione um filtro de identificação válido.'; end if;
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
        indique_ganhe_influencer.resolve_courier_name(r.name, t.fallback_name) as name,
        r.region, r.released_at, r.phone, r.cpf,
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
        and v_id_filter = 'all'
        and (v_influencer_id = 'all' or i.id = v_influencer_id)
        and (v_search = '' or strpos(lower(concat_ws(' ',
          indique_ganhe_influencer.resolve_courier_name(r.name, t.fallback_name), r.name,
          r.uuid::text, r.region, r.phone, r.cpf, i.name)), v_search) > 0)
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

revoke execute on function indique_ganhe_influencer.admin_referrals_page_filtered_v2(text, integer, integer, text, text, text)
  from public, anon;
grant execute on function indique_ganhe_influencer.admin_referrals_page_filtered_v2(text, integer, integer, text, text, text)
  to authenticated;

notify pgrst, 'reload schema';
