\set ON_ERROR_STOP on

\connect kora_qa supabase_admin
grant create on database kora_qa to postgres;
grant create on schema public to postgres;
set role supabase_storage_admin;
create table storage.buckets (id text primary key, name text not null, public boolean not null default false);
create table storage.objects (id uuid primary key default gen_random_uuid(), bucket_id text, name text);
create or replace function storage.foldername(name text) returns text[]
language sql immutable
as $$ select string_to_array(name, '/') $$;
grant select, insert, update, delete on storage.buckets, storage.objects to authenticated, service_role;
reset role;
\connect kora_qa postgres
