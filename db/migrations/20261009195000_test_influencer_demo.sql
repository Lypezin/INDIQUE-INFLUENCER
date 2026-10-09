begin;

alter table indique_ganhe_influencer.influencers
  add column if not exists is_demo boolean;
update indique_ganhe_influencer.influencers set is_demo = false where is_demo is null;
alter table indique_ganhe_influencer.influencers
  alter column is_demo set default false,
  alter column is_demo set not null;

insert into indique_ganhe_influencer.influencers
  (id, name, route_goal, prize_cents, sort_order, is_demo)
values ('teste', 'Influenciador de teste', 150, 25000, 10, true)
on conflict (id) do update set
  name = excluded.name,
  route_goal = excluded.route_goal,
  prize_cents = excluded.prize_cents,
  sort_order = excluded.sort_order,
  is_demo = true;

create table if not exists indique_ganhe_influencer.demo_referrals (
  uuid uuid primary key default gen_random_uuid(),
  name text not null,
  region text not null,
  routes bigint not null check (routes >= 0),
  created_at timestamptz not null default now()
);

alter table indique_ganhe_influencer.demo_referrals enable row level security;
drop policy if exists demo_referrals_owner_or_admin_read on indique_ganhe_influencer.demo_referrals;
create policy demo_referrals_owner_or_admin_read
  on indique_ganhe_influencer.demo_referrals
  for select to authenticated
  using (
    indique_ganhe_influencer.is_admin()
    or indique_ganhe_influencer.current_influencer_id() = 'teste'
  );
revoke all on indique_ganhe_influencer.demo_referrals from public, anon;
grant select on indique_ganhe_influencer.demo_referrals to authenticated;

insert into indique_ganhe_influencer.demo_referrals (name, region, routes)
select sample.name, sample.region, sample.routes
from (values
  ('Entregador de exemplo 001', 'Campinas · exemplo', 0::bigint),
  ('Entregador de exemplo 002', 'Santos · exemplo', 87::bigint),
  ('Entregador de exemplo 003', 'São Paulo · exemplo', 150::bigint)
) as sample(name, region, routes)
where not exists (select 1 from indique_ganhe_influencer.demo_referrals);

drop view if exists indique_ganhe_influencer.referral_progress;
create view indique_ganhe_influencer.referral_progress
with (security_invoker = true) as
select r.uuid as referral_id, r.uuid,
  coalesce(nullif(r.name, ''), t.fallback_name, '') as name,
  coalesce(nullif(r.region, ''), t.fallback_region) as region,
  r.phone, r.cpf,
  coalesce(t.route_count, 0)::bigint as routes,
  i.route_goal, i.prize_cents,
  (coalesce(t.route_count, 0) >= i.route_goal) as prize_unlocked,
  greatest(i.route_goal::bigint - coalesce(t.route_count, 0), 0)::bigint as routes_remaining,
  i.name as influencer_name
from indique_ganhe_influencer.referrals r
join indique_ganhe_influencer.influencers i on i.id = r.influencer_id
left join indique_ganhe_influencer.performance_totals t on t.uuid = r.uuid
where r.influencer_id is not null and not i.is_demo
union all
select d.uuid as referral_id, d.uuid, d.name, d.region,
  null::text as phone, null::text as cpf, d.routes,
  i.route_goal, i.prize_cents,
  (d.routes >= i.route_goal) as prize_unlocked,
  greatest(i.route_goal::bigint - d.routes, 0)::bigint as routes_remaining,
  i.name as influencer_name
from indique_ganhe_influencer.demo_referrals d
join indique_ganhe_influencer.influencers i on i.id = 'teste' and i.is_demo;
revoke all on indique_ganhe_influencer.referral_progress from public, anon;
grant select on indique_ganhe_influencer.referral_progress to authenticated;

drop policy if exists referrals_owner_or_admin_read on indique_ganhe_influencer.referrals;
create policy referrals_owner_or_admin_read
  on indique_ganhe_influencer.referrals for select to authenticated
  using (
    indique_ganhe_influencer.is_admin()
    or (
      influencer_id = indique_ganhe_influencer.current_influencer_id()
      and exists (
        select 1 from indique_ganhe_influencer.influencers i
        where i.id = referrals.influencer_id and not i.is_demo
      )
    )
  );

drop policy if exists performance_referrals_owner_or_admin_read on indique_ganhe_influencer.performance_contributions;
create policy performance_referrals_owner_or_admin_read
  on indique_ganhe_influencer.performance_contributions for select to authenticated
  using (
    indique_ganhe_influencer.is_admin()
    or exists (
      select 1 from indique_ganhe_influencer.referrals r
      join indique_ganhe_influencer.influencers i on i.id = r.influencer_id
      where r.uuid = performance_contributions.uuid
        and r.influencer_id = indique_ganhe_influencer.current_influencer_id()
        and not i.is_demo
    )
  );

drop policy if exists performance_totals_owner_or_admin_read on indique_ganhe_influencer.performance_totals;
create policy performance_totals_owner_or_admin_read
  on indique_ganhe_influencer.performance_totals for select to authenticated
  using (
    indique_ganhe_influencer.is_admin()
    or exists (
      select 1 from indique_ganhe_influencer.referrals r
      join indique_ganhe_influencer.influencers i on i.id = r.influencer_id
      where r.uuid = performance_totals.uuid
        and r.influencer_id = indique_ganhe_influencer.current_influencer_id()
        and not i.is_demo
    )
  );

