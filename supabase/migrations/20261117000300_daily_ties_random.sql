-- Daily haunt / +2 AP votes: a tie is settled by picking one of the tied
-- players at random, straight away (no revote). The final winner vote keeps
-- its revotes.

create or replace function internal.tally_day(g public.games, p_day int)
returns void language plpgsql as $$
declare
  k text;
  v uuid[];
begin
  insert into public.jury_results (game_id, day) values (g.id, p_day) on conflict do nothing;
  foreach k in array array['haunt', 'bonus'] loop
    v := internal.top_votes(g.id, p_day, k, 0, null);
    if cardinality(v) >= 1 then
      perform internal.apply_daily(g.id, p_day, k, v[1 + floor(random() * cardinality(v))::int]);
    end if;
  end loop;
end $$;

-- Settle any daily revotes still open from the previous version the same way.
do $$
declare r record;
begin
  for r in delete from public.jury_runoffs where kind <> 'winner' returning * loop
    perform internal.apply_daily(r.game_id, r.day, r.kind,
      r.candidates[1 + floor(random() * cardinality(r.candidates))::int]);
  end loop;
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

drop function if exists public.cast_revote(uuid, text, uuid);
drop function if exists internal.resolve_daily_runoff(uuid, int, text);

-- Only the final vote has revotes now.
alter table public.jury_runoffs drop constraint if exists jury_runoffs_kind_check;
alter table public.jury_runoffs add constraint jury_runoffs_kind_check check (kind = 'winner');

revoke execute on all functions in schema internal from public;
