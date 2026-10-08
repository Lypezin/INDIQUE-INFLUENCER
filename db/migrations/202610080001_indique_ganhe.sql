-- Indique e Ganhe application data. This migration is scoped to its dedicated schema.
create schema if not exists indique_ganhe_influencer;

create table if not exists indique_ganhe_influencer.influencers (
  id text primary key,
  name text not null unique,
  route_goal integer not null check (route_goal > 0),
  prize_cents integer not null check (prize_cents >= 0),
  sort_order smallint not null unique
);
insert into indique_ganhe_influencer.influencers (id, name, route_goal, prize_cents, sort_order) values
  ('jaiminho', 'Jaiminho', 30, 5000, 1), ('jhowjhow', 'JhowJhow', 30, 5000, 2),
  ('felipe', 'Felipe', 30, 5000, 3), ('00-brocador', '00 Brocador', 150, 30000, 4),
  ('sassa', 'Sassa', 30, 10000, 5), ('vini', 'Vini', 150, 25000, 6),
  ('gui', 'Gui', 150, 25000, 7), ('biel', 'Biel', 150, 25000, 8), ('thais', 'Thais', 150, 25000, 9)
on conflict (id) do update set name = excluded.name, route_goal = excluded.route_goal,
  prize_cents = excluded.prize_cents, sort_order = excluded.sort_order;

create table if not exists indique_ganhe_influencer.account_members (
  user_id uuid primary key references auth.users(id) on delete cascade,
  email text not null,
  role text not null check (role in ('admin', 'influencer')),
  influencer_id text references indique_ganhe_influencer.influencers(id),
  created_at timestamptz not null default now(),
  constraint account_members_role_owner check ((role = 'admin' and influencer_id is null) or (role = 'influencer' and influencer_id is not null))
);
create unique index if not exists account_members_one_user_per_influencer
  on indique_ganhe_influencer.account_members (influencer_id) where role = 'influencer';

create table if not exists indique_ganhe_influencer.account_invites (
  id uuid primary key default gen_random_uuid(),
  email text not null unique,
  role text not null check (role in ('admin', 'influencer')),
  influencer_id text references indique_ganhe_influencer.influencers(id),
  status text not null default 'pending' check (status in ('pending', 'claimed', 'revoked')),
  created_by uuid references auth.users(id), claimed_by uuid references auth.users(id),
  created_at timestamptz not null default now(), claimed_at timestamptz,
  constraint account_invites_role_owner check ((role = 'admin' and influencer_id is null) or (role = 'influencer' and influencer_id is not null))
);
insert into indique_ganhe_influencer.account_invites (email, role, influencer_id)
values ('owner@gmail.com', 'admin', null) on conflict (email) do nothing;

create table if not exists indique_ganhe_influencer.import_batches (
  id uuid primary key default gen_random_uuid(),
  kind text not null check (kind in ('data_crazy', 'performance')),
  file_name text not null,
  file_hash text not null check (file_hash ~ '^[0-9a-f]{64}$'),
  status text not null default 'staging' check (status in ('staging', 'completed', 'failed')),
  metrics jsonb not null default '{}'::jsonb, expected_rows integer not null check (expected_rows >= 0),
  created_by uuid not null references auth.users(id), created_at timestamptz not null default now(), completed_at timestamptz
);
create index if not exists import_batches_recent_idx on indique_ganhe_influencer.import_batches (created_at desc);
create index if not exists import_batches_hash_idx on indique_ganhe_influencer.import_batches (kind, file_hash, status);

create table if not exists indique_ganhe_influencer.import_rows (
  id bigint generated always as identity primary key,
  batch_id uuid not null references indique_ganhe_influencer.import_batches(id) on delete cascade,
  payload jsonb not null check (jsonb_typeof(payload) = 'object'), created_at timestamptz not null default now()
);
create index if not exists import_rows_batch_idx on indique_ganhe_influencer.import_rows (batch_id, id);

create table if not exists indique_ganhe_influencer.referrals (
  uuid uuid primary key, name text not null default '', region text, phone text, cpf text,
  phone_unavailable boolean not null default false,
  influencer_id text references indique_ganhe_influencer.influencers(id), raw_influencer text not null default '',
  source_batch_id uuid not null references indique_ganhe_influencer.import_batches(id), updated_at timestamptz not null default now()
);
create index if not exists referrals_influencer_idx on indique_ganhe_influencer.referrals (influencer_id, name);

