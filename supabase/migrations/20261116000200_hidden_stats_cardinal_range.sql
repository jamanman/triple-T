-- 1. Range is counted in cardinal steps (Manhattan distance), not diagonally.
-- 2. Hearts, AP and range are secret: players see only their own until the game ends.
--    The players table is no longer readable by clients; they read players_view,
--    which blanks other players' stats. Events can be private to some players.
-- 3. Accounts are email-based (configured in Supabase Auth, see README).

------------------------------------------------------------------------------
-- Range: cardinal steps only
------------------------------------------------------------------------------

create or replace function internal.dist(a public.players, b public.players)
returns int language sql immutable as $$
  select abs(a.x - b.x) + abs(a.y - b.y);
$$;

------------------------------------------------------------------------------
-- Hidden stats
------------------------------------------------------------------------------

-- Gifted hearts are not capped at 4 (only buying is). A cap would let players
-- learn someone's hearts by probing with gifts that get rejected.
alter table public.players drop constraint if exists players_hearts_check;
alter table public.players add constraint players_hearts_check check (hearts >= 0);

drop policy if exists players_read on public.players;
revoke select on public.players from anon, authenticated;

create or replace function public.my_player_id(p_game uuid)
returns uuid language sql stable security definer set search_path = public as $$
  select id from players where game_id = p_game and user_id = auth.uid();
$$;

create or replace view public.players_view with (security_barrier) as
select
  p.id, p.game_id, p.user_id, p.name, p.color, p.x, p.y, p.alive, p.killed_by, p.plea, p.joined_at,
  case when p.user_id = auth.uid() or g.status = 'finished' then p.hearts end as hearts,
  case when p.user_id = auth.uid() or g.status = 'finished' then p.ap     end as ap,
  case when p.user_id = auth.uid() or g.status = 'finished' then p.range  end as range
from public.players p
join public.games g on g.id = p.game_id
where public.is_game_member(p.game_id);

revoke all on public.players_view from anon;
grant select on public.players_view to authenticated;

-- Votes policy used to read players directly.
drop policy if exists votes_read_own on public.jury_votes;
create policy votes_read_own on public.jury_votes for select to authenticated
  using (voter_id = public.my_player_id(game_id));

-- Events: visible_to = null means everyone in the game; otherwise only those players.
alter table public.events add column if not exists visible_to uuid[];
drop policy if exists events_read on public.events;
create policy events_read on public.events for select to authenticated
  using (public.is_game_member(game_id) and (visible_to is null or public.my_player_id(game_id) = any (visible_to)));

-- Player rows can no longer be streamed. Clients refresh on events instead,
-- so every publicly visible change below logs an event.
do $$
begin
  if exists (select 1 from pg_publication_tables
             where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'players') then
    alter publication supabase_realtime drop table public.players;
  end if;
end $$;

create or replace function internal.log(p_game uuid, p_kind text, p_actor uuid, p_target uuid,
                                        p_message text, p_data jsonb default '{}', p_visible_to uuid[] default null)
returns void language sql as $$
  insert into public.events (game_id, kind, actor_id, target_id, message, data, visible_to)
  values (p_game, p_kind, p_actor, p_target, p_message, coalesce(p_data, '{}'), p_visible_to);
$$;
drop function if exists internal.log(uuid, text, uuid, uuid, text, jsonb);
revoke execute on all functions in schema internal from public;

------------------------------------------------------------------------------
-- Functions whose messages or checks change
------------------------------------------------------------------------------

create or replace function public.join_game(p_code text, p_name text)
returns uuid language plpgsql security definer set search_path = public as $$
declare
  g games;
  v_color int;
