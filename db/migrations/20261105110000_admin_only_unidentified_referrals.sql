begin;

-- Leads de Mensagens sem UUID são dados operacionais internos e não devem
-- aparecer nas consultas dos influenciadores, mesmo quando já atribuídos.
drop policy if exists data_crazy_unidentified_owner_or_admin_read
  on indique_ganhe_influencer.data_crazy_unidentified_referrals;

drop policy if exists data_crazy_unidentified_admin_only_read
  on indique_ganhe_influencer.data_crazy_unidentified_referrals;
create policy data_crazy_unidentified_admin_only_read
  on indique_ganhe_influencer.data_crazy_unidentified_referrals
  for select to authenticated
  using (indique_ganhe_influencer.is_admin());

commit;
