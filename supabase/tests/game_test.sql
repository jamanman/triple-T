-- End-to-end rules test. Run with supabase/tests/run-local.sh (plain Postgres
-- with stand-ins for Supabase's auth schema and roles).
\set ON_ERROR_STOP 1
\set QUIET 1

create schema if not exists test;
grant usage on schema test to authenticated;

create or replace function test.ok(cond boolean, label text) returns void language plpgsql as $$
begin
  if cond is not true then raise exception 'FAIL: %', label; end if;
  raise notice 'ok - %', label;
end $$;

create or replace function test.fails(stmt text, pattern text, label text) returns void language plpgsql as $$
begin
  execute stmt;
  raise exception 'FAIL: % (expected error matching "%")', label, pattern;
exception when others then
  if sqlerrm like 'FAIL:%' then raise; end if;
  if sqlerrm not ilike '%' || pattern || '%' then
    raise exception 'FAIL: % (got "%", expected "%")', label, sqlerrm, pattern;
  end if;
  raise notice 'ok - %', label;
end $$;
grant execute on all functions in schema test to authenticated;

create or replace function test.as_user(n int) returns void language sql as $$
  select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-00000000000' || n, false);
$$;
create or replace function test.pid(n int) returns uuid language sql as $$
  select id from public.players where user_id = ('00000000-0000-0000-0000-00000000000' || n)::uuid;
$$;
grant execute on all functions in schema test to authenticated;

------------------------------------------------------------ lobby
set role authenticated;
select test.as_user(1);
select set_config('t.game', public.create_game('Alice', 5, 'UTC')::text, false);
select test.fails($$select public.create_game('X', 21, 'UTC')$$, 'between 4 and 20', 'max players capped at 20');
select test.fails($$select public.create_game('X', 5, 'Mars/Base')$$, 'Unknown time zone', 'time zone validated');

reset role;
select set_config('t.code', (select code from games where id = current_setting('t.game')::uuid), false);
set role authenticated;

select test.as_user(2); select public.join_game(lower(current_setting('t.code')), 'Bob');
select test.as_user(3);
select test.fails(format($$select public.join_game(%L, 'bob')$$, current_setting('t.code')), 'already called', 'names unique');
select public.join_game(current_setting('t.code'), 'Cara');
select test.as_user(4); select public.join_game(current_setting('t.code'), 'Dan');
select test.fails(format($$select public.start_game(%L)$$, current_setting('t.game')), 'Only the host', 'only host starts');
select test.as_user(5); select public.join_game(current_setting('t.code'), 'Eve');
select test.as_user(6);
select test.fails(format($$select public.join_game(%L, 'Fay')$$, current_setting('t.code')), 'full', 'max players enforced');
select test.ok((select count(*) from games) = 0, 'non-members cannot see the game');

select test.as_user(1);
select test.ok((select count(*) from players) = 5, 'members see all players');
select test.ok((select array_agg(color order by color) from players) = '{0,1,2,3,4}', 'distinct colours');
select public.start_game(current_setting('t.game')::uuid);
select test.ok((select count(distinct (x, y)) from players where x between 0 and 14 and y between 0 and 14) = 5, 'random distinct start squares');
select test.ok((select bool_and(hearts = 3 and ap = 0 and range = 2) from players), 'start with 3 hearts, 0 AP, range 2');
select test.ok((select count(*) from ap_drops) = 0, 'AP drop times are hidden from players');
select test.fails($$update players set ap = 99$$, 'permission denied', 'cannot write tables directly');
select test.fails($$select internal.tick()$$, 'permission denied', 'cannot run the clock');
select test.fails(format($$select public.act_move(%L, 0, 0)$$, current_setting('t.game')), 'need 1 AP', 'actions cost AP');

------------------------------------------------------------ set up a known board
reset role;
update players set x = null, y = null;
update players set x = 0,  y = 0,  ap = 10 where id = test.pid(1); -- Alice
update players set x = 2,  y = 2,  ap = 4  where id = test.pid(2); -- Bob (diagonal distance 2)
update players set x = 5,  y = 5           where id = test.pid(3); -- Cara
update players set x = 14, y = 14          where id = test.pid(4); -- Dan
update players set x = 10, y = 10          where id = test.pid(5); -- Eve
set role authenticated;
select test.as_user(1);

select test.fails(format($$select public.act_move(%L, 1, 1)$$, current_setting('t.game')), 'up, down, left or right', 'no diagonal moves');
select test.fails(format($$select public.act_move(%L, -1, 0)$$, current_setting('t.game')), 'off the board', 'stay on board');
select public.act_move(current_setting('t.game')::uuid, 1, 0);
select test.ok((select x = 1 and y = 0 and ap = 9 from players where id = test.pid(1)), 'move costs 1 AP');
select public.act_move(current_setting('t.game')::uuid, 0, 0);

select test.fails(format($$select public.act_shoot(%L, %L)$$, current_setting('t.game'), test.pid(3)), 'out of range', 'range enforced');
select public.act_shoot(current_setting('t.game')::uuid, test.pid(2));
select test.ok((select hearts from players where id = test.pid(2)) = 2, 'shooting removes a heart (diagonal range)');
select public.act_shoot(current_setting('t.game')::uuid, test.pid(2));
select public.act_shoot(current_setting('t.game')::uuid, test.pid(2));
select test.ok((select not alive and ap = 0 and killed_by = test.pid(1) from players where id = test.pid(2)), 'Bob is dead');
select test.ok((select ap from players where id = test.pid(1)) = 5 + 4, 'killer takes victim AP');
select test.fails(format($$select public.act_shoot(%L, %L)$$, current_setting('t.game'), test.pid(2)), 'already dead', 'cannot shoot the dead');
select test.fails(format($$select public.gift(%L, %L, 'ap', 1)$$, current_setting('t.game'), test.pid(2)), 'cannot receive AP', 'no AP to the dead');
select test.fails(format($$select public.gift(%L, %L, 'heart', 3)$$, current_setting('t.game'), test.pid(2)), 'keep at least 1', 'must keep a heart');

select public.act_add_heart(current_setting('t.game')::uuid);
select test.ok((select hearts = 4 and ap = 6 from players where id = test.pid(1)), 'add heart costs 3 AP');
select test.fails(format($$select public.act_add_heart(%L)$$, current_setting('t.game')), 'maximum of 4', 'max 4 hearts');
select public.act_upgrade_range(current_setting('t.game')::uuid);
select test.ok((select range = 3 and ap = 3 from players where id = test.pid(1)), 'upgrade range costs 3 AP');

------------------------------------------------------------ jury
select test.as_user(2);
select test.fails(format($$select public.act_move(%L, 2, 3)$$, current_setting('t.game')), 'You are dead', 'dead cannot act');
select public.cast_vote(current_setting('t.game')::uuid, 'haunt', test.pid(1));
select public.cast_vote(current_setting('t.game')::uuid, 'bonus', test.pid(3));
select test.fails(format($$select public.cast_vote(%L, 'winner', %L)$$, current_setting('t.game'), test.pid(3)), 'not started', 'no winner vote before finale');
select test.ok((select count(*) from jury_votes) = 2, 'juror sees own votes');
select test.as_user(1);
select test.fails(format($$select public.cast_vote(%L, 'haunt', %L)$$, current_setting('t.game'), test.pid(3)), 'Only dead', 'living cannot vote');
select test.ok((select count(*) from jury_votes) = 0, 'votes are secret');

------------------------------------------------------------ clock: AP drops and day rollover
reset role;
delete from ap_drops;
insert into ap_drops (game_id, day, scheduled_at) values (current_setting('t.game')::uuid, 1, now() - interval '1 minute');
select internal.tick();
select test.ok((select ap from players where id = test.pid(1)) = 4, 'AP drop gives living players 1 AP');
select test.ok((select ap from players where id = test.pid(2)) = 0, 'dead players get no AP');
select test.ok((select count(*) from ap_drops where processed_at is null) = 0, 'drop processed once');
select internal.tick();
select test.ok((select ap from players where id = test.pid(1)) = 4, 'drop not repeated');

-- Day 1 ends: move day1_date back so day 1 is over.
update games set day1_date = (now() at time zone 'UTC')::date - 1 where id = current_setting('t.game')::uuid;
select internal.tick();
select test.ok((select current_day from games) = 2, 'day rolls over');
select test.ok((select day_ends_at = ((now() at time zone 'UTC')::date + 1)::timestamp at time zone 'UTC' from games), 'day_ends_at is next local midnight');
select test.ok((select haunted_id = test.pid(1) and bonus_id = test.pid(3) from jury_results where day = 1), 'jury tallied');
select test.ok((select ap from players where id = test.pid(3)) = 1 + 2, 'bonus gives 2 AP');
select test.ok((select count(*) from ap_drops where day = 2) = 2, 'two drops scheduled for day 2');
select test.ok((select bool_and(scheduled_at >= ((now() at time zone 'UTC')::date + time '08:00') at time zone 'UTC'
                and scheduled_at < ((now() at time zone 'UTC')::date + time '20:00') at time zone 'UTC') from ap_drops where day = 2),
  'drops fall between 8am and 8pm');
update ap_drops set scheduled_at = now() - interval '1 second' where day = 2;
select internal.tick();
select test.ok((select ap from players where id = test.pid(1)) = 4, 'haunted player gets no AP next day');
select test.ok((select ap from players where id = test.pid(3)) = 3 + 2, 'others get both drops');

------------------------------------------------------------ revive, then finale
set role authenticated;
select test.as_user(1);
select public.gift(current_setting('t.game')::uuid, test.pid(2), 'heart', 1);
select test.ok((select alive and hearts = 1 and ap = 0 from players where id = test.pid(2)), 'heart revives with 1 heart, 0 AP');
select test.ok((select hearts from players where id = test.pid(1)) = 3, 'giver loses the heart');
select public.gift(current_setting('t.game')::uuid, test.pid(2), 'ap', 2);
select test.ok((select ap from players where id = test.pid(2)) = 2, 'AP gift');
select public.act_shoot(current_setting('t.game')::uuid, test.pid(2));
select test.ok((select ap from players where id = test.pid(1)) = 1 + 2, 'kill again, AP transferred');
select test.ok((select status from games) = 'active', 'still 4 alive: no finale');

reset role;
update players set x = 0, y = 1 where id = test.pid(5);  -- Eve next to Alice
set role authenticated;
select test.as_user(5);
select test.fails(format($$select public.act_move(%L, 0, 0)$$, current_setting('t.game')), 'occupied', 'cannot move onto a player');
select test.as_user(1);
select public.act_shoot(current_setting('t.game')::uuid, test.pid(5));
select public.act_shoot(current_setting('t.game')::uuid, test.pid(5));
select public.act_shoot(current_setting('t.game')::uuid, test.pid(5));
select test.ok((select status from games) = 'finale', '3 players left triggers the finale');
select test.fails(format($$select public.act_move(%L, 1, 0)$$, current_setting('t.game')), 'while the game is active', 'actions frozen in finale');
select public.submit_plea(current_setting('t.game')::uuid, 'I was merciful to Bob.');
select test.as_user(2);
select test.fails(format($$select public.submit_plea(%L, 'x')$$, current_setting('t.game')), 'Only survivors', 'jurors do not plead');
select public.cast_vote(current_setting('t.game')::uuid, 'winner', test.pid(3));
select test.ok((select status from games) = 'finale', 'waits for all jurors');
select test.as_user(5);
select public.cast_vote(current_setting('t.game')::uuid, 'winner', test.pid(3));
select test.ok((select status = 'finished' and winner_ids = array[test.pid(3)] from games), 'jury picks the winner');
select test.ok((select message from events order by id desc limit 1) = 'Game over! Cara wins.', 'winner announced');

reset role;
\echo ALL TESTS PASSED
