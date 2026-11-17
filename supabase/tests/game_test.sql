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
-- Unrestricted views for assertions (owned by postgres, so they bypass RLS).
create or replace view test.players as select * from public.players;
create or replace view test.events as select * from public.events;
grant select on test.players, test.events to authenticated;

create or replace function test.pid(n int) returns uuid language sql security definer as $$
  select id from public.players where user_id = ('00000000-0000-0000-0000-00000000000' || n)::uuid;
$$;
grant execute on all functions in schema test to authenticated;

------------------------------------------------------------ lobby
set role authenticated;
select test.as_user(1);
select set_config('t.game', public.create_game('Alice', 5, 'UTC')::text, false);
select test.fails($$select public.create_game('X', 26, 'UTC')$$, 'between 4 and 25', 'max players capped at 25');
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
select test.ok((select count(*) from players_view) = 5, 'members see all players');
select test.ok((select array_agg(color order by color) from players_view) = '{0,1,2,3,4}', 'distinct colours');
select test.fails($$select * from public.players$$, 'permission denied', 'raw players table is not readable');
select public.start_game(current_setting('t.game')::uuid);
select test.ok((select count(distinct (x, y)) from test.players where x between 0 and 14 and y between 0 and 14) = 5, 'random distinct start squares');
select test.ok((select bool_and(hearts = 3 and ap = 0 and range = 2) from test.players), 'start with 3 hearts, 0 AP, range 2');
select test.ok((select count(*) from ap_drops) = 0, 'AP drop times are hidden from players');
select test.fails($$update players set ap = 99$$, 'permission denied', 'cannot write tables directly');
select test.fails($$select internal.tick()$$, 'permission denied', 'cannot run the clock');
select test.fails(format($$select public.act_move(%L, 0, 0)$$, current_setting('t.game')), 'need 1 AP', 'actions cost AP');

------------------------------------------------------------ set up a known board
reset role;
update players set x = null, y = null;
update players set x = 0,  y = 0,  ap = 10 where id = test.pid(1); -- Alice
update players set x = 1,  y = 1,  ap = 4  where id = test.pid(2); -- Bob (2 cardinal steps)
update players set x = 2,  y = 2           where id = test.pid(3); -- Cara (diagonally 2, but 4 cardinal steps)
update players set x = 14, y = 14          where id = test.pid(4); -- Dan
update players set x = 10, y = 10          where id = test.pid(5); -- Eve
set role authenticated;
select test.as_user(1);

select test.fails(format($$select public.act_move(%L, 1, 1)$$, current_setting('t.game')), 'up, down, left or right', 'no diagonal moves');
select test.fails(format($$select public.act_move(%L, -1, 0)$$, current_setting('t.game')), 'off the board', 'stay on board');
select public.act_move(current_setting('t.game')::uuid, 1, 0);
select test.ok((select x = 1 and y = 0 and ap = 9 from test.players where id = test.pid(1)), 'move costs 1 AP');
select public.act_move(current_setting('t.game')::uuid, 0, 0);

select test.fails(format($$select public.act_shoot(%L, %L)$$, current_setting('t.game'), test.pid(3)), 'out of range', 'range is counted in cardinal steps, not diagonally');
select public.act_shoot(current_setting('t.game')::uuid, test.pid(2));
select test.ok((select hearts from test.players where id = test.pid(2)) = 2, 'shooting removes a heart');
select public.act_shoot(current_setting('t.game')::uuid, test.pid(2));
select public.act_shoot(current_setting('t.game')::uuid, test.pid(2));
select test.ok((select not alive and ap = 0 and killed_by = test.pid(1) from test.players where id = test.pid(2)), 'Bob is dead');
select test.ok((select ap from test.players where id = test.pid(1)) = 5 + 4, 'killer takes victim AP');
select test.fails(format($$select public.act_shoot(%L, %L)$$, current_setting('t.game'), test.pid(2)), 'already dead', 'cannot shoot the dead');
select test.fails(format($$select public.gift(%L, %L, 'ap', 1)$$, current_setting('t.game'), test.pid(2)), 'cannot receive AP', 'no AP to the dead');
select test.fails(format($$select public.gift(%L, %L, 'heart', 3)$$, current_setting('t.game'), test.pid(2)), 'keep at least 1', 'must keep a heart');