create table if not exists indique_ganhe_influencer.performance_contributions (
  id bigint generated always as identity primary key,
  batch_id uuid not null references indique_ganhe_influencer.import_batches(id), uuid uuid not null,
  route_count integer not null check (route_count >= 0), fallback_name text, fallback_region text,
  imported_at timestamptz not null default now(), unique (batch_id, uuid)
);
create index if not exists performance_contributions_uuid_idx on indique_ganhe_influencer.performance_contributions (uuid);

create table if not exists indique_ganhe_influencer.attribution_reviews (
  id uuid primary key default gen_random_uuid(), batch_id uuid not null references indique_ganhe_influencer.import_batches(id),
  uuid uuid not null, name text not null default '', region text, raw_influencer text not null default '',
  status text not null default 'open' check (status in ('open', 'resolved', 'superseded')),
  influencer_id text references indique_ganhe_influencer.influencers(id), reviewed_by uuid references auth.users(id),
  created_at timestamptz not null default now(), reviewed_at timestamptz
);
create index if not exists attribution_reviews_open_idx on indique_ganhe_influencer.attribution_reviews (status, created_at desc);
create unique index if not exists account_invites_one_pending_per_influencer
  on indique_ganhe_influencer.account_invites (influencer_id)
  where role = 'influencer' and status = 'pending';

create or replace function indique_ganhe_influencer.is_admin()
returns boolean language sql stable security definer
set search_path = pg_catalog, indique_ganhe_influencer
as $$
  select exists (select 1 from indique_ganhe_influencer.account_members m
    where m.user_id = auth.uid() and m.role = 'admin');
$$;

create or replace function indique_ganhe_influencer.current_influencer_id()
returns text language sql stable security definer
set search_path = pg_catalog, indique_ganhe_influencer
as $$
  select m.influencer_id from indique_ganhe_influencer.account_members m
  where m.user_id = auth.uid() and m.role = 'influencer' limit 1;
$$;

create or replace function indique_ganhe_influencer.claim_invite()
returns boolean language plpgsql security definer
set search_path = pg_catalog, indique_ganhe_influencer
as $$
declare
  v_user uuid := auth.uid();
  v_email text;
  v_confirmed_at timestamptz;
  v_invite indique_ganhe_influencer.account_invites%rowtype;
begin
  if v_user is null then raise exception 'Entre com um e-mail confirmado para ativar o acesso.'; end if;
  select lower(trim(coalesce(u.email, ''))), u.email_confirmed_at into v_email, v_confirmed_at
    from auth.users u where u.id = v_user;
  if coalesce(v_email, '') = '' or v_confirmed_at is null then raise exception 'Confirme seu e-mail antes de ativar o acesso.'; end if;
  if exists (select 1 from indique_ganhe_influencer.account_members m where m.user_id = v_user) then return true; end if;
  select * into v_invite from indique_ganhe_influencer.account_invites i
    where lower(i.email) = v_email and i.status = 'pending' for update;
  if not found then return false; end if;
  insert into indique_ganhe_influencer.account_members (user_id, email, role, influencer_id)
  values (v_user, v_email, v_invite.role, v_invite.influencer_id);
  update indique_ganhe_influencer.account_invites set status = 'claimed', claimed_by = v_user, claimed_at = now()
    where id = v_invite.id;
  return true;
end;
$$;

create or replace function indique_ganhe_influencer.current_profile()
returns jsonb language plpgsql stable security definer
set search_path = pg_catalog, indique_ganhe_influencer
as $$
declare v_profile jsonb;
begin
  select jsonb_build_object('role', m.role, 'influencer_id', m.influencer_id, 'email', m.email)
  into v_profile from indique_ganhe_influencer.account_members m where m.user_id = auth.uid();
  if v_profile is null then raise exception 'Esta conta ainda não tem convite. Peça ao administrador para vincular seu e-mail.'; end if;
  return v_profile;
end;
$$;

