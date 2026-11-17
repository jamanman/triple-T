-- Run the game clock (AP drops, day rollover, jury tallies, finale deadline)
-- every minute with pg_cron.
create extension if not exists pg_cron;

select cron.unschedule('triple-t-tick') where exists (select 1 from cron.job where jobname = 'triple-t-tick');
select cron.schedule('triple-t-tick', '* * * * *', 'select internal.tick()');