select public.act_add_heart(current_setting('t.game')::uuid);
select test.ok((select hearts = 4 and ap = 6 from test.players where id = test.pid(1)), 'add heart costs 3 AP');
select test.fails(format($$select public.act_add_heart(%L)$$, current_setting('t.game')), 'maximum of 4', 'can only buy up to 4 hearts');
select public.act_upgrade_range(current_setting('t.game')::uuid);
select test.ok((select range = 3 and ap = 3 from test.players where id = test.pid(1)), 'upgrade range costs 3 AP');


------------------------------------------------------------ secrecy
select test.ok((select hearts = 4 and ap = 3 and range = 3 from players_view where id = test.pid(1)), 'you see your own stats');
select test.ok((select hearts is null and ap is null and range is null from players_view where id = test.pid(3)), 'other players'' stats are hidden');
select test.ok(not exists (select 1 from information_schema.columns where table_name = 'players_view' and column_name = 'killed_by'), 'killers are not revealed');
select test.ok((select bool_and(kind in ('ap_drop', 'death', 'revive', 'move', 'shot', 'bonus', 'haunted', 'gift')) from test.events),
  'feed only has AP handouts, gifts, deaths, revives, moves and shots');
select test.ok(not exists (select 1 from test.events where kind <> 'move' and (actor_id is not null or message like '%Alice%')),
  'feed never names the shooter or killer');
select test.ok(not exists (select 1 from events where kind = 'shot'), 'shooter gets no feed entry');
select test.as_user(2);
select test.ok((select count(*) from events where kind = 'shot' and message like 'You were shot!%') = 2, 'victim is told they were shot');
select test.as_user(3);
select test.ok(not exists (select 1 from events where kind = 'shot'), 'other players don''t see shots');
select test.ok(exists (select 1 from events where kind = 'death' and message = 'Bob died.'), 'everyone sees the death');
select test.ok(exists (select 1 from events where kind = 'move' and message = 'Alice moved.'), 'everyone sees moves');
select test.as_user(1);

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
select test.ok((select ap from test.players where id = test.pid(1)) = 4, 'AP drop gives living players 1 AP');
select test.ok((select ap from test.players where id = test.pid(2)) = 0, 'dead players get no AP');
select test.ok((select count(*) from ap_drops where processed_at is null) = 0, 'drop processed once');
select internal.tick();
select test.ok((select ap from test.players where id = test.pid(1)) = 4, 'drop not repeated');

-- Day 1 ends: move day1_date back so day 1 is over.
update games set day1_date = (now() at time zone 'UTC')::date - 1 where id = current_setting('t.game')::uuid;
select internal.tick();
select test.ok((select current_day from games) = 2, 'day rolls over');
select test.ok((select day_ends_at = ((now() at time zone 'UTC')::date + 1)::timestamp at time zone 'UTC' from games), 'day_ends_at is next local midnight');
select test.ok((select haunted_id = test.pid(1) and bonus_id = test.pid(3) from jury_results where day = 1), 'jury tallied');
select test.ok((select ap from test.players where id = test.pid(3)) = 1 + 2, 'bonus gives 2 AP');
set role authenticated;
select test.as_user(1);
select test.ok(not exists (select 1 from jury_results), 'living players can''t see jury results');
select test.as_user(2);
select test.ok(exists (select 1 from jury_results), 'the jury sees its results');
select test.as_user(3);
select test.ok((select message from events where kind = 'bonus') = 'The jury awarded you 2 bonus AP.', 'bonus winner is told privately');
select test.as_user(4);
select test.ok((select message from events where kind = 'bonus') = 'Someone received 2 bonus AP from the jury.', 'others are told someone got the bonus, not who');
reset role;
select test.ok((select count(*) from ap_drops where day = 2) = 2, 'two drops scheduled for day 2');
select test.ok((select bool_and(scheduled_at >= ((now() at time zone 'UTC')::date + time '08:00') at time zone 'UTC'
                and scheduled_at < ((now() at time zone 'UTC')::date + time '20:00') at time zone 'UTC') from ap_drops where day = 2),
  'drops fall between 8am and 8pm');
update ap_drops set scheduled_at = now() - interval '1 second' where day = 2;
select internal.tick();
select test.ok((select ap from test.players where id = test.pid(1)) = 4, 'haunted player gets no AP next day');
select test.ok((select ap from test.players where id = test.pid(3)) = 3 + 2, 'others get both drops');
select test.ok((select count(*) from events where kind = 'haunted' and visible_to = array[test.pid(1)]) = 2, 'haunted player is told privately');

