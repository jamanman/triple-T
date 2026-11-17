-- Triple-T: multiplayer 15x15 grid game.
--
-- All game rules are enforced here. Clients can only READ tables (through RLS)
-- and change state by calling the RPC functions in the public schema. The
-- scheduled jobs (AP drops, day rollover, jury tallies, finale) live in the
-- `internal` schema, which is not exposed through the API.

create schema if not exists internal;
revoke all on schema internal from public;

------------------------------------------------------------------------------
-- Tables
------------------------------------------------------------------------------

create table public.games (
  id                uuid primary key default gen_random_uuid(),
  code              text not null unique,
  host_id           uuid not null,                 -- auth.users.id of the host
  max_players       int  not null check (max_players between 4 and 20),
  timezone          text not null default 'UTC',   -- AP drop window 8am-8pm is in this zone
  board_size        int  not null default 15,
  total_days        int  not null default 5,
  finale_hours      int  not null default 24,      -- how long the jury has to pick a winner
  status            text not null default 'lobby'
                      check (status in ('lobby', 'active', 'finale', 'finished')),
  current_day       int  not null default 0,
  day1_date         date,                          -- local calendar date of day 1
  day_ends_at       timestamptz,                   -- local midnight ending current_day (jury tally)
  started_at        timestamptz,
  finale_started_at timestamptz,
  finale_ends_at    timestamptz,
  winner_ids        uuid[],
  created_at        timestamptz not null default now()
);

create table public.players (
  id         uuid primary key default gen_random_uuid(),
  game_id    uuid not null references public.games (id) on delete cascade,
  user_id    uuid not null,
  name       text not null check (char_length(btrim(name)) between 1 and 20),
  color      int  not null check (color between 0 and 19),
  x          int,
  y          int,
  hearts     int  not null default 3 check (hearts between 0 and 4),
  ap         int  not null default 0 check (ap >= 0),
  range      int  not null default 2,
  alive      boolean generated always as (hearts > 0) stored,
  killed_by  uuid references public.players (id) on delete set null,
  died_at    timestamptz,
  plea       text check (char_length(plea) <= 2000),
  joined_at  timestamptz not null default now(),
  unique (game_id, user_id),
  unique (game_id, name),
  unique (game_id, color)
);
-- Dead players stay on the board, so every player (alive or dead) holds a square.
create unique index players_position_uniq on public.players (game_id, x, y) where x is not null;
create index players_game_idx on public.players (game_id);

create table public.events (
  id         bigint generated always as identity primary key,
  game_id    uuid not null references public.games (id) on delete cascade,
  created_at timestamptz not null default now(),
  kind       text not null,
  actor_id   uuid,
  target_id  uuid,
  message    text not null,
  data       jsonb not null default '{}'
);
create index events_game_idx on public.events (game_id, id desc);

-- The random AP drop times. Not readable by players, so drops stay a surprise.
create table public.ap_drops (
  id           bigint generated always as identity primary key,
  game_id      uuid not null references public.games (id) on delete cascade,
  day          int  not null,
  scheduled_at timestamptz not null,
  processed_at timestamptz
);
create index ap_drops_due_idx on public.ap_drops (game_id, scheduled_at) where processed_at is null;

