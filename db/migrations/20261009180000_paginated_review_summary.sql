-- Keep the admin overview bounded when a large Data Crazy import creates many reviews.
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
