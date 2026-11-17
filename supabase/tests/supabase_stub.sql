create role anon nologin; create role authenticated nologin;
create schema auth;
create function auth.uid() returns uuid language sql stable as $$ select nullif(current_setting('request.jwt.claim.sub', true),'')::uuid $$;
grant usage on schema auth, public to anon, authenticated; grant execute on function auth.uid() to anon, authenticated;
grant select on all tables in schema public to anon, authenticated;
alter default privileges in schema public grant all on tables to anon, authenticated;
