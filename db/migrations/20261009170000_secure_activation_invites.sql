begin;

alter table indique_ganhe_influencer.account_invites
  add column if not exists activation_token_hash text,
  add column if not exists activation_expires_at timestamptz,
  add column if not exists activation_claim_id uuid,
  add column if not exists activation_claim_started_at timestamptz,
  add column if not exists activation_failed_attempts integer not null default 0,
  add column if not exists activation_failure_window_started_at timestamptz;

alter table indique_ganhe_influencer.account_invites
  drop constraint if exists account_invites_status_check;
alter table indique_ganhe_influencer.account_invites
  add constraint account_invites_status_check
  check (status in ('pending', 'redeeming', 'claimed', 'revoked'));

alter table indique_ganhe_influencer.account_invites
  drop constraint if exists account_invites_activation_hash_check;
alter table indique_ganhe_influencer.account_invites
  add constraint account_invites_activation_hash_check
  check (activation_token_hash is null or activation_token_hash ~ '^[0-9a-f]{64}$');

alter table indique_ganhe_influencer.account_invites
  drop constraint if exists account_invites_activation_failures_check;
alter table indique_ganhe_influencer.account_invites
  add constraint account_invites_activation_failures_check
  check (activation_failed_attempts between 0 and 10);

drop index if exists indique_ganhe_influencer.account_invites_one_pending_per_influencer;
create unique index account_invites_one_pending_per_influencer
  on indique_ganhe_influencer.account_invites (influencer_id)
  where role = 'influencer' and status in ('pending', 'redeeming');

-- The old seed predates activation codes and cannot be redeemed securely.
update indique_ganhe_influencer.account_invites
set status = 'revoked'
where lower(email) = 'owner@gmail.com'
  and status = 'pending'
  and activation_token_hash is null;

create or replace function indique_ganhe_influencer.claim_invite()
returns boolean language sql stable security definer
set search_path = pg_catalog, indique_ganhe_influencer
as $$
  -- Email-only claiming is intentionally disabled. Access is linked only by an
  -- activation code or by the server-side account creation flow.
  select exists (
    select 1 from indique_ganhe_influencer.account_members m
    where m.user_id = auth.uid()
  );
$$;

create or replace function indique_ganhe_influencer.issue_account_activation_invite(
  p_email text,
  p_influencer_id text,
  p_token_hash text,
  p_expires_at timestamptz
)
returns jsonb language plpgsql security definer
set search_path = pg_catalog, indique_ganhe_influencer
as $$
declare
  v_email text := lower(trim(coalesce(p_email, '')));
  v_invite_id uuid;
begin
  if auth.uid() is null or not indique_ganhe_influencer.is_admin() then
    raise exception 'Apenas a administração pode liberar acessos.';
  end if;
  if v_email !~* '^[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}$' then
    raise exception 'Informe um e-mail válido.';
  end if;
  if coalesce(p_token_hash, '') !~ '^[0-9a-f]{64}$' then
    raise exception 'Código de ativação inválido.';
  end if;
  if p_expires_at <= now() or p_expires_at > now() + interval '25 hours' then
    raise exception 'O prazo do convite é inválido.';
  end if;
  if not exists (
    select 1 from indique_ganhe_influencer.influencers i where i.id = p_influencer_id
  ) then
    raise exception 'Influenciador não encontrado.';
  end if;
  if exists (
    select 1 from indique_ganhe_influencer.account_members m where lower(m.email) = v_email
  ) then
    raise exception 'Este e-mail já está vinculado a uma conta.';
  end if;
  if exists (
    select 1 from indique_ganhe_influencer.account_members m
    where m.role = 'influencer' and m.influencer_id = p_influencer_id
  ) then
    raise exception 'Este influenciador já possui uma conta vinculada.';
  end if;
  if exists (
    select 1 from indique_ganhe_influencer.account_invites i
    where lower(i.email) = v_email and i.role = 'admin' and i.status in ('pending', 'redeeming')
  ) then
    raise exception 'Este e-mail já possui um convite administrativo pendente.';
  end if;
  if exists (
    select 1 from indique_ganhe_influencer.account_invites i
    where i.role = 'influencer'
      and i.influencer_id = p_influencer_id
      and i.status in ('pending', 'redeeming')
      and lower(i.email) <> v_email
  ) then
    raise exception 'Este influenciador já possui outro convite pendente.';
  end if;
  if exists (
    select 1 from indique_ganhe_influencer.account_invites i
    where lower(i.email) = v_email
      and i.status in ('pending', 'redeeming')
      and (i.role <> 'influencer' or i.influencer_id <> p_influencer_id)
  ) then
    raise exception 'Este e-mail já possui outro convite pendente.';
  end if;

  insert into indique_ganhe_influencer.account_invites (
    email, role, influencer_id, status, created_by, claimed_by, claimed_at,
    activation_token_hash, activation_expires_at, activation_claim_id,
    activation_claim_started_at, activation_failed_attempts,
    activation_failure_window_started_at
  ) values (
    v_email, 'influencer', p_influencer_id, 'pending', auth.uid(), null, null,
    p_token_hash, p_expires_at, null, null, 0, null
  )
  on conflict (email) do update set
    role = excluded.role,
    influencer_id = excluded.influencer_id,
    status = 'pending',
    created_by = excluded.created_by,
    claimed_by = null,
    claimed_at = null,
    activation_token_hash = excluded.activation_token_hash,
    activation_expires_at = excluded.activation_expires_at,
    activation_claim_id = null,
    activation_claim_started_at = null,
    activation_failed_attempts = 0,
    activation_failure_window_started_at = null
  returning id into v_invite_id;

  return jsonb_build_object(
    'invite_id', v_invite_id,
    'email', v_email,
    'influencer_id', p_influencer_id,
    'expires_at', p_expires_at
  );