------------------------------------------------------------ revive, then finale
set role authenticated;
select test.as_user(1);
select public.gift(current_setting('t.game')::uuid, test.pid(2), 'heart', 1);
select test.ok((select alive and hearts = 1 and ap = 0 from test.players where id = test.pid(2)), 'heart revives with 1 heart, 0 AP');
select test.ok((select hearts from test.players where id = test.pid(1)) = 3, 'giver loses the heart');
select public.gift(current_setting('t.game')::uuid, test.pid(2), 'ap', 2);
select test.ok((select ap from test.players where id = test.pid(2)) = 2, 'AP gift');
select test.as_user(2);
select test.ok(exists (select 1 from events where kind = 'gift' and message = 'Alice sent you 2 AP.'), 'gift receiver is told who sent it');
select test.as_user(4);
select test.ok(not exists (select 1 from events where kind = 'gift'), 'nobody else hears about the gift');
select test.ok(exists (select 1 from events where kind = 'revive' and message = 'Bob was revived!' and actor_id is null), 'revives are announced anonymously');
reset role;
update players set hearts = 3 where id = test.pid(2);
set role authenticated;
select test.as_user(1);
select test.fails(format($$select public.gift(%L, %L, 'heart', 2)$$, current_setting('t.game'), test.pid(2)), 'maximum is 4', 'gifts cannot go above 4 hearts');
reset role;
update players set hearts = 1 where id = test.pid(2);
set role authenticated;
select test.as_user(1);
select public.act_shoot(current_setting('t.game')::uuid, test.pid(2));
select test.ok((select ap from test.players where id = test.pid(1)) = 1 + 2, 'kill again, AP transferred');
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
select public.cast_vote(current_setting('t.game')::uuid, 'winner', test.pid(1));
select test.ok((select status from games) = 'finale', 'a tied winner vote does not end the game');
select test.ok((select round = 1 and candidates = (select array_agg(c order by c) from unnest(array[test.pid(1), test.pid(3)]) c) from jury_runoffs),
  'tie goes to a revote between only the tied players');
select test.fails(format($$select public.cast_vote(%L, 'winner', %L)$$, current_setting('t.game'), test.pid(4)), 'only between the tied', 'revote is limited to the tied players');
select public.cast_vote(current_setting('t.game')::uuid, 'winner', test.pid(3));
select test.ok((select status from games) = 'finale', 'revote waits for all jurors');
select test.as_user(1);
select test.ok(exists (select 1 from jury_runoffs), 'survivors can see the revote');
select test.as_user(2);
select public.cast_vote(current_setting('t.game')::uuid, 'winner', test.pid(3));
select test.ok((select status = 'finished' and winner_ids = array[test.pid(3)] from games), 'the revote picks the winner');
select test.ok((select bool_and(hearts is not null and ap is not null) from players_view), 'all stats revealed when the game ends');

------------------------------------------------------------ lobby settings (second game)
set role authenticated;
select test.as_user(6);
select set_config('t.g2', public.create_game('Fay', 25, 'UTC')::text, false);
reset role;
select set_config('t.code2', (select code from games where id = current_setting('t.g2')::uuid), false);
set role authenticated;
select test.as_user(7); select public.join_game(current_setting('t.code2'), 'Gil');
select test.fails(format($$select public.update_settings(%L, 12, 6, 2, 3, '09:00', '17:30', 'UTC', 5)$$, current_setting('t.g2')),
  'Only the host', 'only the host edits settings');