create or replace function indique_ganhe_influencer.admin_overview()
returns jsonb language plpgsql stable security definer
set search_path = pg_catalog, indique_ganhe_influencer
as $$
begin
  if not indique_ganhe_influencer.is_admin() then raise exception 'Apenas a administração pode abrir esta área.'; end if;
  return jsonb_build_object(
    'influencers', (select coalesce(jsonb_agg(to_jsonb(i) order by i.sort_order), '[]'::jsonb) from indique_ganhe_influencer.influencers i),
    'imports', (select coalesce(jsonb_agg(jsonb_build_object('id', b.id, 'kind', b.kind, 'file_name', b.file_name, 'status', b.status, 'created_at', b.created_at, 'metrics', b.metrics) order by b.created_at desc), '[]'::jsonb) from (select * from indique_ganhe_influencer.import_batches where status <> 'staging' order by created_at desc limit 10) b),
    'reviews', (select coalesce(jsonb_agg(jsonb_build_object('id', r.id, 'uuid', r.uuid, 'name', r.name, 'region', r.region, 'raw_influencer', r.raw_influencer, 'status', r.status) order by r.created_at), '[]'::jsonb) from indique_ganhe_influencer.attribution_reviews r where r.status = 'open'),
    'members', (select coalesce(jsonb_agg(jsonb_build_object('user_id', m.user_id, 'email', m.email, 'role', m.role, 'influencer_id', m.influencer_id, 'influencer_name', i.name) order by m.role, m.email), '[]'::jsonb) from indique_ganhe_influencer.account_members m left join indique_ganhe_influencer.influencers i on i.id = m.influencer_id),
    'referralCount', (select count(*) from indique_ganhe_influencer.referrals r where r.influencer_id is not null),
    'contributionTotal', (select coalesce(sum(p.route_count), 0) from indique_ganhe_influencer.performance_contributions p)
  );
end;
$$;

create or replace function indique_ganhe_influencer.create_account_invite(p_email text, p_influencer_id text)
returns jsonb language plpgsql security definer
set search_path = pg_catalog, indique_ganhe_influencer
as $$
declare v_email text := lower(trim(coalesce(p_email, ''))); v_id uuid;
begin
  if not indique_ganhe_influencer.is_admin() then raise exception 'Apenas a administração pode convidar contas.'; end if;
  if v_email !~* '^[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}$' then raise exception 'Informe um e-mail válido.'; end if;
  if not exists (select 1 from indique_ganhe_influencer.influencers i where i.id = p_influencer_id) then raise exception 'Influenciador não encontrado.'; end if;
  if exists (select 1 from indique_ganhe_influencer.account_members m where m.role = 'influencer' and m.influencer_id = p_influencer_id) then raise exception 'Este influenciador já possui uma conta vinculada.'; end if;
  if exists (select 1 from indique_ganhe_influencer.account_invites i where i.role = 'influencer' and i.influencer_id = p_influencer_id and i.status = 'pending' and i.email <> v_email) then raise exception 'Este influenciador já possui um convite pendente.'; end if;
  insert into indique_ganhe_influencer.account_invites (email, role, influencer_id, status, created_by, claimed_by, claimed_at)
  values (v_email, 'influencer', p_influencer_id, 'pending', auth.uid(), null, null)
  on conflict (email) do update set role = excluded.role, influencer_id = excluded.influencer_id,
    status = 'pending', created_by = excluded.created_by, claimed_by = null, claimed_at = null returning id into v_id;
  return jsonb_build_object('invite_id', v_id, 'email', v_email, 'influencer_id', p_influencer_id, 'status', 'pending');
end;
$$;

create or replace function indique_ganhe_influencer.start_import(
  p_kind text, p_file_name text, p_file_hash text, p_metrics jsonb, p_total_rows integer
)
returns jsonb language plpgsql security definer
set search_path = pg_catalog, indique_ganhe_influencer
as $$
declare v_id uuid; v_duplicate boolean;
begin
  if not indique_ganhe_influencer.is_admin() then raise exception 'Apenas a administração pode importar arquivos.'; end if;
  if p_kind not in ('data_crazy', 'performance') then raise exception 'Tipo de importação inválido.'; end if;
  if p_total_rows is null or p_total_rows < 1 or p_total_rows > 100000 then raise exception 'Quantidade de registros inválida.'; end if;
  if p_file_hash !~ '^[0-9a-f]{64}$' then raise exception 'Hash do arquivo inválido.'; end if;
  select exists (select 1 from indique_ganhe_influencer.import_batches b
    where b.kind = p_kind and b.file_hash = p_file_hash and b.status = 'completed') into v_duplicate;
  insert into indique_ganhe_influencer.import_batches (kind, file_name, file_hash, metrics, expected_rows, created_by)
  values (p_kind, left(coalesce(p_file_name, 'arquivo'), 255), p_file_hash, coalesce(p_metrics, '{}'::jsonb), p_total_rows, auth.uid())
  returning id into v_id;
  return jsonb_build_object('batchId', v_id, 'duplicateFile', v_duplicate);
