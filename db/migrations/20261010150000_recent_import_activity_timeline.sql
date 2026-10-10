begin;

create index if not exists import_activity_recent_timeline_idx
  on indique_ganhe_influencer.import_activity (created_at desc, id desc);

create or replace function indique_ganhe_influencer.list_recent_import_activity(
  p_limit integer default 60,
  p_kind text default 'all'
)
returns jsonb language plpgsql stable security definer
set search_path = pg_catalog, indique_ganhe_influencer
as $$
declare
  v_kind text := coalesce(nullif(p_kind, ''), 'all');
begin
  if not indique_ganhe_influencer.is_admin() then
    raise exception 'Apenas a administração pode consultar o histórico.';
  end if;
  if p_limit is null or p_limit < 1 or p_limit > 100 then
    raise exception 'A quantidade de atividades deve ficar entre 1 e 100.';
  end if;
  if v_kind not in ('all', 'data_crazy', 'performance') then
    raise exception 'Filtro de origem inválido.';
  end if;

  return (
    select coalesce(
      jsonb_agg(to_jsonb(activity) order by activity.created_at desc, activity.id desc),
      '[]'::jsonb
    )
    from (
      select e.id, e.batch_id, b.kind, b.source, b.file_name,
        e.event_type, e.message, e.details, e.created_at,
        m.email as actor_email, m.display_name as actor_display_name
      from indique_ganhe_influencer.import_activity e
      join indique_ganhe_influencer.import_batches b on b.id = e.batch_id
      left join indique_ganhe_influencer.account_members m on m.user_id = e.actor_id
      where v_kind = 'all' or b.kind = v_kind
      order by e.created_at desc, e.id desc
      limit p_limit
    ) activity
  );
end;
$$;

revoke execute on function indique_ganhe_influencer.list_recent_import_activity(integer, text)
  from public, anon;
grant execute on function indique_ganhe_influencer.list_recent_import_activity(integer, text)
  to authenticated;

notify pgrst, 'reload schema';

commit;
