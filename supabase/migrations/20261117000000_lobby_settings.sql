-- Host-editable lobby settings, and an anonymous "you received a gift" notice.
--
-- Settings (editable by the host until the game starts):
--   board_size        10-20 (square grid)
--   max_players       4-25
--   max_hearts        1-10 (players start with 3, or max_hearts if lower)
--   ap_drops_per_day  1-12
--   ap_window_start / ap_window_end: drops land at random times in this window
--   timezone

alter table public.games drop constraint if exists games_max_players_check;
alter table public.games add constraint games_max_players_check check (max_players between 4 and 25);
alter table public.games drop constraint if exists games_board_size_check;
alter table public.games add constraint games_board_size_check check (board_size between 10 and 20);

alter table public.games
  add column if not exists max_hearts       int  not null default 4 check (max_hearts between 1 and 10),
  add column if not exists ap_drops_per_day int  not null default 2 check (ap_drops_per_day between 1 and 12),
  add column if not exists ap_window_start  time not null default '08:00',
  add column if not exists ap_window_end    time not null default '20:00';
alter table public.games drop constraint if exists games_ap_window_check;
alter table public.games add constraint games_ap_window_check check (ap_window_start < ap_window_end);

alter table public.players drop constraint if exists players_color_check;
alter table public.players add constraint players_color_check check (color between 0 and 24);
alter table public.players drop constraint if exists players_hearts_check;
alter table public.players add constraint players_hearts_check check (hearts between 0 and 10);

------------------------------------------------------------------------------
-- Lobby
------------------------------------------------------------------------------

create or replace function public.create_game(p_name text, p_max_players int, p_timezone text)
returns uuid language plpgsql security definer set search_path = public as $$
declare
  v_code text;
  v_id uuid;
begin
  if auth.uid() is null then raise exception 'Not signed in'; end if;
  if p_max_players not between 4 and 25 then raise exception 'Max players must be between 4 and 25'; end if;
  if not exists (select 1 from pg_timezone_names where name = p_timezone) then
    raise exception 'Unknown time zone %', p_timezone;
  end if;
  loop
    select string_agg(substr('ABCDEFGHJKLMNPQRSTUVWXYZ23456789', 1 + floor(random() * 32)::int, 1), '')
      into v_code from generate_series(1, 6);
    exit when not exists (select 1 from games where code = v_code);
  end loop;
  insert into games (code, host_id, max_players, timezone)
  values (v_code, auth.uid(), p_max_players, p_timezone) returning id into v_id;
  insert into players (game_id, user_id, name, color) values (v_id, auth.uid(), btrim(p_name), 0);
  return v_id;
end $$;

create or replace function public.update_settings(
  p_game uuid,
  p_board_size int,
  p_max_players int,
  p_max_hearts int,
  p_ap_drops_per_day int,
  p_ap_window_start time,
  p_ap_window_end time,
  p_timezone text
) returns void language plpgsql security definer set search_path = public as $$
declare g games; v_count int;
begin
  g := internal.lock_game(p_game, 'lobby');
  if g.host_id is distinct from auth.uid() then raise exception 'Only the host can change the settings'; end if;
  if p_board_size not between 10 and 20 then raise exception 'Grid size must be between 10 and 20'; end if;
  if p_max_players not between 4 and 25 then raise exception 'Max players must be between 4 and 25'; end if;
  select count(*) into v_count from players where game_id = p_game;
  if p_max_players < v_count then raise exception '% players have already joined', v_count; end if;
  if p_max_hearts not between 1 and 10 then raise exception 'Max hearts must be between 1 and 10'; end if;
  if p_ap_drops_per_day not between 1 and 12 then raise exception 'AP drops per day must be between 1 and 12'; end if;
  if p_ap_window_start is null or p_ap_window_end is null or p_ap_window_start >= p_ap_window_end then
    raise exception 'The AP window must start before it ends (on the same day)';
  end if;
  if not exists (select 1 from pg_timezone_names where name = p_timezone) then
    raise exception 'Unknown time zone %', p_timezone;
  end if;
  update games set
    board_size = p_board_size, max_players = p_max_players, max_hearts = p_max_hearts,
    ap_drops_per_day = p_ap_drops_per_day, ap_window_start = p_ap_window_start, ap_window_end = p_ap_window_end,
    timezone = p_timezone, updated_at = now()
  where id = p_game;
