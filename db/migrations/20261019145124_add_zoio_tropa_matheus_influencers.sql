begin;

update indique_ganhe_influencer.influencers
set sort_order = 13
where id = 'teste' and is_demo;

insert into indique_ganhe_influencer.influencers
  (id, name, route_goal, prize_cents, sort_order, is_demo)
values
  ('zoio-motoboy', 'Zoio motoboy', 170, 25000, 10, false),
  ('tropa-do-bate-lata', 'Tropa do bate lata', 170, 25000, 11, false),
  ('matheus', 'Matheus', 30, 10000, 12, false)
on conflict (id) do update set
  name = excluded.name,
  route_goal = excluded.route_goal,
  prize_cents = excluded.prize_cents,
  sort_order = excluded.sort_order,
  is_demo = false;

commit;
