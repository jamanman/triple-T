drop schema if exists test, internal cascade;
drop view if exists public.players_view;
drop table if exists public.push_subscriptions, public.push_config, public.jury_runoffs, public.player_pings, public.jury_results, public.jury_votes, public.ap_drops, public.events, public.players, public.games cascade;
drop function if exists public.is_game_member, public.create_game, public.join_game, public.leave_game, public.start_game,
  public.act_move, public.act_shoot, public.act_add_heart, public.act_upgrade_range, public.gift, public.cast_vote, public.submit_plea, public.my_player_id, public.am_juror, public.update_settings, public.cast_revote, public.push_public_key, public.save_push_subscription, public.delete_push_subscription, public.push_init_keys, public.push_job, public.push_remove_subscriptions;