select test.as_user(6);
select test.fails(format($$select public.update_settings(%L, 21, 6, 2, 3, '09:00', '17:30', 'UTC', 5)$$, current_setting('t.g2')), 'between 10 and 20', 'grid size 10-20');
select test.fails(format($$select public.update_settings(%L, 9, 6, 2, 3, '09:00', '17:30', 'UTC', 5)$$, current_setting('t.g2')), 'between 10 and 20', 'grid size at least 10');
select test.fails(format($$select public.update_settings(%L, 12, 26, 2, 3, '09:00', '17:30', 'UTC', 5)$$, current_setting('t.g2')), 'between 4 and 25', 'max players up to 25');
select test.fails(format($$select public.update_settings(%L, 12, 6, 11, 3, '09:00', '17:30', 'UTC', 5)$$, current_setting('t.g2')), 'between 1 and 10', 'max hearts up to 10');
select test.fails(format($$select public.update_settings(%L, 12, 6, 2, 0, '09:00', '17:30', 'UTC', 5)$$, current_setting('t.g2')), 'between 1 and 12', 'at least 1 drop a day');
select test.fails(format($$select public.update_settings(%L, 12, 6, 2, 3, '18:00', '09:00', 'UTC', 5)$$, current_setting('t.g2')), 'must start before', 'window must be in order');
select test.fails(format($$select public.update_settings(%L, 12, 6, 2, 3, '09:00', '17:30', 'UTC', 0)$$, current_setting('t.g2')), 'between 1 and 365', 'game length 1-365 days or no limit');
select public.update_settings(current_setting('t.g2')::uuid, 12, 6, 2, 3, '09:00', '17:30', 'UTC', null);
select test.ok((select board_size = 12 and max_players = 6 and max_hearts = 2 and ap_drops_per_day = 3 from games where id = current_setting('t.g2')::uuid), 'settings saved');
select test.as_user(8); select public.join_game(current_setting('t.code2'), 'Hal');
select test.as_user(9); select public.join_game(current_setting('t.code2'), 'Ida');
select test.as_user(6);
select public.start_game(current_setting('t.g2')::uuid);
select test.fails(format($$select public.update_settings(%L, 15, 6, 4, 2, '08:00', '20:00', 'UTC', 5)$$, current_setting('t.g2')), 'while the game is lobby', 'settings lock when the game starts');
select test.ok((select bool_and(x < 12 and y < 12) from test.players where game_id = current_setting('t.g2')::uuid), 'players placed on the 12x12 grid');
select test.ok((select bool_and(hearts = 2) from test.players where game_id = current_setting('t.g2')::uuid), 'start hearts capped by max hearts');
reset role;
select test.ok((select count(*) from ap_drops where game_id = current_setting('t.g2')::uuid and day = 1) = 3, 'drops per day follows the setting');
select test.ok((select bool_and((scheduled_at at time zone 'UTC')::time between '09:00' and '17:30') from ap_drops where game_id = current_setting('t.g2')::uuid), 'drops fall inside the chosen window');
update players set hearts = 1, ap = 6 where game_id = current_setting('t.g2')::uuid;
set role authenticated;
select test.as_user(6);
select public.act_add_heart(current_setting('t.g2')::uuid);
select test.fails(format($$select public.act_add_heart(%L)$$, current_setting('t.g2')), 'maximum of 2', 'buying respects max hearts');

-- daily ties: Hal and Ida die and split their haunt vote
reset role;
update players set hearts = 0 where id in (test.pid(8), test.pid(9));
set role authenticated;
select test.as_user(8);
select public.cast_vote(current_setting('t.g2')::uuid, 'haunt', test.pid(6));
select public.cast_vote(current_setting('t.g2')::uuid, 'bonus', test.pid(6));
select test.as_user(9);
select public.cast_vote(current_setting('t.g2')::uuid, 'haunt', test.pid(7));
reset role;
update games set day1_date = (now() at time zone 'UTC')::date - 1 where id = current_setting('t.g2')::uuid;
select internal.tick();
select test.ok((select haunted_id in (test.pid(6), test.pid(7)) from jury_results where game_id = current_setting('t.g2')::uuid and day = 1),
  'a tied haunt goes to one of the tied players at random');
select test.ok((select bonus_id = test.pid(6) from jury_results where game_id = current_setting('t.g2')::uuid and day = 1), 'a clear bonus is applied');
select test.ok(not exists (select 1 from jury_runoffs where game_id = current_setting('t.g2')::uuid), 'daily ties have no revote');

-- no day limit
update games set day1_date = (now() at time zone 'UTC')::date - 7 where id = current_setting('t.g2')::uuid;
select internal.tick();
select test.ok((select status = 'active' and current_day = 8 and total_days is null from games where id = current_setting('t.g2')::uuid), 'no day limit: the game keeps going past day 5');
set role authenticated;

-- a revote that ends in the same tie is a shared win
reset role;
select internal.start_finale(current_setting('t.g2')::uuid, 'test');
set role authenticated;
select test.as_user(8); select public.cast_vote(current_setting('t.g2')::uuid, 'winner', test.pid(6));
select test.as_user(9); select public.cast_vote(current_setting('t.g2')::uuid, 'winner', test.pid(7));
select test.ok((select status = 'finale' from games where id = current_setting('t.g2')::uuid), 'tie: revote');
select test.as_user(8); select public.cast_vote(current_setting('t.g2')::uuid, 'winner', test.pid(6));
select test.as_user(9); select public.cast_vote(current_setting('t.g2')::uuid, 'winner', test.pid(7));
select test.ok((select status = 'finished' and cardinality(winner_ids) = 2 from games where id = current_setting('t.g2')::uuid), 'same tie again: shared victory');

