begin;

-- Attribution comes only from a mapped influencer pipeline. Keep the audit
-- columns for compatibility with the existing publisher, but discard the
-- lead's custom indication before it can participate in assignment.
create or replace function indique_ganhe_influencer.clear_data_crazy_lead_indication()
returns trigger
language plpgsql
set search_path = pg_catalog, indique_ganhe_influencer
as $$
begin
  new.indication_raw := '';
  new.indication_influencer_id := null;
  new.indication_status := 'empty';
  return new;
end;
$$;

revoke all on function indique_ganhe_influencer.clear_data_crazy_lead_indication()
  from public, anon, authenticated;
grant execute on function indique_ganhe_influencer.clear_data_crazy_lead_indication()
  to service_role;

drop trigger if exists clear_data_crazy_lead_indication
  on indique_ganhe_influencer.data_crazy_sync_leads;
create trigger clear_data_crazy_lead_indication
  before insert or update on indique_ganhe_influencer.data_crazy_sync_leads
  for each row execute function indique_ganhe_influencer.clear_data_crazy_lead_indication();

update indique_ganhe_influencer.data_crazy_sync_leads
set indication_raw = '', indication_influencer_id = null, indication_status = 'empty'
where indication_raw <> '' or indication_influencer_id is not null or indication_status <> 'empty';

notify pgrst, 'reload schema';
commit;