end;
$$;

create or replace function indique_ganhe_influencer.begin_account_activation(
  p_email text,
  p_token_hash text,
  p_claim_id uuid
)
returns jsonb language plpgsql security definer
set search_path = pg_catalog, indique_ganhe_influencer
as $$
declare
  v_invite indique_ganhe_influencer.account_invites%rowtype;
  v_email text := lower(trim(coalesce(p_email, '')));
  v_now timestamptz := clock_timestamp();
begin
  select * into v_invite
  from indique_ganhe_influencer.account_invites i
  where lower(i.email) = v_email
  for update;
  if not found then return null; end if;

  if v_invite.activation_failure_window_started_at >= v_now - interval '15 minutes'
    and v_invite.activation_failed_attempts >= 10 then
    return null;
  end if;
  if v_invite.status not in ('pending', 'redeeming')
    or v_invite.activation_token_hash is null
    or v_invite.activation_expires_at <= v_now
    or v_invite.activation_token_hash <> lower(coalesce(p_token_hash, '')) then
    if v_invite.status in ('pending', 'redeeming') and v_invite.activation_expires_at > v_now then
      if v_invite.activation_failure_window_started_at is null
        or v_invite.activation_failure_window_started_at < v_now - interval '15 minutes' then
        update indique_ganhe_influencer.account_invites
        set activation_failed_attempts = 1,
            activation_failure_window_started_at = v_now
        where id = v_invite.id;
      else
        update indique_ganhe_influencer.account_invites
        set activation_failed_attempts = least(activation_failed_attempts + 1, 10)
        where id = v_invite.id;
      end if;
    end if;
    return null;
  end if;
  if v_invite.status = 'redeeming'
    and v_invite.activation_claim_started_at > v_now - interval '15 minutes' then
    return null;
  end if;

  update indique_ganhe_influencer.account_invites
  set status = 'redeeming', activation_claim_id = p_claim_id,
      activation_claim_started_at = v_now,
      activation_failed_attempts = 0,
      activation_failure_window_started_at = null
  where id = v_invite.id;

  return jsonb_build_object(
    'invite_id', v_invite.id,
    'claim_id', p_claim_id,
    'email', v_invite.email,
    'role', v_invite.role,
    'influencer_id', v_invite.influencer_id
  );
end;
$$;

create or replace function indique_ganhe_influencer.finish_account_activation(
  p_invite_id uuid,
  p_claim_id uuid,
  p_user_id uuid
)
returns boolean language plpgsql security definer
set search_path = pg_catalog, indique_ganhe_influencer
as $$
declare
  v_invite indique_ganhe_influencer.account_invites%rowtype;
  v_email text;
  v_confirmed_at timestamptz;
begin
  select * into v_invite
  from indique_ganhe_influencer.account_invites i
  where i.id = p_invite_id
  for update;
  if not found then return false; end if;
  if v_invite.status = 'claimed' and v_invite.claimed_by = p_user_id then return true; end if;
  if v_invite.status <> 'redeeming' or v_invite.activation_claim_id <> p_claim_id then return false; end if;

  select lower(coalesce(u.email, '')), u.email_confirmed_at
  into v_email, v_confirmed_at
  from auth.users u where u.id = p_user_id;
  if v_email <> lower(v_invite.email) or v_confirmed_at is null then return false; end if;

  insert into indique_ganhe_influencer.account_members (user_id, email, role, influencer_id)
  values (p_user_id, v_email, v_invite.role, v_invite.influencer_id);

  update indique_ganhe_influencer.account_invites
  set status = 'claimed', claimed_by = p_user_id, claimed_at = now(),
      activation_token_hash = null, activation_claim_id = null,
      activation_claim_started_at = null, activation_failed_attempts = 0,
      activation_failure_window_started_at = null
  where id = v_invite.id;
  return true;
