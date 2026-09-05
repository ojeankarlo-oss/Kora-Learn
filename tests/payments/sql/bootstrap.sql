\set ON_ERROR_STOP on

\connect kora_qa supabase_admin
grant create on database kora_qa to postgres;
grant create on schema public to postgres;
\connect kora_qa postgres

do $$ begin create role anon nologin; exception when duplicate_object then null; end $$;
do $$ begin create role authenticated nologin; exception when duplicate_object then null; end $$;
do $$ begin create role service_role nologin; exception when duplicate_object then null; end $$;
grant anon, authenticated, service_role to postgres;

create schema if not exists storage;
create table storage.buckets (id text primary key, name text not null, public boolean not null default false);
create table storage.objects (id uuid primary key default gen_random_uuid(), bucket_id text, name text);
create or replace function storage.foldername(name text) returns text[]
language sql immutable
as $$ select string_to_array(name, '/') $$;

create schema if not exists vault;
create table vault.decrypted_secrets (name text primary key, decrypted_secret text);

create schema if not exists extensions;

grant usage on schema public, auth, storage to anon, authenticated, service_role;
alter default privileges in schema public grant select, insert, update, delete on tables to authenticated, service_role;
alter default privileges in schema public grant usage, select on sequences to authenticated, service_role;
alter default privileges in schema public grant execute on functions to authenticated, service_role;
grant select on auth.users to authenticated, service_role;
grant select, insert, update, delete on storage.buckets, storage.objects to authenticated, service_role;