create or replace function indique_ganhe_influencer.assign_review(p_review_id uuid, p_influencer_id text)
returns boolean language plpgsql security definer
set search_path = pg_catalog, indique_ganhe_influencer
as $$
declare v_uuid uuid;
begin
  if not indique_ganhe_influencer.is_admin() then
    raise exception 'Apenas a administração pode revisar atribuições.';
  end if;
  if not exists (
    select 1 from indique_ganhe_influencer.influencers i
    where i.id = p_influencer_id and not i.is_demo
  ) then
    raise exception 'Influenciador não encontrado.';
  end if;
  select r.uuid into v_uuid
  from indique_ganhe_influencer.attribution_reviews r
  where r.id = p_review_id and r.status = 'open'
  for update;
  if v_uuid is null then raise exception 'A revisão não está mais pendente.'; end if;
  update indique_ganhe_influencer.referrals
  set influencer_id = p_influencer_id, updated_at = now()
  where uuid = v_uuid and influencer_id is null;
  if not found then
    raise exception 'Este UUID não está na lista atual. Reimporte o Data Crazy para atualizar a revisão.';
  end if;
  update indique_ganhe_influencer.attribution_reviews
  set status = 'resolved', influencer_id = p_influencer_id,
      reviewed_by = auth.uid(), reviewed_at = now()
  where id = p_review_id;
  return true;
end;
$$;

revoke execute on function indique_ganhe_influencer.assign_review(uuid, text) from public, anon;
grant execute on function indique_ganhe_influencer.assign_review(uuid, text) to authenticated;

create or replace function indique_ganhe_influencer.last_import_at()
returns timestamptz language sql stable security definer
set search_path = pg_catalog, indique_ganhe_influencer
as $$
  select max(b.completed_at)
  from indique_ganhe_influencer.import_batches b
  where b.status = 'completed'
    and exists (
      select 1 from indique_ganhe_influencer.account_members m
      where m.user_id = auth.uid()
        and (m.role = 'admin' or m.influencer_id <> 'teste')
    );
$$;
revoke execute on function indique_ganhe_influencer.last_import_at() from public, anon;
grant execute on function indique_ganhe_influencer.last_import_at() to authenticated;

create or replace function indique_ganhe_influencer.admin_overview()
returns jsonb language plpgsql stable security definer
set search_path = pg_catalog, indique_ganhe_influencer
as $$
begin
  if not indique_ganhe_influencer.is_admin() then
    raise exception 'Apenas a administração pode abrir esta área.';
  end if;
  return jsonb_build_object(
    'influencers', (
      select coalesce(jsonb_agg(to_jsonb(i) order by i.sort_order), '[]'::jsonb)
      from indique_ganhe_influencer.influencers i where not i.is_demo
    ),
    'availableInfluencers', (
      select coalesce(jsonb_agg(to_jsonb(i) order by i.sort_order), '[]'::jsonb)
      from indique_ganhe_influencer.influencers i
    ),
    'imports', (
      select coalesce(jsonb_agg(jsonb_build_object(
        'id', b.id, 'kind', b.kind, 'file_name', b.file_name,
        'status', b.status, 'created_at', b.created_at, 'metrics', b.metrics
      ) order by b.created_at desc), '[]'::jsonb)
      from (
        select * from indique_ganhe_influencer.import_batches
        where status <> 'staging' order by created_at desc limit 10
      ) b
    ),
    'reviews', (
      select coalesce(jsonb_agg(jsonb_build_object(
        'id', r.id, 'uuid', r.uuid, 'name', r.name,
        'region', r.region, 'raw_influencer', r.raw_influencer, 'status', r.status
      ) order by r.created_at), '[]'::jsonb)
      from (
        select * from indique_ganhe_influencer.attribution_reviews
        where status = 'open' order by created_at, id limit 50
      ) r
    ),
    'reviewCount', (
      select count(*) from indique_ganhe_influencer.attribution_reviews r where r.status = 'open'
    ),
    'members', (
      select coalesce(jsonb_agg(jsonb_build_object(
        'user_id', m.user_id, 'email', m.email, 'role', m.role,
        'influencer_id', m.influencer_id, 'influencer_name', i.name
      ) order by m.role, m.email), '[]'::jsonb)
      from indique_ganhe_influencer.account_members m
      left join indique_ganhe_influencer.influencers i on i.id = m.influencer_id
    ),
    'invites', (
      select coalesce(jsonb_agg(jsonb_build_object(
        'id', a.id, 'email', a.email, 'influencer_id', a.influencer_id,
        'influencer_name', i.name, 'created_at', a.created_at
      ) order by a.created_at desc), '[]'::jsonb)
      from indique_ganhe_influencer.account_invites a
      left join indique_ganhe_influencer.influencers i on i.id = a.influencer_id
      where a.status = 'pending'
    ),
    'referralCount', (
      select count(*) from indique_ganhe_influencer.referrals r where r.influencer_id is not null
    ),
    'contributionTotal', (
      select coalesce(sum(t.route_count), 0)
      from indique_ganhe_influencer.performance_totals t
    )
  );
end;
$$;

revoke execute on function indique_ganhe_influencer.admin_overview() from public, anon;
grant execute on function indique_ganhe_influencer.admin_overview() to authenticated;

commit;
