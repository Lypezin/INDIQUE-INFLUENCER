begin;

-- The owner confirmed this Data Crazy tenant only has records from 2026.
-- The worker still probes for older records and fails without publishing if
-- that changes in the future.
alter table indique_ganhe_influencer.data_crazy_sync_runs
  alter column business_month set default date '2026-01-01',
  alter column lead_month set default date '2026-01-01';

-- The active run already advanced through empty business months. Its lead
-- phase has not started, so skip those known-empty months for this run too.
update indique_ganhe_influencer.data_crazy_sync_runs
set lead_month = date '2026-01-01', updated_at = now()
where phase = 'businesses' and lead_month = date '2020-01-01'
  and leads_fetched = 0 and leads_skip = 0;

commit;
