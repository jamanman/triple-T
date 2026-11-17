-- Push notifications.
--
-- Every activity-feed event is pushed to the players who can see it (except
-- the player who did it). Flow:
--   events INSERT -> Database Webhook -> Edge Function `send-push`
--   -> push_job(event id) returns the message, VAPID keys and subscriptions
--   -> the function encrypts and sends each push.
-- push_job only hands out each event once, and only for recent events, so the
-- function can't be used to resend or invent notifications.

create table if not exists public.push_subscriptions (
  endpoint   text primary key,
  user_id    uuid not null,
  p256dh     text not null,
  auth       text not null,
  created_at timestamptz not null default now()
);
create index if not exists push_subscriptions_user_idx on public.push_subscriptions (user_id);
alter table public.push_subscriptions enable row level security;
revoke all on public.push_subscriptions from anon, authenticated;

-- The VAPID key pair, generated once by the edge function. Not readable by clients.
create table if not exists public.push_config (
  id          int primary key default 1 check (id = 1),
  public_key  text not null,
  private_jwk jsonb not null,
  subject     text not null,
  created_at  timestamptz not null default now()
);
alter table public.push_config enable row level security;
revoke all on public.push_config from anon, authenticated;

alter table public.events add column if not exists pushed_at timestamptz;

------------------------------------------------------------------------------
-- Client RPCs
------------------------------------------------------------------------------

create or replace function public.push_public_key()
returns text language sql stable security definer set search_path = public as $$
  select public_key from push_config where id = 1;
$$;

create or replace function public.save_push_subscription(p_endpoint text, p_p256dh text, p_auth text)
returns void language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'Not signed in'; end if;
  if p_endpoint !~ '^https://' or char_length(p_endpoint) > 2000
     or coalesce(char_length(p_p256dh), 0) not between 20 and 200
     or coalesce(char_length(p_auth), 0) not between 10 and 100 then
    raise exception 'Invalid push subscription';
  end if;
  insert into push_subscriptions (endpoint, user_id, p256dh, auth)
  values (p_endpoint, auth.uid(), p_p256dh, p_auth)
  on conflict (endpoint) do update
    set user_id = excluded.user_id, p256dh = excluded.p256dh, auth = excluded.auth, created_at = now();
end $$;

create or replace function public.delete_push_subscription(p_endpoint text)
returns void language sql security definer set search_path = public as $$
  delete from push_subscriptions where endpoint = p_endpoint and user_id = auth.uid();
$$;

------------------------------------------------------------------------------
-- Edge function RPCs (service role only)
------------------------------------------------------------------------------

create or replace function public.push_init_keys(p_public_key text, p_private_jwk jsonb, p_subject text)
returns text language plpgsql security definer set search_path = public as $$
begin
  insert into push_config (id, public_key, private_jwk, subject)
  values (1, p_public_key, p_private_jwk, p_subject)
  on conflict (id) do nothing;
  return (select public_key from push_config where id = 1);
end $$;

create or replace function public.push_job(p_event_id bigint)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  e events;
  c push_config;
  v_code text;
begin
  update events set pushed_at = now()
   where id = p_event_id and pushed_at is null and created_at > now() - interval '10 minutes'
  returning * into e;
  if not found then return null; end if;
  select * into c from push_config where id = 1;
  if not found then return null; end if;
  select code into v_code from games where id = e.game_id;

  return jsonb_build_object(
    'title', 'Triple-T · ' || v_code,
    'body', e.message,
    'url', '#/game/' || e.game_id,
    'vapid', jsonb_build_object('public_key', c.public_key, 'private_jwk', c.private_jwk, 'subject', c.subject),
    'subscriptions', coalesce((
      select jsonb_agg(jsonb_build_object('endpoint', s.endpoint, 'p256dh', s.p256dh, 'auth', s.auth))
      from push_subscriptions s
      join players p on p.user_id = s.user_id
      where p.game_id = e.game_id
        and (e.visible_to is null or p.id = any (e.visible_to))
        and p.id is distinct from e.actor_id          -- don't notify players about their own move
    ), '[]'::jsonb)
  );
end $$;

create or replace function public.push_remove_subscriptions(p_endpoints text[])
returns void language sql security definer set search_path = public as $$
  delete from push_subscriptions where endpoint = any (p_endpoints);
$$;

------------------------------------------------------------------------------
-- Permissions
------------------------------------------------------------------------------

revoke execute on function public.push_public_key() from public;
grant execute on function public.push_public_key() to anon, authenticated;
revoke execute on function public.save_push_subscription(text, text, text), public.delete_push_subscription(text) from public, anon;
grant execute on function public.save_push_subscription(text, text, text), public.delete_push_subscription(text) to authenticated;
revoke execute on function
  public.push_init_keys(text, jsonb, text), public.push_job(bigint), public.push_remove_subscriptions(text[])
  from public, anon, authenticated;
do $$
begin
  if exists (select 1 from pg_roles where rolname = 'service_role') then
    grant execute on function
      public.push_init_keys(text, jsonb, text), public.push_job(bigint), public.push_remove_subscriptions(text[])
      to service_role;
  end if;
end $$;
