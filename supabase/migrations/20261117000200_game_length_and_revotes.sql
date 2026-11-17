-- 1. Adjustable game length: total_days 1-365, or NULL for no limit (the game
--    then ends only when 3 players remain).
-- 2. Jury ties go to a revote between only the tied players.
--    Daily haunt/bonus: one revote, open until the next morning's AP window
--    opens (at least 1 hour). Still tied => nobody is haunted / awarded.
--    Final winner: revotes repeat while they narrow the field; a revote that
--    ends in the same tie is a shared victory.

------------------------------------------------------------------------------
-- Game length
------------------------------------------------------------------------------

alter table public.games alter column total_days drop not null;
alter table public.games drop constraint if exists games_total_days_check;
alter table public.games add constraint games_total_days_check check (total_days is null or total_days between 1 and 365);

drop function if exists public.update_settings(uuid, int, int, int, int, time, time, text);
create or replace function public.update_settings(
  p_game uuid,
  p_board_size int,
  p_max_players int,
  p_max_hearts int,
  p_ap_drops_per_day int,
  p_ap_window_start time,
  p_ap_window_end time,
  p_timezone text,
  p_total_days int          -- null = no limit
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
  if p_total_days is not null and p_total_days not between 1 and 365 then
    raise exception 'Game length must be between 1 and 365 days, or no limit';
  end if;
  update games set
    board_size = p_board_size, max_players = p_max_players, max_hearts = p_max_hearts,
    ap_drops_per_day = p_ap_drops_per_day, ap_window_start = p_ap_window_start, ap_window_end = p_ap_window_end,
    timezone = p_timezone, total_days = p_total_days, updated_at = now()
  where id = p_game;
end $$;

------------------------------------------------------------------------------
-- Revotes
------------------------------------------------------------------------------

alter table public.jury_votes add column if not exists round int not null default 0;
alter table public.jury_votes drop constraint if exists jury_votes_pkey;
alter table public.jury_votes add primary key (game_id, day, kind, round, voter_id);

-- The revote currently open for a vote (at most one per game/day/kind).
-- Finale revotes use day 0, kind 'winner'.
create table if not exists public.jury_runoffs (
  game_id    uuid not null references public.games (id) on delete cascade,
  day        int  not null,
  kind       text not null check (kind in ('haunt', 'bonus', 'winner')),
  round      int  not null,
  candidates uuid[] not null,
  closes_at  timestamptz not null,
  primary key (game_id, day, kind)
);
alter table public.jury_runoffs enable row level security;
-- Everyone sees the final revote (survivors need to know); daily revotes are for the jury.
drop policy if exists runoffs_read on public.jury_runoffs;
create policy runoffs_read on public.jury_runoffs for select to authenticated
  using (public.is_game_member(game_id) and (kind = 'winner' or public.am_juror(game_id)));
revoke insert, update, delete, truncate on public.jury_runoffs from anon, authenticated;

do $$
begin
  if exists (select 1 from pg_publication where pubname = 'supabase_realtime')
     and not exists (select 1 from pg_publication_tables
                     where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'jury_runoffs') then
    alter publication supabase_realtime add table public.jury_runoffs;
  end if;
end $$;

-- All targets sharing the most votes (sorted), counting only votes from players
-- who are still dead, for living targets in the candidate list. NULL if no votes.
create or replace function internal.top_votes(p_game uuid, p_day int, p_kind text, p_round int, p_candidates uuid[])
returns uuid[] language sql as $$
  with counts as (
    select v.target_id, count(*) as n
    from public.jury_votes v
    join public.players voter on voter.id = v.voter_id and not voter.alive
    join public.players target on target.id = v.target_id and target.alive
    where v.game_id = p_game and v.day = p_day and v.kind = p_kind and v.round = p_round
      and (p_candidates is null or v.target_id = any (p_candidates))
    group by v.target_id
  )
  select array_agg(target_id order by target_id) from counts where n = (select max(n) from counts);
$$;
drop function if exists internal.top_vote(uuid, int, text);

-- Apply a decided daily vote.
create or replace function internal.apply_daily(p_game uuid, p_day int, p_kind text, p_target uuid)
returns void language plpgsql as $$
declare v_others uuid[];
begin
  if p_kind = 'haunt' then
    update public.jury_results set haunted_id = p_target where game_id = p_game and day = p_day;
  else
    update public.jury_results set bonus_id = p_target where game_id = p_game and day = p_day;
    update public.players set ap = ap + 2 where id = p_target;
    perform internal.log(p_game, 'bonus', null, p_target, 'The jury awarded you 2 bonus AP.', '{}', array[p_target]);
    select array_agg(id) into v_others from public.players where game_id = p_game and id <> p_target;
    perform internal.log(p_game, 'bonus', null, null, 'Someone received 2 bonus AP from the jury.', '{}', v_others);
  end if;
end $$;

create or replace function internal.tally_day(g public.games, p_day int)
returns void language plpgsql as $$
declare
  k text;
  v uuid[];
  v_closes timestamptz;
begin
  insert into public.jury_results (game_id, day) values (g.id, p_day) on conflict do nothing;
  -- A revote closes when the next day's AP window opens, so a haunt is settled before any drop.
  v_closes := greatest(((g.day1_date + p_day) + g.ap_window_start)::timestamp at time zone g.timezone,
                       now() + interval '1 hour');
  foreach k in array array['haunt', 'bonus'] loop
    v := internal.top_votes(g.id, p_day, k, 0, null);
    if cardinality(v) = 1 then
      perform internal.apply_daily(g.id, p_day, k, v[1]);
    elsif cardinality(v) > 1 then
      insert into public.jury_runoffs (game_id, day, kind, round, candidates, closes_at)
      values (g.id, p_day, k, 1, v, v_closes)
      on conflict (game_id, day, kind) do update set round = 1, candidates = excluded.candidates, closes_at = excluded.closes_at;
    end if;
  end loop;
end $$;

create or replace function internal.resolve_daily_runoff(p_game uuid, p_day int, p_kind text)
returns void language plpgsql as $$
declare r public.jury_runoffs; v uuid[];
begin
  delete from public.jury_runoffs where game_id = p_game and day = p_day and kind = p_kind returning * into r;
  if not found then return; end if;
  v := internal.top_votes(p_game, r.day, r.kind, r.round, r.candidates);
  if cardinality(v) = 1 then
    perform internal.apply_daily(p_game, r.day, r.kind, v[1]);
  end if;   -- still tied, or nobody voted: nobody is haunted / awarded
end $$;

create or replace function internal.all_jurors_voted(p_game uuid, p_day int, p_kind text, p_round int)
returns boolean language sql as $$
  select not exists (
    select 1 from public.players p
    where p.game_id = p_game and not p.alive
      and not exists (select 1 from public.jury_votes v
                      where v.game_id = p_game and v.day = p_day and v.kind = p_kind
                        and v.round = p_round and v.voter_id = p.id)
  );
$$;

create or replace function internal.resolve_finale(p_game uuid)
returns void language plpgsql as $$
declare
  g public.games;
  r public.jury_runoffs;
  v_round int := 0;
  v uuid[];
  v_winners uuid[];
begin
  select * into g from public.games where id = p_game for update;
  if g.status <> 'finale' then return; end if;
  select * into r from public.jury_runoffs where game_id = p_game and day = 0 and kind = 'winner';
  if found then v_round := r.round; end if;

  v := internal.top_votes(p_game, 0, 'winner', v_round, r.candidates);

  if cardinality(v) = 1 then
    v_winners := v;
  elsif cardinality(v) > 1 and (v_round = 0 or cardinality(v) < cardinality(r.candidates)) then
    -- Tie that narrowed the field: revote between only the tied players.
    update public.games set finale_ends_at = now() + make_interval(hours => finale_hours), updated_at = now()
     where id = p_game returning * into g;
    insert into public.jury_runoffs (game_id, day, kind, round, candidates, closes_at)
    values (p_game, 0, 'winner', v_round + 1, v, g.finale_ends_at)
    on conflict (game_id, day, kind) do update
      set round = excluded.round, candidates = excluded.candidates, closes_at = excluded.closes_at;
    return;
  elsif v_round > 0 then
    -- The revote ended in the same tie (or nobody voted): shared victory.
    v_winners := coalesce(v, r.candidates);
  else
    -- No jury votes at all: every survivor shares the win.
    select array_agg(id) into v_winners from public.players where game_id = p_game and alive;
  end if;

  delete from public.jury_runoffs where game_id = p_game;
  update public.games set status = 'finished', winner_ids = v_winners, updated_at = now() where id = p_game;
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
  delete from public.jury_runoffs where game_id = p_game;   -- open daily revotes no longer matter
  if not exists (select 1 from public.players where game_id = p_game and not alive) then
    perform internal.resolve_finale(p_game);
  end if;
end $$;

create or replace function internal.process_game(p_game uuid)
returns void language plpgsql as $$
declare
  g public.games;
  d record;
  r record;
  v_haunted uuid;
  v_others uuid[];
begin
  select * into g from public.games where id = p_game and status = 'active' for update skip locked;
  if not found then return; end if;

  loop
    for r in
      select day, kind from public.jury_runoffs
      where game_id = g.id and kind <> 'winner' and closes_at <= now()
    loop
      perform internal.resolve_daily_runoff(g.id, r.day, r.kind);
    end loop;

    for d in
      select * from public.ap_drops
      where game_id = g.id and processed_at is null and scheduled_at <= now()
      order by scheduled_at
    loop
      select jr.haunted_id into v_haunted
        from public.jury_results jr join public.players p on p.id = jr.haunted_id and p.alive
       where jr.game_id = g.id and jr.day = d.day - 1;
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
    if g.total_days is not null and g.current_day >= g.total_days then
      perform internal.start_finale(g.id, format('Day %s is over.', g.total_days));
      return;
    end if;
    update public.games
       set current_day = current_day + 1, day_ends_at = internal.day_start(g, g.current_day + 2), updated_at = now()
     where id = g.id returning * into g;
    perform internal.schedule_drops(g, g.current_day);
  end loop;
end $$;

-- Votes. During the finale, votes go to the current revote round automatically.
create or replace function public.cast_vote(p_game uuid, p_kind text, p_target uuid)
returns void language plpgsql security definer set search_path = public as $$
declare g games; me players; t players; v_day int; v_round int := 0; r jury_runoffs;
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
    select * into r from jury_runoffs where game_id = p_game and day = 0 and kind = 'winner';
    if found then
      v_round := r.round;
      if not (t.id = any (r.candidates)) then raise exception 'This revote is only between the tied players'; end if;
    end if;
  else
    raise exception 'Unknown vote kind %', p_kind;
  end if;

  insert into jury_votes (game_id, day, kind, round, voter_id, target_id)
  values (p_game, v_day, p_kind, v_round, me.id, t.id)
  on conflict (game_id, day, kind, round, voter_id) do update set target_id = excluded.target_id, created_at = now();

  if p_kind = 'winner' and internal.all_jurors_voted(p_game, 0, 'winner', v_round) then
    perform internal.resolve_finale(p_game);
  end if;
end $$;

-- Vote in an open daily revote (haunt or bonus) between the tied players.
create or replace function public.cast_revote(p_game uuid, p_kind text, p_target uuid)
returns void language plpgsql security definer set search_path = public as $$
declare g games; me players; t players; r jury_runoffs;
begin
  g := internal.lock_game(p_game, 'active');
  me := internal.me(p_game);
  if me.alive then raise exception 'Only dead players are on the jury'; end if;
  select * into r from jury_runoffs where game_id = p_game and kind = p_kind and kind <> 'winner' and closes_at > now();
  if not found then raise exception 'There is no % revote open', p_kind; end if;
  t := internal.other(p_game, p_target);
  if not (t.id = any (r.candidates)) then raise exception 'This revote is only between the tied players'; end if;
  if not t.alive then raise exception 'You can only vote for a living player'; end if;

  insert into jury_votes (game_id, day, kind, round, voter_id, target_id)
  values (p_game, r.day, p_kind, r.round, me.id, t.id)
  on conflict (game_id, day, kind, round, voter_id) do update set target_id = excluded.target_id, created_at = now();

  if internal.all_jurors_voted(p_game, r.day, p_kind, r.round) then
    perform internal.resolve_daily_runoff(p_game, r.day, p_kind);
  end if;
end $$;

revoke execute on all functions in schema internal from public;
revoke execute on function public.update_settings(uuid, int, int, int, int, time, time, text, int) from public, anon;
grant execute on function public.update_settings(uuid, int, int, int, int, time, time, text, int) to authenticated;
revoke execute on function public.cast_revote(uuid, text, uuid) from public, anon;
grant execute on function public.cast_revote(uuid, text, uuid) to authenticated;