end;
$$;

create or replace function indique_ganhe_influencer.append_import_rows(p_batch_id uuid, p_rows jsonb)
returns integer language plpgsql security definer
set search_path = pg_catalog, indique_ganhe_influencer
as $$
declare v_count integer;
begin
  if not indique_ganhe_influencer.is_admin() then raise exception 'Apenas a administração pode importar arquivos.'; end if;
  if jsonb_typeof(p_rows) <> 'array' or jsonb_array_length(p_rows) < 1 or jsonb_array_length(p_rows) > 300 then raise exception 'Envie um lote entre 1 e 300 registros.'; end if;
  perform 1 from indique_ganhe_influencer.import_batches b
    where b.id = p_batch_id and b.created_by = auth.uid() and b.status = 'staging' for update;
  if not found then raise exception 'Importação não encontrada ou já finalizada.'; end if;
  insert into indique_ganhe_influencer.import_rows (batch_id, payload)
  select p_batch_id, item from jsonb_array_elements(p_rows) item;
  select count(*)::integer into v_count from indique_ganhe_influencer.import_rows r where r.batch_id = p_batch_id;
  if v_count > (select b.expected_rows from indique_ganhe_influencer.import_batches b where b.id = p_batch_id) then raise exception 'O lote excedeu a quantidade prevista.'; end if;
  return v_count;
end;
$$;

create or replace function indique_ganhe_influencer.cancel_import(p_batch_id uuid)
returns boolean language plpgsql security definer
set search_path = pg_catalog, indique_ganhe_influencer
as $$
begin
  if not indique_ganhe_influencer.is_admin() then raise exception 'Apenas a administração pode cancelar importações.'; end if;
  perform 1 from indique_ganhe_influencer.import_batches b
    where b.id = p_batch_id and b.created_by = auth.uid() and b.status = 'staging' for update;
  if not found then return false; end if;
  delete from indique_ganhe_influencer.import_rows where batch_id = p_batch_id;
  update indique_ganhe_influencer.import_batches set status = 'failed' where id = p_batch_id;
  return true;
end;
$$;