begin
  if auth.uid() is null then raise exception 'Not signed in'; end if;
  select * into g from games where code = upper(btrim(p_code)) for update;
  if not found then raise exception 'No game with code %', upper(btrim(p_code)); end if;
  if exists (select 1 from players where game_id = g.id and user_id = auth.uid()) then return g.id; end if;
  if g.status <> 'lobby' then raise exception 'That game has already started'; end if;
  if (select count(*) from players where game_id = g.id) >= g.max_players then
    raise exception 'That game is full (% players)', g.max_players;
  end if;
  if exists (select 1 from players where game_id = g.id and lower(name) = lower(btrim(p_name))) then
    raise exception 'Someone in that game is already called %', btrim(p_name);
  end if;
  select min(c) into v_color from generate_series(0, 19) c
   where c not in (select color from players where game_id = g.id);
  insert into players (game_id, user_id, name, color) values (g.id, auth.uid(), btrim(p_name), v_color);
  perform internal.log(g.id, 'join', null, null, format('%s joined.', btrim(p_name)));
  return g.id;
end $$;

create or replace function public.leave_game(p_game uuid)
returns void language plpgsql security definer set search_path = public as $$
declare g games; me players;
begin
  g := internal.lock_game(p_game, 'lobby');
  me := internal.me(p_game);
  if g.host_id = auth.uid() then
    delete from games where id = p_game;
  else
    delete from players where id = me.id;
    perform internal.log(p_game, 'leave', null, null, format('%s left.', me.name));
  end if;
end $$;

create or replace function public.act_shoot(p_game uuid, p_target uuid)
returns void language plpgsql security definer set search_path = public as $$
declare me players; t players;
begin
  me := internal.require_action(p_game, 1);
  t := internal.other(p_game, p_target);
  if t.id = me.id then raise exception 'You cannot shoot yourself'; end if;
  if not t.alive then raise exception '% is already dead', t.name; end if;
  if internal.dist(me, t) > me.range then raise exception '% is out of range', t.name; end if;

  update players set ap = ap - 1 where id = me.id;
  update players set hearts = hearts - 1 where id = t.id returning * into t;

  if t.alive then
    perform internal.log(p_game, 'shoot', me.id, t.id, format('%s shot %s.', me.name, t.name));
  else
    update players set ap = ap + t.ap where id = me.id;
    update players set ap = 0, killed_by = me.id, died_at = now() where id = t.id;
    perform internal.log(p_game, 'kill', me.id, t.id, format('%s killed %s.', me.name, t.name));
    if t.ap > 0 then
      perform internal.log(p_game, 'loot', me.id, t.id, format('You took %s AP from %s.', t.ap, t.name),
        jsonb_build_object('ap', t.ap), array[me.id]);
    end if;
    perform internal.check_survivors(p_game);
  end if;
end $$;

create or replace function public.act_add_heart(p_game uuid)
returns void language plpgsql security definer set search_path = public as $$
declare me players;
begin
  me := internal.require_action(p_game, 3);
  if me.hearts >= 4 then raise exception 'You can only buy hearts up to 4'; end if;
  update players set ap = ap - 3, hearts = hearts + 1 where id = me.id;
  perform internal.log(p_game, 'heal', me.id, null, format('You bought a heart (now %s).', me.hearts + 1), '{}', array[me.id]);
end $$;

create or replace function public.act_upgrade_range(p_game uuid)
returns void language plpgsql security definer set search_path = public as $$
declare me players; g games;
begin
  me := internal.require_action(p_game, 3);
  select * into g from games where id = p_game;
  if me.range >= 2 * (g.board_size - 1) then raise exception 'Your range already covers the whole board'; end if;
  update players set ap = ap - 3, range = range + 1 where id = me.id;
  perform internal.log(p_game, 'upgrade', me.id, null, format('You upgraded your range to %s.', me.range + 1), '{}', array[me.id]);
end $$;