------------------------------------------------------------ push notifications
set role authenticated;
select test.as_user(6);
select test.ok(public.push_public_key() is null, 'no push key until the edge function creates one');
select test.fails($$select public.save_push_subscription('http://insecure.example/x', 'BCVxsr7N_eNgVRqvHtD0zTZsEc6-VV-JvLexhqUzORcxaOzi6-AYWXvTBHm4bjyPjs7Vd8pZGH6SRpkNtoIAiw4', 'BTBZMqHH6r4Tts7J_aSIgg')$$, 'Invalid', 'push endpoints must be https');
select public.save_push_subscription('https://push.example/fay', 'BCVxsr7N_eNgVRqvHtD0zTZsEc6-VV-JvLexhqUzORcxaOzi6-AYWXvTBHm4bjyPjs7Vd8pZGH6SRpkNtoIAiw4', 'BTBZMqHH6r4Tts7J_aSIgg');
select test.as_user(7); select public.save_push_subscription('https://push.example/gil', 'BCVxsr7N_eNgVRqvHtD0zTZsEc6-VV-JvLexhqUzORcxaOzi6-AYWXvTBHm4bjyPjs7Vd8pZGH6SRpkNtoIAiw4', 'BTBZMqHH6r4Tts7J_aSIgg');
select test.as_user(8); select public.save_push_subscription('https://push.example/hal', 'BCVxsr7N_eNgVRqvHtD0zTZsEc6-VV-JvLexhqUzORcxaOzi6-AYWXvTBHm4bjyPjs7Vd8pZGH6SRpkNtoIAiw4', 'BTBZMqHH6r4Tts7J_aSIgg');
select public.save_push_subscription('https://push.example/hal-old', 'BCVxsr7N_eNgVRqvHtD0zTZsEc6-VV-JvLexhqUzORcxaOzi6-AYWXvTBHm4bjyPjs7Vd8pZGH6SRpkNtoIAiw4', 'BTBZMqHH6r4Tts7J_aSIgg');
select public.delete_push_subscription('https://push.example/hal-old');
select test.as_user(9);
select public.delete_push_subscription('https://push.example/gil');  -- not Ida's: ignored
select test.fails($$select * from push_subscriptions$$, 'permission denied', 'subscriptions are not readable');
select test.fails($$select * from push_config$$, 'permission denied', 'VAPID keys are not readable');
select test.fails($$select public.push_job(1)$$, 'permission denied', 'players can''t trigger pushes');
select test.fails($$select public.push_init_keys('a', '{}', 'b')$$, 'permission denied', 'players can''t set push keys');
reset role;
select test.ok((select count(*) from push_subscriptions) = 3, 'subscriptions saved; delete only removes your own');
select public.push_init_keys('PUBKEY', '{"kty":"EC"}', 'https://site.example');
select test.ok(public.push_init_keys('OTHER', '{}', 'x') = 'PUBKEY', 'push keys are only created once');

insert into events (game_id, kind, actor_id, message) values (current_setting('t.g2')::uuid, 'move', test.pid(6), 'Fay moved.');
select set_config('t.ev', (select max(id) from events)::text, false);
select test.ok((select array_agg(s->>'endpoint' order by s->>'endpoint')
                from jsonb_array_elements(public.push_job(current_setting('t.ev')::bigint)->'subscriptions') s)
               = array['https://push.example/gil', 'https://push.example/hal'], 'move is pushed to everyone except the mover');
select test.ok(public.push_job(current_setting('t.ev')::bigint) is null, 'each event is pushed only once');

insert into events (game_id, kind, target_id, message, visible_to) values (current_setting('t.g2')::uuid, 'shot', test.pid(7), 'You were shot! 1 heart left.', array[test.pid(7)]);
select set_config('t.ev', (select max(id) from events)::text, false);
select set_config('t.job', public.push_job(current_setting('t.ev')::bigint)::text, false);
select test.ok((select jsonb_array_length(current_setting('t.job')::jsonb->'subscriptions')) = 1
                and current_setting('t.job')::jsonb->'subscriptions'->0->>'endpoint' = 'https://push.example/gil', 'private events only go to who can see them');
select test.ok((current_setting('t.job')::jsonb->>'body') = 'You were shot! 1 heart left.'
                and (current_setting('t.job')::jsonb->>'url') = '#/game/' || current_setting('t.g2')::uuid, 'push carries the feed message and a link to the game');

insert into events (game_id, kind, message, created_at) values (current_setting('t.g2')::uuid, 'ap_drop', 'AP drop!', now() - interval '1 hour');
select test.ok(public.push_job((select max(id) from events)) is null, 'old events are never pushed');

reset role;
\echo ALL TESTS PASSED