create or replace function indique_ganhe_influencer.complete_import(p_batch_id uuid)
returns jsonb language plpgsql security definer
set search_path = pg_catalog, indique_ganhe_influencer
as $$
declare v_batch indique_ganhe_influencer.import_batches%rowtype; v_rows integer; v_result jsonb;
begin
  if not indique_ganhe_influencer.is_admin() then raise exception 'Apenas a administração pode finalizar importações.'; end if;
  select * into v_batch from indique_ganhe_influencer.import_batches b
    where b.id = p_batch_id and b.created_by = auth.uid() for update;
  if not found or v_batch.status <> 'staging' then raise exception 'Importação não encontrada ou já finalizada.'; end if;
  select count(*)::integer into v_rows from indique_ganhe_influencer.import_rows r where r.batch_id = p_batch_id;
  if v_rows <> v_batch.expected_rows then raise exception 'A importação recebeu % de % registros. Nada foi aplicado.', v_rows, v_batch.expected_rows; end if;
  perform pg_advisory_xact_lock(hashtext('indique_ganhe:' || v_batch.kind));
  if v_batch.kind = 'data_crazy' then
    if exists (select 1 from indique_ganhe_influencer.import_rows r where r.batch_id = p_batch_id and coalesce(r.payload->>'uuid', '') !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$') then
      raise exception 'Há UUID inválido no lote Data Crazy.';
    end if;
    update indique_ganhe_influencer.attribution_reviews set status = 'superseded' where status = 'open';
    delete from indique_ganhe_influencer.referrals;
    insert into indique_ganhe_influencer.referrals (uuid, name, region, phone, cpf, phone_unavailable, influencer_id, raw_influencer, source_batch_id)
    select (r.payload->>'uuid')::uuid,
      coalesce(r.payload->>'name', ''), nullif(r.payload->>'region', ''), nullif(r.payload->>'phone', ''),
      case when coalesce(r.payload->>'cpf', '') ~ '^[0-9]{11}$' then r.payload->>'cpf' else null end,
      coalesce((r.payload->>'phoneUnavailable')::boolean, false),
      case when i.id is not null then i.id else null end,
      coalesce(r.payload->>'rawInfluencer', ''), p_batch_id
    from indique_ganhe_influencer.import_rows r
    left join indique_ganhe_influencer.influencers i on i.id = r.payload->>'influencerId'
    where r.batch_id = p_batch_id;
    insert into indique_ganhe_influencer.attribution_reviews (batch_id, uuid, name, region, raw_influencer)
    select p_batch_id, (r.payload->>'uuid')::uuid, coalesce(r.payload->>'name', ''),
      nullif(r.payload->>'region', ''), coalesce(r.payload->>'rawInfluencer', '')
    from indique_ganhe_influencer.import_rows r
    where r.batch_id = p_batch_id and nullif(r.payload->>'influencerId', '') is null;
    v_result := jsonb_build_object('imported', v_rows, 'kind', 'data_crazy');
  else
    if exists (select 1 from indique_ganhe_influencer.import_rows r where r.batch_id = p_batch_id and (
      coalesce(r.payload->>'uuid', '') !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
      or coalesce(r.payload->>'routes', '') !~ '^[0-9]+$')) then
      raise exception 'Há UUID ou quantidade de corridas inválida no lote Performance.';
    end if;
    insert into indique_ganhe_influencer.performance_contributions (batch_id, uuid, route_count, fallback_name, fallback_region)
    select p_batch_id, (r.payload->>'uuid')::uuid, (r.payload->>'routes')::integer,
      nullif(r.payload->>'name', ''), nullif(r.payload->>'region', '')
    from indique_ganhe_influencer.import_rows r where r.batch_id = p_batch_id;
    v_result := jsonb_build_object('imported', v_rows, 'kind', 'performance');
  end if;
  update indique_ganhe_influencer.import_batches set status = 'completed', completed_at = now() where id = p_batch_id;
  delete from indique_ganhe_influencer.import_rows where batch_id = p_batch_id;
  return v_result;
end;
$$;

create or replace function indique_ganhe_influencer.assign_review(p_review_id uuid, p_influencer_id text)
returns boolean language plpgsql security definer
set search_path = pg_catalog, indique_ganhe_influencer
as $$
declare v_uuid uuid;
begin
  if not indique_ganhe_influencer.is_admin() then raise exception 'Apenas a administração pode revisar atribuições.'; end if;
  if not exists (select 1 from indique_ganhe_influencer.influencers i where i.id = p_influencer_id) then raise exception 'Influenciador não encontrado.'; end if;
  select r.uuid into v_uuid from indique_ganhe_influencer.attribution_reviews r where r.id = p_review_id and r.status = 'open' for update;
  if v_uuid is null then raise exception 'A revisão não está mais pendente.'; end if;
  update indique_ganhe_influencer.referrals set influencer_id = p_influencer_id, updated_at = now()
    where uuid = v_uuid and influencer_id is null;
  if not found then raise exception 'Este UUID não está na lista atual. Reimporte o Data Crazy para atualizar a revisão.'; end if;
  update indique_ganhe_influencer.attribution_reviews set status = 'resolved', influencer_id = p_influencer_id,
    reviewed_by = auth.uid(), reviewed_at = now() where id = p_review_id;
  return true;
end;
$$;

create or replace view indique_ganhe_influencer.referral_progress with (security_invoker = true) as
select r.uuid as referral_id, r.uuid, coalesce(nullif(r.name, ''), max(nullif(p.fallback_name, '')), '') as name,
  coalesce(nullif(r.region, ''), max(nullif(p.fallback_region, ''))) as region, r.phone, r.cpf,
  coalesce(sum(p.route_count), 0)::bigint as routes,
  i.route_goal, i.prize_cents,
  (coalesce(sum(p.route_count), 0) >= i.route_goal) as prize_unlocked,
  greatest(i.route_goal::bigint - coalesce(sum(p.route_count), 0), 0)::bigint as routes_remaining,
  i.name as influencer_name
from indique_ganhe_influencer.referrals r
join indique_ganhe_influencer.influencers i on i.id = r.influencer_id
left join indique_ganhe_influencer.performance_contributions p on p.uuid = r.uuid
where r.influencer_id is not null
group by r.uuid, r.name, r.region, r.phone, r.cpf, i.route_goal, i.prize_cents, i.name;

alter table indique_ganhe_influencer.influencers enable row level security;
alter table indique_ganhe_influencer.account_members enable row level security;
alter table indique_ganhe_influencer.account_invites enable row level security;
alter table indique_ganhe_influencer.import_batches enable row level security;
alter table indique_ganhe_influencer.import_rows enable row level security;
alter table indique_ganhe_influencer.referrals enable row level security;
alter table indique_ganhe_influencer.performance_contributions enable row level security;
alter table indique_ganhe_influencer.attribution_reviews enable row level security;

drop policy if exists influencers_authenticated_read on indique_ganhe_influencer.influencers;
create policy influencers_authenticated_read on indique_ganhe_influencer.influencers for select to authenticated using (true);
drop policy if exists members_self_or_admin_read on indique_ganhe_influencer.account_members;
create policy members_self_or_admin_read on indique_ganhe_influencer.account_members for select to authenticated
  using (user_id = auth.uid() or indique_ganhe_influencer.is_admin());
drop policy if exists invites_admin_only on indique_ganhe_influencer.account_invites;
create policy invites_admin_only on indique_ganhe_influencer.account_invites for all to authenticated
  using (indique_ganhe_influencer.is_admin()) with check (indique_ganhe_influencer.is_admin());
drop policy if exists imports_admin_only on indique_ganhe_influencer.import_batches;
create policy imports_admin_only on indique_ganhe_influencer.import_batches for all to authenticated
  using (indique_ganhe_influencer.is_admin()) with check (indique_ganhe_influencer.is_admin());
drop policy if exists import_rows_admin_only on indique_ganhe_influencer.import_rows;
create policy import_rows_admin_only on indique_ganhe_influencer.import_rows for all to authenticated
  using (indique_ganhe_influencer.is_admin()) with check (indique_ganhe_influencer.is_admin());
drop policy if exists referrals_owner_or_admin_read on indique_ganhe_influencer.referrals;
create policy referrals_owner_or_admin_read on indique_ganhe_influencer.referrals for select to authenticated
  using (indique_ganhe_influencer.is_admin() or influencer_id = indique_ganhe_influencer.current_influencer_id());
drop policy if exists performance_referrals_owner_or_admin_read on indique_ganhe_influencer.performance_contributions;
create policy performance_referrals_owner_or_admin_read on indique_ganhe_influencer.performance_contributions for select to authenticated
  using (indique_ganhe_influencer.is_admin() or exists (
    select 1 from indique_ganhe_influencer.referrals r
    where r.uuid = performance_contributions.uuid and r.influencer_id = indique_ganhe_influencer.current_influencer_id()
  ));
drop policy if exists reviews_admin_only on indique_ganhe_influencer.attribution_reviews;
create policy reviews_admin_only on indique_ganhe_influencer.attribution_reviews for all to authenticated
  using (indique_ganhe_influencer.is_admin()) with check (indique_ganhe_influencer.is_admin());

revoke all on schema indique_ganhe_influencer from public, anon, authenticated, service_role;
grant usage on schema indique_ganhe_influencer to authenticated;
revoke all on all tables in schema indique_ganhe_influencer from public, anon;
revoke all on all sequences in schema indique_ganhe_influencer from public, anon, authenticated;
grant select on indique_ganhe_influencer.influencers,
  indique_ganhe_influencer.account_members,
  indique_ganhe_influencer.import_batches,
  indique_ganhe_influencer.referrals,
  indique_ganhe_influencer.performance_contributions,
  indique_ganhe_influencer.attribution_reviews,
  indique_ganhe_influencer.referral_progress to authenticated;
revoke all on indique_ganhe_influencer.account_invites, indique_ganhe_influencer.import_rows from authenticated;

revoke execute on all functions in schema indique_ganhe_influencer from public, anon;
grant execute on function indique_ganhe_influencer.is_admin() to authenticated;
grant execute on function indique_ganhe_influencer.current_influencer_id() to authenticated;
grant execute on function indique_ganhe_influencer.claim_invite() to authenticated;
grant execute on function indique_ganhe_influencer.current_profile() to authenticated;
grant execute on function indique_ganhe_influencer.admin_overview() to authenticated;
grant execute on function indique_ganhe_influencer.create_account_invite(text, text) to authenticated;
grant execute on function indique_ganhe_influencer.start_import(text, text, text, jsonb, integer) to authenticated;
grant execute on function indique_ganhe_influencer.append_import_rows(uuid, jsonb) to authenticated;
grant execute on function indique_ganhe_influencer.cancel_import(uuid) to authenticated;
grant execute on function indique_ganhe_influencer.complete_import(uuid) to authenticated;
grant execute on function indique_ganhe_influencer.assign_review(uuid, text) to authenticated;