end $$;

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
  select min(c) into v_color from generate_series(0, 24) c
   where c not in (select color from players where game_id = g.id);
  insert into players (game_id, user_id, name, color) values (g.id, auth.uid(), btrim(p_name), v_color);
  perform internal.touch_game(g.id);
  return g.id;
end $$;

------------------------------------------------------------------------------
-- Clock: drops follow the game's count and window
------------------------------------------------------------------------------

create or replace function internal.schedule_drops(g public.games, p_day int, p_not_before timestamptz default null)
returns void language plpgsql as $$
declare
  ws timestamptz := (((g.day1_date + (p_day - 1)) + g.ap_window_start)::timestamp) at time zone g.timezone;
  we timestamptz := (((g.day1_date + (p_day - 1)) + g.ap_window_end)::timestamp) at time zone g.timezone;
begin
  if p_not_before is not null then ws := greatest(ws, p_not_before); end if;
  if ws >= we then return; end if;
  insert into public.ap_drops (game_id, day, scheduled_at)
  select g.id, p_day, ws + random() * (we - ws) from generate_series(1, g.ap_drops_per_day);
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

  -- Day 1 is today, unless today's AP window has already closed.
  v_local := now() at time zone g.timezone;
  update games
     set status = 'active', current_day = 1, started_at = now(), updated_at = now(),
         day1_date = case when v_local::time >= g.ap_window_end then v_local::date + 1 else v_local::date end
   where id = p_game returning * into g;
  update games set day_ends_at = internal.day_start(g, 2) where id = p_game returning * into g;

  update players set hearts = least(3, g.max_hearts), ap = 0, range = 2 where game_id = p_game;

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
-- Actions: per-game heart cap; gifts notify the receiver anonymously
------------------------------------------------------------------------------

create or replace function public.act_add_heart(p_game uuid)
returns void language plpgsql security definer set search_path = public as $$
declare me players; g games;
begin
  me := internal.require_action(p_game, 3);
  select * into g from games where id = p_game;
  if me.hearts >= g.max_hearts then raise exception 'You already have the maximum of % hearts', g.max_hearts; end if;
  update players set ap = ap - 3, hearts = hearts + 1 where id = me.id;
end $$;

create or replace function public.gift(p_game uuid, p_target uuid, p_kind text, p_amount int default 1)
returns void language plpgsql security definer set search_path = public as $$
declare me players; t players; g games;
begin
  me := internal.require_action(p_game, 0);
  select * into g from games where id = p_game;
  t := internal.other(p_game, p_target);
  if t.id = me.id then raise exception 'You cannot send a gift to yourself'; end if;
  if internal.dist(me, t) > me.range then raise exception '% is out of range', t.name; end if;
  if p_amount is null or p_amount < 1 then raise exception 'Amount must be at least 1'; end if;

  if p_kind = 'ap' then
    if not t.alive then raise exception 'Dead players cannot receive AP. Send them a heart to revive them.'; end if;
    if me.ap < p_amount then raise exception 'You only have % AP', me.ap; end if;
    update players set ap = ap - p_amount where id = me.id;
    update players set ap = ap + p_amount where id = t.id;
    perform internal.log(p_game, 'gift', null, t.id,
      format('Someone sent you %s AP.', p_amount), '{}', array[t.id]);

  elsif p_kind = 'heart' then
    if me.hearts - p_amount < 1 then raise exception 'You must keep at least 1 heart'; end if;
    if not t.alive then
      if p_amount <> 1 then raise exception 'Reviving takes exactly 1 heart'; end if;
      update players set hearts = hearts - 1 where id = me.id;
      update players set hearts = 1, ap = 0, killed_by = null, died_at = null where id = t.id;
      perform internal.log(p_game, 'revive', null, t.id, format('%s was revived!', t.name));
    else
      if t.hearts + p_amount > g.max_hearts then
        raise exception '% can''t hold that many hearts (the maximum is %)', t.name, g.max_hearts;
      end if;
      update players set hearts = hearts - p_amount where id = me.id;
      update players set hearts = hearts + p_amount where id = t.id;
      perform internal.log(p_game, 'gift', null, t.id,
        format('Someone sent you %s %s.', p_amount, case when p_amount = 1 then 'heart' else 'hearts' end),
        '{}', array[t.id]);
    end if;
  else
    raise exception 'Gift must be heart or ap';
  end if;
end $$;

revoke execute on all functions in schema internal from public;
revoke execute on function public.update_settings(uuid, int, int, int, int, time, time, text) from public, anon;
grant execute on function public.update_settings(uuid, int, int, int, int, time, time, text) to authenticated;
