-- Apply to Supabase project cpidpqnstchvcozijczf only, after deploying the
-- migration and Edge Function and storing the SAME random cron secret in:
--   Edge Function env: DATACRAZY_CRON_SECRET
--   Supabase Vault:    indique_ganhe_dc_cron_secret
-- Do not put a credential in this file. Jobs are named and only touch this app.

begin;
create schema if not exists extensions;
create extension if not exists pg_cron with schema pg_catalog;
create extension if not exists pg_net with schema extensions;

do $$
begin
  if not exists (select 1 from vault.decrypted_secrets
    where name = 'indique_ganhe_dc_cron_secret' and nullif(decrypted_secret, '') is not null) then
    raise exception 'Configure o segredo indique_ganhe_dc_cron_secret no Vault antes de ativar o agendamento.';
  end if;
end;
$$;

-- Reapply safely without touching any other project's scheduled jobs.
select cron.unschedule(jobid)
from cron.job
where jobname in ('indique_ganhe_datacrazy_daily_start', 'indique_ganhe_datacrazy_advance');

-- Supabase pg_cron uses UTC: 09:00 UTC = 06:00 America/Sao_Paulo.
select cron.schedule(
  'indique_ganhe_datacrazy_daily_start',
  '0 9 * * *',
  $job$
    select net.http_post(
      url := 'https://cpidpqnstchvcozijczf.supabase.co/functions/v1/indique-ganhe-datacrazy-sync',
      headers := jsonb_build_object('Content-Type', 'application/json', 'x-cron-secret',
        (select decrypted_secret from vault.decrypted_secrets
         where name = 'indique_ganhe_dc_cron_secret')),
      body := '{"action":"cron-start"}'::jsonb,
      timeout_milliseconds := 30000
    ) as request_id;
  $job$
);

-- A pending run advances in bounded Edge Function invocations. Idle ticks make
-- no HTTP request. Deferred 429 work waits until its lease_until timestamp.
select cron.schedule(
  'indique_ganhe_datacrazy_advance',
  '* * * * *',
  $job$
    select net.http_post(
      url := 'https://cpidpqnstchvcozijczf.supabase.co/functions/v1/indique-ganhe-datacrazy-sync',
      headers := jsonb_build_object('Content-Type', 'application/json', 'x-cron-secret',
        (select decrypted_secret from vault.decrypted_secrets
         where name = 'indique_ganhe_dc_cron_secret')),
      body := '{"action":"advance"}'::jsonb,
      timeout_milliseconds := 60000
    ) as request_id
    where exists (
      select 1 from indique_ganhe_influencer.data_crazy_sync_runs r
      where r.phase in ('businesses', 'leads', 'ready')
        and (r.lease_until is null or r.lease_until <= now())
    );
  $job$
);

commit;
