-- 1. Gifted hearts cannot take a player above 4.
-- 2. The activity feed only records: AP being handed out, deaths, revives,
--    moves, and (privately, to the victim) being shot. Nothing in the feed says
--    who shot, killed or revived whom.
--    Other changes reach clients through games.updated_at (public changes) and
--    player_pings (private changes to one player's stats).
-- 3. Jury results are visible to the jury only (the bonus reveals AP).

alter table public.players drop constraint if exists players_hearts_check;
alter table public.players add constraint players_hearts_check check (hearts between 0 and 4);

alter table public.games add column if not exists updated_at timestamptz not null default now();

-- Killers stay anonymous: drop killed_by from what clients can read.
drop view if exists public.players_view;
create view public.players_view with (security_barrier) as
select
  p.id, p.game_id, p.user_id, p.name, p.color, p.x, p.y, p.alive, p.plea, p.joined_at,
  case when p.user_id = auth.uid() or g.status = 'finished' then p.hearts end as hearts,
  case when p.user_id = auth.uid() or g.status = 'finished' then p.ap     end as ap,
  case when p.user_id = auth.uid() or g.status = 'finished' then p.range  end as range
from public.players p
join public.games g on g.id = p.game_id
where public.is_game_member(p.game_id);
revoke all on public.players_view from anon;
grant select on public.players_view to authenticated;

-- Private "your stats changed" signal, one row per player, readable only by that player.
create table if not exists public.player_pings (
  player_id uuid primary key references public.players (id) on delete cascade,
  game_id   uuid not null references public.games (id) on delete cascade,
  at        timestamptz not null default now()
);
alter table public.player_pings enable row level security;
drop policy if exists pings_read_own on public.player_pings;
create policy pings_read_own on public.player_pings for select to authenticated
  using (player_id = public.my_player_id(game_id));
revoke insert, update, delete, truncate on public.player_pings from anon, authenticated;

create or replace function public.am_juror(p_game uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from players where game_id = p_game and user_id = auth.uid() and not alive);
$$;
revoke execute on function public.am_juror(uuid) from public, anon;
grant execute on function public.am_juror(uuid) to authenticated;

drop policy if exists results_read on public.jury_results;
create policy results_read on public.jury_results for select to authenticated
  using (public.am_juror(game_id));

do $$
begin
  if exists (select 1 from pg_publication where pubname = 'supabase_realtime')
     and not exists (select 1 from pg_publication_tables
                     where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'player_pings') then
    alter publication supabase_realtime add table public.player_pings;
  end if;
end $$;

create or replace function internal.ping(p_player uuid)
returns void language sql as $$
  insert into public.player_pings (player_id, game_id)
  select id, game_id from public.players where id = p_player
  on conflict (player_id) do update set at = now();
$$;

create or replace function internal.touch_game(p_game uuid)
returns void language sql as $$
  update public.games set updated_at = now() where id = p_game;
$$;

-- Clean up feed entries from earlier versions.
delete from public.events where kind not in ('ap_drop', 'death', 'revive', 'move', 'shot', 'bonus', 'haunted');
update public.events set actor_id = null where kind <> 'move';

------------------------------------------------------------------------------
-- Lobby
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
  perform internal.touch_game(g.id);
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
    perform internal.touch_game(p_game);
  end if;
end $$;

create or replace function public.start_game(p_game uuid)
returns void language plpgsql security definer set search_path = public as $$
declare
  g games;
  v_local timestamp;
begin
  g := internal.lock_game(p_game, 'lobby');
  if g.host_id is distinct from auth.uid() then raise exception 'Only the host can start the game'; end if;
  if (select count(*) from players where game_id = p_game) < 4 then
    raise exception 'You need at least 4 players to start';
  end if;

  v_local := now() at time zone g.timezone;
  update games
     set status = 'active', current_day = 1, started_at = now(), updated_at = now(),
         day1_date = case when v_local::time >= time '20:00' then v_local::date + 1 else v_local::date end
   where id = p_game returning * into g;
  update games set day_ends_at = internal.day_start(g, 2) where id = p_game returning * into g;

  with cells as (
    select n % g.board_size as x, n / g.board_size as y, row_number() over (order by random()) as rn
    from generate_series(0, g.board_size * g.board_size - 1) n
  ), ps as (
    select id, row_number() over (order by random()) as rn from players where game_id = p_game
  )
  update players p set x = c.x, y = c.y from ps join cells c using (rn) where p.id = ps.id;

  perform internal.schedule_drops(g, 1, now());
end $$;

------------------------------------------------------------------------------
-- Actions
------------------------------------------------------------------------------

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
    perform internal.log(p_game, 'shot', null, t.id,
      format('You were shot! %s %s left.', t.hearts, case when t.hearts = 1 then 'heart' else 'hearts' end),
      '{}', array[t.id]);
  else
    update players set ap = ap + t.ap where id = me.id;
    update players set ap = 0, killed_by = me.id, died_at = now() where id = t.id;
    perform internal.log(p_game, 'death', null, t.id, format('%s died.', t.name));
    perform internal.check_survivors(p_game);
  end if;
end $$;

create or replace function public.act_add_heart(p_game uuid)
returns void language plpgsql security definer set search_path = public as $$
declare me players;
begin
  me := internal.require_action(p_game, 3);
  if me.hearts >= 4 then raise exception 'You already have the maximum of 4 hearts'; end if;
  update players set ap = ap - 3, hearts = hearts + 1 where id = me.id;
end $$;

create or replace function public.act_upgrade_range(p_game uuid)
returns void language plpgsql security definer set search_path = public as $$
declare me players; g games;
begin
  me := internal.require_action(p_game, 3);
  select * into g from games where id = p_game;
  if me.range >= 2 * (g.board_size - 1) then raise exception 'Your range already covers the whole board'; end if;
  update players set ap = ap - 3, range = range + 1 where id = me.id;
end $$;

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
    perform internal.ping(t.id);

  elsif p_kind = 'heart' then
    if me.hearts - p_amount < 1 then raise exception 'You must keep at least 1 heart'; end if;
    if not t.alive then
      if p_amount <> 1 then raise exception 'Reviving takes exactly 1 heart'; end if;
      update players set hearts = hearts - 1 where id = me.id;
      update players set hearts = 1, ap = 0, killed_by = null, died_at = null where id = t.id;
      perform internal.log(p_game, 'revive', null, t.id, format('%s was revived!', t.name));
    else
      if t.hearts + p_amount > 4 then
        raise exception '% can''t hold that many hearts (the maximum is 4)', t.name;
      end if;
      update players set hearts = hearts - p_amount where id = me.id;
      update players set hearts = hearts + p_amount where id = t.id;
      perform internal.ping(t.id);
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
  perform internal.touch_game(p_game);
end $$;

------------------------------------------------------------------------------
-- Clock, jury and finale
------------------------------------------------------------------------------

create or replace function internal.tally_day(g public.games, p_day int)
returns void language plpgsql as $$
declare
  v_haunt uuid := internal.top_vote(g.id, p_day, 'haunt');
  v_bonus uuid := internal.top_vote(g.id, p_day, 'bonus');
begin
  insert into public.jury_results (game_id, day, haunted_id, bonus_id) values (g.id, p_day, v_haunt, v_bonus)
  on conflict do nothing;
  if v_bonus is not null then
    update public.players set ap = ap + 2 where id = v_bonus;
    perform internal.log(g.id, 'bonus', null, v_bonus, 'The jury awarded you 2 bonus AP.', '{}', array[v_bonus]);
  end if;
end $$;

create or replace function internal.process_game(p_game uuid)
returns void language plpgsql as $$
declare
  g public.games;
  d record;
  v_haunted uuid;
  v_others uuid[];
begin
  select * into g from public.games where id = p_game and status = 'active' for update skip locked;
  if not found then return; end if;

  loop
    for d in
      select * from public.ap_drops
      where game_id = g.id and processed_at is null and scheduled_at <= now()
      order by scheduled_at
    loop
      select r.haunted_id into v_haunted
        from public.jury_results r join public.players p on p.id = r.haunted_id and p.alive
       where r.game_id = g.id and r.day = d.day - 1;
      update public.players set ap = ap + 1
       where game_id = g.id and alive and id is distinct from v_haunted;
      update public.ap_drops set processed_at = now() where id = d.id;

      if v_haunted is null then
        perform internal.log(g.id, 'ap_drop', null, null, 'AP drop! Every living player received 1 AP.');
      else
        select array_agg(id) into v_others from public.players where game_id = g.id and id <> v_haunted;
        perform internal.log(g.id, 'ap_drop', null, null, 'AP drop! Living players received 1 AP.', '{}', v_others);
        perform internal.log(g.id, 'haunted', null, v_haunted,
          'AP drop, but the jury has haunted you: no AP for you today.', '{}', array[v_haunted]);
      end if;
    end loop;

    exit when now() < internal.day_start(g, g.current_day + 1);

    perform internal.tally_day(g, g.current_day);
    if g.current_day >= g.total_days then
      perform internal.start_finale(g.id, format('Day %s is over.', g.total_days));
      return;
    end if;
    update public.games
       set current_day = current_day + 1, day_ends_at = internal.day_start(g, g.current_day + 2), updated_at = now()
     where id = g.id returning * into g;
    perform internal.schedule_drops(g, g.current_day);
  end loop;
end $$;

create or replace function internal.start_finale(p_game uuid, p_reason text)
returns void language plpgsql as $$
begin
  update public.games
     set status = 'finale', finale_started_at = now(), updated_at = now(),
         finale_ends_at = now() + make_interval(hours => finale_hours)
   where id = p_game and status = 'active';
  if not found then return; end if;
  delete from public.ap_drops where game_id = p_game and processed_at is null;
  if not exists (select 1 from public.players where game_id = p_game and not alive) then
    perform internal.resolve_finale(p_game);
  end if;
end $$;

create or replace function internal.resolve_finale(p_game uuid)
returns void language plpgsql as $$
declare
  g public.games;
  v_winners uuid[];
begin
  select * into g from public.games where id = p_game for update;
  if g.status <> 'finale' then return; end if;

  with counts as (
    select v.target_id, count(*) as n
    from public.jury_votes v
    join public.players voter on voter.id = v.voter_id and not voter.alive
    join public.players target on target.id = v.target_id and target.alive
    where v.game_id = p_game and v.kind = 'winner'
    group by v.target_id
  )
  select array_agg(target_id) into v_winners from counts where n = (select max(n) from counts);

  if v_winners is null then
    select array_agg(id) into v_winners from public.players where game_id = p_game and alive;
  end if;

  update public.games set status = 'finished', winner_ids = v_winners, updated_at = now() where id = p_game;
end $$;

revoke execute on all functions in schema internal from public;
