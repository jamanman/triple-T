-- 1. Gift receivers are told who sent the gift (still private to the receiver).
-- 2. The jury's +2 AP bonus: the winner is told privately; everyone else is
--    told that someone received it, without saying who.

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
    perform internal.log(p_game, 'gift', me.id, t.id,
      format('%s sent you %s AP.', me.name, p_amount), '{}', array[t.id]);

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
      perform internal.log(p_game, 'gift', me.id, t.id,
        format('%s sent you %s %s.', me.name, p_amount, case when p_amount = 1 then 'heart' else 'hearts' end),
        '{}', array[t.id]);
    end if;
  else
    raise exception 'Gift must be heart or ap';
  end if;
end $$;

create or replace function internal.tally_day(g public.games, p_day int)
returns void language plpgsql as $$
declare
  v_haunt uuid := internal.top_vote(g.id, p_day, 'haunt');
  v_bonus uuid := internal.top_vote(g.id, p_day, 'bonus');
  v_others uuid[];
begin
  insert into public.jury_results (game_id, day, haunted_id, bonus_id) values (g.id, p_day, v_haunt, v_bonus)
  on conflict do nothing;
  if v_bonus is not null then
    update public.players set ap = ap + 2 where id = v_bonus;
    perform internal.log(g.id, 'bonus', null, v_bonus, 'The jury awarded you 2 bonus AP.', '{}', array[v_bonus]);
    select array_agg(id) into v_others from public.players where game_id = g.id and id <> v_bonus;
    perform internal.log(g.id, 'bonus', null, null, 'Someone received 2 bonus AP from the jury.', '{}', v_others);
  end if;
end $$;

revoke execute on all functions in schema internal from public;