-- Jury votes. kind = 'haunt' | 'bonus' (daily, day = game day) or 'winner' (finale, day = 0).
create table public.jury_votes (
  game_id    uuid not null references public.games (id) on delete cascade,
  day        int  not null,
  kind       text not null check (kind in ('haunt', 'bonus', 'winner')),
  voter_id   uuid not null references public.players (id) on delete cascade,
  target_id  uuid not null references public.players (id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (game_id, day, kind, voter_id)
);

-- Outcome of each day's jury vote. The haunted player gets no AP on day + 1.
create table public.jury_results (
  game_id    uuid not null references public.games (id) on delete cascade,
  day        int  not null,
  haunted_id uuid references public.players (id) on delete set null,
  bonus_id   uuid references public.players (id) on delete set null,
  primary key (game_id, day)
);

------------------------------------------------------------------------------
-- Row level security: read-only access for members of a game
------------------------------------------------------------------------------

create or replace function public.is_game_member(p_game uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from players where game_id = p_game and user_id = auth.uid());
$$;

alter table public.games        enable row level security;
alter table public.players      enable row level security;
alter table public.events       enable row level security;
alter table public.ap_drops     enable row level security;
alter table public.jury_votes   enable row level security;
alter table public.jury_results enable row level security;

create policy games_read   on public.games        for select to authenticated using (public.is_game_member(id));
create policy players_read on public.players      for select to authenticated using (public.is_game_member(game_id));
create policy events_read  on public.events       for select to authenticated using (public.is_game_member(game_id));
create policy results_read on public.jury_results for select to authenticated using (public.is_game_member(game_id));
-- Jury votes are secret: you can only see your own.
create policy votes_read_own on public.jury_votes for select to authenticated
  using (exists (select 1 from public.players p where p.id = voter_id and p.user_id = auth.uid()));
-- ap_drops: no policy, so nobody can read it through the API.

revoke insert, update, delete, truncate on
  public.games, public.players, public.events, public.ap_drops, public.jury_votes, public.jury_results
  from anon, authenticated;

------------------------------------------------------------------------------
-- Internal helpers
------------------------------------------------------------------------------

create or replace function internal.log(p_game uuid, p_kind text, p_actor uuid, p_target uuid,
                                        p_message text, p_data jsonb default '{}')
returns void language sql as $$
  insert into public.events (game_id, kind, actor_id, target_id, message, data)
  values (p_game, p_kind, p_actor, p_target, p_message, coalesce(p_data, '{}'));
$$;

-- Lock the game row (serialises all actions in one game) and check its status.
create or replace function internal.lock_game(p_game uuid, p_status text)
returns public.games language plpgsql as $$
declare g public.games;
begin
  select * into g from public.games where id = p_game for update;
  if not found then raise exception 'Game not found'; end if;
  if p_status is not null and g.status <> p_status then
    raise exception 'This can only be done while the game is %', p_status;
  end if;
  return g;
end $$;

-- The calling user's player row in a game, locked.
create or replace function internal.me(p_game uuid)
returns public.players language plpgsql as $$
declare v public.players;
begin
  if auth.uid() is null then raise exception 'Not signed in'; end if;
  select * into v from public.players where game_id = p_game and user_id = auth.uid() for update;
  if not found then raise exception 'You are not in this game'; end if;
  return v;
end $$;

create or replace function internal.other(p_game uuid, p_player uuid)
returns public.players language plpgsql as $$
declare v public.players;
begin
  select * into v from public.players where game_id = p_game and id = p_player for update;
  if not found then raise exception 'Player not found'; end if;
  return v;
end $$;

-- Range is measured as Chebyshev distance: diagonals count as 1 square.
create or replace function internal.dist(a public.players, b public.players)
returns int language sql immutable as $$
  select greatest(abs(a.x - b.x), abs(a.y - b.y));
$$;

create or replace function internal.day_start(g public.games, p_day int)
returns timestamptz language sql stable as $$
  select ((g.day1_date + (p_day - 1))::timestamp) at time zone g.timezone;
$$;

-- Schedule this day's two AP drops at random times between 8am and 8pm local.
-- p_not_before stops drops being scheduled in the past on the first day.
create or replace function internal.schedule_drops(g public.games, p_day int, p_not_before timestamptz default null)
returns void language plpgsql as $$
declare
  ws timestamptz := internal.day_start(g, p_day) + interval '8 hours';
  we timestamptz := internal.day_start(g, p_day) + interval '20 hours';
begin
  if p_not_before is not null then ws := greatest(ws, p_not_before); end if;
  if ws >= we then return; end if;
  insert into public.ap_drops (game_id, day, scheduled_at)
  select g.id, p_day, ws + random() * (we - ws) from generate_series(1, 2);
end $$;

-- Pick the most-voted target among votes cast by players who are still dead.
-- Ties are broken at random.
create or replace function internal.top_vote(p_game uuid, p_day int, p_kind text)
returns uuid language sql as $$
  select v.target_id
  from public.jury_votes v
  join public.players voter on voter.id = v.voter_id and not voter.alive
  join public.players target on target.id = v.target_id and target.alive
  where v.game_id = p_game and v.day = p_day and v.kind = p_kind
  group by v.target_id
  order by count(*) desc, random()
  limit 1;
$$;

create or replace function internal.tally_day(g public.games, p_day int)
returns void language plpgsql as $$
declare
  v_haunt uuid := internal.top_vote(g.id, p_day, 'haunt');
  v_bonus uuid := internal.top_vote(g.id, p_day, 'bonus');
  v_name  text;
begin
  insert into public.jury_results (game_id, day, haunted_id, bonus_id) values (g.id, p_day, v_haunt, v_bonus)
  on conflict do nothing;
  if v_haunt is not null then
    select name into v_name from public.players where id = v_haunt;
    perform internal.log(g.id, 'haunt', null, v_haunt,
      format('The jury has haunted %s: no AP for them on day %s.', v_name, p_day + 1));
  end if;
  if v_bonus is not null then
    update public.players set ap = ap + 2 where id = v_bonus returning name into v_name;
    perform internal.log(g.id, 'bonus', null, v_bonus,
      format('The jury awarded %s 2 bonus AP.', v_name));
  end if;
end $$;

create or replace function internal.resolve_finale(p_game uuid)
returns void language plpgsql as $$
declare
  g public.games;
  v_winners uuid[];
  v_names text;
begin
  select * into g from public.games where id = p_game for update;
  if g.status <> 'finale' then return; end if;

  -- Winner = most jury votes; a tie means shared victory.
  with counts as (
    select v.target_id, count(*) as n
    from public.jury_votes v
    join public.players voter on voter.id = v.voter_id and not voter.alive
    join public.players target on target.id = v.target_id and target.alive
    where v.game_id = p_game and v.kind = 'winner'
    group by v.target_id
  )
  select array_agg(target_id) into v_winners from counts where n = (select max(n) from counts);

  -- No jury, or the jury did not vote: every survivor shares the win.
  if v_winners is null then
    select array_agg(id) into v_winners from public.players where game_id = p_game and alive;
  end if;

  update public.games set status = 'finished', winner_ids = v_winners where id = p_game;
  select string_agg(name, ' & ' order by name) into v_names from public.players where id = any (v_winners);
  perform internal.log(p_game, 'winner', null, null,
    case when cardinality(v_winners) > 1 then format('Game over! Shared victory: %s.', v_names)
         else format('Game over! %s wins.', v_names) end,
    jsonb_build_object('winner_ids', to_jsonb(v_winners)));
end $$;

create or replace function internal.start_finale(p_game uuid, p_reason text)
returns void language plpgsql as $$
declare g public.games;
begin
  update public.games
     set status = 'finale', finale_started_at = now(), finale_ends_at = now() + make_interval(hours => finale_hours)
   where id = p_game and status = 'active'
  returning * into g;
  if not found then return; end if;
  -- Drops that have not happened yet are cancelled.
  delete from public.ap_drops where game_id = p_game and processed_at is null;
  perform internal.log(p_game, 'finale', null, null,
    p_reason || ' Survivors: plead your case. Jury: vote for a winner before '
    || to_char(g.finale_ends_at at time zone g.timezone, 'Dy HH24:MI') || '.');
  if not exists (select 1 from public.players where game_id = p_game and not alive) then
    perform internal.resolve_finale(p_game);
  end if;
end $$;

create or replace function internal.check_survivors(p_game uuid)
returns void language plpgsql as $$
begin
  if (select count(*) from public.players where game_id = p_game and alive) <= 3 then
    perform internal.start_finale(p_game, 'Only 3 players remain!');
  end if;
end $$;

-- Process due AP drops and day rollovers for one active game.
create or replace function internal.process_game(p_game uuid)
returns void language plpgsql as $$
declare
  g public.games;
  d record;
  v_haunted uuid;
  v_count int;
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
      get diagnostics v_count = row_count;
      update public.ap_drops set processed_at = now() where id = d.id;
      perform internal.log(g.id, 'ap_drop', null, null,
        format('AP drop! %s player%s received 1 AP.', v_count, case when v_count = 1 then '' else 's' end),
        jsonb_build_object('day', d.day, 'haunted_id', v_haunted));
    end loop;

    exit when now() < internal.day_start(g, g.current_day + 1);

    -- The day is over.
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

-- Run every minute by pg_cron.
create or replace function internal.tick()
returns void language plpgsql as $$
declare r record;
begin
  for r in select id from public.games where status = 'active' loop
    perform internal.process_game(r.id);
  end loop;
  for r in select id from public.games where status = 'finale' and finale_ends_at <= now() loop
    perform internal.resolve_finale(r.id);
  end loop;
end $$;

------------------------------------------------------------------------------
-- Lobby RPCs
------------------------------------------------------------------------------

create or replace function public.create_game(p_name text, p_max_players int, p_timezone text)
returns uuid language plpgsql security definer set search_path = public as $$
declare
  v_code text;
  v_id uuid;
begin
  if auth.uid() is null then raise exception 'Not signed in'; end if;
  if p_max_players not between 4 and 20 then raise exception 'Max players must be between 4 and 20'; end if;
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
  return g.id;
end $$;

-- Leave a game that has not started. If the host leaves, the lobby is closed.
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

  -- Day 1 is today, unless today's AP window (8am-8pm) has already closed.
  v_local := now() at time zone g.timezone;
  update games
     set status = 'active', current_day = 1, started_at = now(),
         day1_date = case when v_local::time >= time '20:00' then v_local::date + 1 else v_local::date end
   where id = p_game returning * into g;
  update games set day_ends_at = internal.day_start(g, 2) where id = p_game returning * into g;

  -- Random, distinct starting squares.
  with cells as (
    select n % g.board_size as x, n / g.board_size as y, row_number() over (order by random()) as rn
    from generate_series(0, g.board_size * g.board_size - 1) n
  ), ps as (
    select id, row_number() over (order by random()) as rn from players where game_id = p_game
  )
  update players p set x = c.x, y = c.y from ps join cells c using (rn) where p.id = ps.id;

  perform internal.schedule_drops(g, 1, now());
  perform internal.log(p_game, 'start', null, null,
    format('The game has begun! Day 1 of %s%s.', g.total_days,
      case when g.day1_date > v_local::date then ' starts tomorrow' else '' end));
end $$;

------------------------------------------------------------------------------
-- Action RPCs (any time, while the game is active)
------------------------------------------------------------------------------

create or replace function internal.require_action(p_game uuid, p_cost int)
returns public.players language plpgsql as $$
declare me public.players;
begin
  perform internal.lock_game(p_game, 'active');
  me := internal.me(p_game);
  if not me.alive then raise exception 'You are dead. Dead players sit on the jury.'; end if;
  if me.ap < p_cost then raise exception 'You need % AP (you have %)', p_cost, me.ap; end if;
  return me;
end $$;

-- 1. Move to an adjacent (not diagonal), unoccupied square. 1 AP.
create or replace function public.act_move(p_game uuid, p_x int, p_y int)
returns void language plpgsql security definer set search_path = public as $$
declare me players; g games;
begin
  me := internal.require_action(p_game, 1);
  select * into g from games where id = p_game;
  if abs(p_x - me.x) + abs(p_y - me.y) <> 1 then
    raise exception 'You can only move one square up, down, left or right';
  end if;
  if p_x < 0 or p_y < 0 or p_x >= g.board_size or p_y >= g.board_size then raise exception 'That square is off the board'; end if;
  if exists (select 1 from players where game_id = p_game and x = p_x and y = p_y) then
    raise exception 'That square is occupied';
  end if;
  update players set x = p_x, y = p_y, ap = ap - 1 where id = me.id;
  perform internal.log(p_game, 'move', me.id, null, format('%s moved.', me.name),
    jsonb_build_object('from', jsonb_build_array(me.x, me.y), 'to', jsonb_build_array(p_x, p_y)));
end $$;

-- 2. Shoot someone in range. 1 AP, removes 1 heart.
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
    perform internal.log(p_game, 'shoot', me.id, t.id,
      format('%s shot %s (%s %s left).', me.name, t.name, t.hearts, case when t.hearts = 1 then 'heart' else 'hearts' end));
  else
    -- The killer takes the victim's AP.
    update players set ap = ap + t.ap where id = me.id;
    update players set ap = 0, killed_by = me.id, died_at = now() where id = t.id;
    perform internal.log(p_game, 'kill', me.id, t.id,
      format('%s killed %s%s.', me.name, t.name,
        case when t.ap > 0 then format(' and took their %s AP', t.ap) else '' end),
      jsonb_build_object('ap_taken', t.ap));
    perform internal.check_survivors(p_game);
  end if;
end $$;

-- 3. Add a heart. 3 AP, max 4 hearts.
create or replace function public.act_add_heart(p_game uuid)
returns void language plpgsql security definer set search_path = public as $$
declare me players;
begin
  me := internal.require_action(p_game, 3);
  if me.hearts >= 4 then raise exception 'You already have the maximum of 4 hearts'; end if;
  update players set ap = ap - 3, hearts = hearts + 1 where id = me.id;
  perform internal.log(p_game, 'heal', me.id, null, format('%s bought a heart.', me.name));
end $$;

-- 4. Upgrade range by 1. 3 AP.
create or replace function public.act_upgrade_range(p_game uuid)
returns void language plpgsql security definer set search_path = public as $$
declare me players; g games;
begin
  me := internal.require_action(p_game, 3);
  select * into g from games where id = p_game;
  if me.range >= g.board_size - 1 then raise exception 'Your range already covers the whole board'; end if;
  update players set ap = ap - 3, range = range + 1 where id = me.id;
  perform internal.log(p_game, 'upgrade', me.id, null, format('%s upgraded their range to %s.', me.name, me.range + 1));
end $$;

-- Gifts: send hearts or AP to anyone in range. Free (the gift itself is the cost).
-- Sending a heart to a dead player revives them with 1 heart and 0 AP.
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
    perform internal.log(p_game, 'gift_ap', me.id, t.id, format('%s sent %s %s AP.', me.name, t.name, p_amount));

  elsif p_kind = 'heart' then
    if me.hearts - p_amount < 1 then raise exception 'You must keep at least 1 heart'; end if;
    if not t.alive then
      if p_amount <> 1 then raise exception 'Reviving takes exactly 1 heart'; end if;
      update players set hearts = hearts - 1 where id = me.id;
      update players set hearts = 1, ap = 0, killed_by = null, died_at = null where id = t.id;
      perform internal.log(p_game, 'revive', me.id, t.id, format('%s revived %s!', me.name, t.name));
    else
      if t.hearts + p_amount > 4 then
        raise exception '% can only hold % more %', t.name, 4 - t.hearts, case when 4 - t.hearts = 1 then 'heart' else 'hearts' end;
      end if;
      update players set hearts = hearts - p_amount where id = me.id;
      update players set hearts = hearts + p_amount where id = t.id;
      perform internal.log(p_game, 'gift_heart', me.id, t.id,
        format('%s sent %s %s %s.', me.name, t.name, p_amount, case when p_amount = 1 then 'heart' else 'hearts' end));
    end if;
  else
    raise exception 'Gift must be heart or ap';
  end if;
end $$;

------------------------------------------------------------------------------
-- Jury and finale RPCs
------------------------------------------------------------------------------

-- Dead players vote. 'haunt' and 'bonus' are daily (while active); 'winner' is
-- in the finale. Votes can be changed until the tally.
create or replace function public.cast_vote(p_game uuid, p_kind text, p_target uuid)
returns void language plpgsql security definer set search_path = public as $$
declare g games; me players; t players; v_day int;
begin
  select * into g from games where id = p_game for update;
  if not found then raise exception 'Game not found'; end if;
  me := internal.me(p_game);
  if me.alive then raise exception 'Only dead players are on the jury'; end if;
  t := internal.other(p_game, p_target);
  if not t.alive then raise exception 'You can only vote for a living player'; end if;

  if p_kind in ('haunt', 'bonus') then
    if g.status <> 'active' then raise exception 'Daily jury votes are closed'; end if;
    v_day := g.current_day;
  elsif p_kind = 'winner' then
    if g.status <> 'finale' then raise exception 'The winner vote has not started'; end if;
    v_day := 0;
  else
    raise exception 'Unknown vote kind %', p_kind;
  end if;

  insert into jury_votes (game_id, day, kind, voter_id, target_id) values (p_game, v_day, p_kind, me.id, t.id)
  on conflict (game_id, day, kind, voter_id) do update set target_id = excluded.target_id, created_at = now();

  -- End the finale as soon as every juror has voted.
  if p_kind = 'winner' and not exists (
    select 1 from players p where p.game_id = p_game and not p.alive
      and not exists (select 1 from jury_votes v where v.game_id = p_game and v.kind = 'winner' and v.voter_id = p.id)
  ) then
    perform internal.resolve_finale(p_game);
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
end $$;

------------------------------------------------------------------------------
-- Permissions and realtime
------------------------------------------------------------------------------

revoke execute on all functions in schema internal from public;
revoke execute on all functions in schema public from public, anon;
grant execute on function
  public.is_game_member(uuid),
  public.create_game(text, int, text),
  public.join_game(text, text),
  public.leave_game(uuid),
  public.start_game(uuid),
  public.act_move(uuid, int, int),
  public.act_shoot(uuid, uuid),
  public.act_add_heart(uuid),
  public.act_upgrade_range(uuid),
  public.gift(uuid, uuid, text, int),
  public.cast_vote(uuid, text, uuid),
  public.submit_plea(uuid, text)
to authenticated;

do $$
begin
  if exists (select 1 from pg_publication where pubname = 'supabase_realtime') then
    alter publication supabase_realtime add table
      public.games, public.players, public.events, public.jury_results, public.jury_votes;
  end if;
end $$;