-- Gifts are private between giver and receiver. Reviving is public (the body gets up).
create or replace function public.gift(p_game uuid, p_target uuid, p_kind text, p_amount int default 1)
returns void language plpgsql security definer set search_path = public as $$
declare me players; t players;
begin
  me := internal.require_action(p_game, 0);
  t := internal.other(p_game, p_target);
  if t.id = me.id then raise exception 'You cannot send a gift to yourself'; end if;
  if internal.dist(me, t) > me.range then raise exception '% is out of range', t.name; end if;
  if p_amount is null or p_amount < 1 then raise exception 'Amount must be at least 1'; end if;

  if p_kind = 'ap' then
    if not t.alive then raise exception 'Dead players cannot receive AP. Send them a heart to revive them.'; end if;
    if me.ap < p_amount then raise exception 'You only have % AP', me.ap; end if;
    update players set ap = ap - p_amount where id = me.id;
    update players set ap = ap + p_amount where id = t.id;
    perform internal.log(p_game, 'gift_ap', me.id, t.id, format('%s sent %s %s AP.', me.name, t.name, p_amount),
      '{}', array[me.id, t.id]);

  elsif p_kind = 'heart' then
    if me.hearts - p_amount < 1 then raise exception 'You must keep at least 1 heart'; end if;
    if not t.alive then
      if p_amount <> 1 then raise exception 'Reviving takes exactly 1 heart'; end if;
      update players set hearts = hearts - 1 where id = me.id;
      update players set hearts = 1, ap = 0, killed_by = null, died_at = null where id = t.id;
      perform internal.log(p_game, 'revive', me.id, t.id, format('%s revived %s!', me.name, t.name));
    else
      update players set hearts = hearts - p_amount where id = me.id;
      update players set hearts = hearts + p_amount where id = t.id;
      perform internal.log(p_game, 'gift_heart', me.id, t.id,
        format('%s sent %s %s %s.', me.name, t.name, p_amount, case when p_amount = 1 then 'heart' else 'hearts' end),
        '{}', array[me.id, t.id]);
    end if;
  else
    raise exception 'Gift must be heart or ap';
  end if;
end $$;

create or replace function public.submit_plea(p_game uuid, p_plea text)
returns void language plpgsql security definer set search_path = public as $$
declare me players;
begin
  perform internal.lock_game(p_game, 'finale');
  me := internal.me(p_game);
  if not me.alive then raise exception 'Only survivors plead their case'; end if;
  update players set plea = nullif(btrim(p_plea), '') where id = me.id;
  perform internal.log(p_game, 'plea', me.id, null, format('%s updated their plea.', me.name));
end $$;

create or replace function internal.process_game(p_game uuid)
returns void language plpgsql as $$
declare
  g public.games;
  d record;
  v_haunted uuid;
  v_name text;
begin
  select * into g from public.games where id = p_game and status = 'active' for update skip locked;
  if not found then return; end if;

  loop
    for d in
      select * from public.ap_drops
      where game_id = g.id and processed_at is null and scheduled_at <= now()
      order by scheduled_at
    loop
      select haunted_id into v_haunted from public.jury_results where game_id = g.id and day = d.day - 1;
      update public.players set ap = ap + 1
       where game_id = g.id and alive and id is distinct from v_haunted;
      update public.ap_drops set processed_at = now() where id = d.id;
      select name into v_name from public.players where id = v_haunted and alive;
      perform internal.log(g.id, 'ap_drop', null, null,
        'AP drop! Every living player received 1 AP' || coalesce(format(' (except %s, who is haunted)', v_name), '') || '.',
        jsonb_build_object('day', d.day));
    end loop;

    exit when now() < internal.day_start(g, g.current_day + 1);

    perform internal.tally_day(g, g.current_day);
    if g.current_day >= g.total_days then
      perform internal.start_finale(g.id, format('Day %s is over.', g.total_days));
      return;
    end if;
    update public.games set current_day = current_day + 1, day_ends_at = internal.day_start(g, g.current_day + 2)
     where id = g.id returning * into g;
    perform internal.schedule_drops(g, g.current_day);
    perform internal.log(g.id, 'new_day', null, null, format('Day %s of %s begins.', g.current_day, g.total_days));
  end loop;
end $$;

revoke execute on all functions in schema internal from public;
revoke execute on function public.my_player_id(uuid) from public, anon;
grant execute on function public.my_player_id(uuid) to authenticated;
