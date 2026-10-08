create or replace function indique_ganhe_influencer.create_account_invite(p_email text, p_influencer_id text)
returns jsonb language plpgsql security definer
set search_path = pg_catalog, indique_ganhe_influencer
as $$
declare v_email text := lower(trim(coalesce(p_email, ''))); v_id uuid;
begin
  if not indique_ganhe_influencer.is_admin() then raise exception 'Apenas a administração pode convidar contas.'; end if;
  if v_email !~* '^[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}$' then raise exception 'Informe um e-mail válido.'; end if;
  if not exists (select 1 from indique_ganhe_influencer.influencers i where i.id = p_influencer_id) then raise exception 'Influenciador não encontrado.'; end if;
  if exists (select 1 from indique_ganhe_influencer.account_members m where lower(m.email) = v_email) then raise exception 'Este e-mail já está vinculado a uma conta.'; end if;
  if exists (select 1 from indique_ganhe_influencer.account_members m where m.role = 'influencer' and m.influencer_id = p_influencer_id) then raise exception 'Este influenciador já possui uma conta vinculada.'; end if;
  if exists (select 1 from indique_ganhe_influencer.account_invites i where i.role = 'influencer' and i.influencer_id = p_influencer_id and i.status = 'pending' and i.email <> v_email) then raise exception 'Este influenciador já possui um convite pendente.'; end if;
  insert into indique_ganhe_influencer.account_invites (email, role, influencer_id, status, created_by, claimed_by, claimed_at)
  values (v_email, 'influencer', p_influencer_id, 'pending', auth.uid(), null, null)
  on conflict (email) do update set role = excluded.role, influencer_id = excluded.influencer_id,
    status = 'pending', created_by = excluded.created_by, claimed_by = null, claimed_at = null returning id into v_id;
  return jsonb_build_object('invite_id', v_id, 'email', v_email, 'influencer_id', p_influencer_id, 'status', 'pending');
end;
$$;

revoke execute on function indique_ganhe_influencer.create_account_invite(text, text) from public, anon;
grant execute on function indique_ganhe_influencer.create_account_invite(text, text) to authenticated;
