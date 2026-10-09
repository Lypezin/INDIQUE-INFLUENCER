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
    );
$$;

revoke execute on function indique_ganhe_influencer.last_import_at() from public, anon;
grant execute on function indique_ganhe_influencer.last_import_at() to authenticated;