end;
$$;

create or replace function indique_ganhe_influencer.release_account_activation(
  p_invite_id uuid,
  p_claim_id uuid
)
returns boolean language plpgsql security definer
set search_path = pg_catalog, indique_ganhe_influencer
as $$
begin
  update indique_ganhe_influencer.account_invites
  set status = 'pending', activation_claim_id = null,
      activation_claim_started_at = null
  where id = p_invite_id and status = 'redeeming' and activation_claim_id = p_claim_id;
  return found;
end;
$$;

create or replace function indique_ganhe_influencer.claim_account_activation_invite(
  p_token_hash text
)
returns jsonb language plpgsql security definer
set search_path = pg_catalog, indique_ganhe_influencer
as $$
declare
  v_user uuid := auth.uid();
  v_email text;
  v_invite indique_ganhe_influencer.account_invites%rowtype;
begin
  if v_user is null then raise exception 'Autenticação necessária.'; end if;
  select lower(coalesce(u.email, '')) into v_email from auth.users u where u.id = v_user;
  if coalesce(v_email, '') = '' then return null; end if;

  select * into v_invite
  from indique_ganhe_influencer.account_invites i
  where lower(i.email) = v_email
    and i.activation_token_hash = lower(coalesce(p_token_hash, ''))
    and i.activation_expires_at > now()
    and i.status in ('pending', 'redeeming')
  for update;
  if not found then return null; end if;

  if exists (
    select 1 from indique_ganhe_influencer.account_members m
    where m.user_id = v_user
  ) then
    return null;
  end if;

  insert into indique_ganhe_influencer.account_members (user_id, email, role, influencer_id)
  values (v_user, v_email, v_invite.role, v_invite.influencer_id);

  update indique_ganhe_influencer.account_invites
  set status = 'claimed', claimed_by = v_user, claimed_at = now(),
      activation_token_hash = null, activation_claim_id = null,
      activation_claim_started_at = null, activation_failed_attempts = 0,
      activation_failure_window_started_at = null
  where id = v_invite.id;

  return jsonb_build_object('activated', true, 'user_id', v_user);
end;
$$;

create or replace function indique_ganhe_influencer.revoke_account_invite(p_invite_id uuid)
returns boolean language plpgsql security definer
set search_path = pg_catalog, indique_ganhe_influencer
as $$
begin
  if not indique_ganhe_influencer.is_admin() then
    raise exception 'Apenas a administração pode gerenciar convites.';
  end if;
  update indique_ganhe_influencer.account_invites
  set status = 'revoked', activation_token_hash = null,
      activation_claim_id = null, activation_claim_started_at = null
  where id = p_invite_id and status in ('pending', 'redeeming');
  return found;
end;
$$;

create or replace function indique_ganhe_influencer.create_account_invite(p_email text, p_influencer_id text)
returns jsonb language plpgsql security definer
set search_path = pg_catalog, indique_ganhe_influencer
as $$
begin
  if not indique_ganhe_influencer.is_admin() then
    raise exception 'Apenas a administração pode liberar acessos.';
  end if;
  raise exception 'Use a função indique-ganhe-access para emitir um código de ativação.';
end;
$$;

revoke execute on function indique_ganhe_influencer.create_account_invite(text, text) from public, anon, authenticated;
revoke execute on function indique_ganhe_influencer.issue_account_activation_invite(text, text, text, timestamptz) from public, anon;
revoke execute on function indique_ganhe_influencer.begin_account_activation(text, text, uuid) from public, anon, authenticated;
revoke execute on function indique_ganhe_influencer.finish_account_activation(uuid, uuid, uuid) from public, anon, authenticated;
revoke execute on function indique_ganhe_influencer.release_account_activation(uuid, uuid) from public, anon, authenticated;
revoke execute on function indique_ganhe_influencer.claim_account_activation_invite(text) from public, anon;
revoke execute on function indique_ganhe_influencer.revoke_account_invite(uuid) from public, anon;
revoke execute on function indique_ganhe_influencer.claim_invite() from public, anon;

grant usage on schema indique_ganhe_influencer to service_role;
grant execute on function indique_ganhe_influencer.issue_account_activation_invite(text, text, text, timestamptz) to authenticated;
grant execute on function indique_ganhe_influencer.begin_account_activation(text, text, uuid) to service_role;
grant execute on function indique_ganhe_influencer.finish_account_activation(uuid, uuid, uuid) to service_role;
grant execute on function indique_ganhe_influencer.release_account_activation(uuid, uuid) to service_role;
grant execute on function indique_ganhe_influencer.claim_account_activation_invite(text) to authenticated;
grant execute on function indique_ganhe_influencer.revoke_account_invite(uuid) to authenticated;
grant execute on function indique_ganhe_influencer.claim_invite() to authenticated;

commit;
