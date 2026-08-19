-- Kora Learn — Migration 021
-- Phase 9: Pulso (check-in) e comunidade.
-- RLS usa current_usuario_id/current_tenant_id, pois usuarios.id não é auth.uid().

create table if not exists check_ins (
  id uuid primary key default gen_random_uuid(),
  usuario_id uuid not null references usuarios(id) on delete cascade,
  tenant_id uuid not null references tenants(id) on delete cascade,
  humor text check (humor is null or humor in ('muito_bom','bom','neutro','ruim','muito_ruim')),
  energia integer check (energia between 1 and 10),
  estresse integer check (estresse between 1 and 10),
  notas text,
  criado_em timestamptz not null default now()
);

create table if not exists community_posts (
  id uuid primary key default gen_random_uuid(),
  usuario_id uuid not null references usuarios(id) on delete cascade,
  tenant_id uuid not null references tenants(id) on delete cascade,
  titulo text,
  conteudo text not null,
  tipo text check (tipo is null or tipo in ('dica','pergunta','celebracao','desabafo')),
  likes integer not null default 0 check (likes >= 0),
  criado_em timestamptz not null default now(),
  atualizado_em timestamptz not null default now()
);

create table if not exists community_comments (
  id uuid primary key default gen_random_uuid(),
  post_id uuid not null references community_posts(id) on delete cascade,
  usuario_id uuid not null references usuarios(id) on delete cascade,
  conteudo text not null,
  criado_em timestamptz not null default now(),
  atualizado_em timestamptz not null default now()
);

create table if not exists community_likes (
  id uuid primary key default gen_random_uuid(),
  post_id uuid not null references community_posts(id) on delete cascade,
  usuario_id uuid not null references usuarios(id) on delete cascade,
  criado_em timestamptz not null default now(),
  constraint community_likes_usuario_post_unique unique(post_id, usuario_id)
);

create index if not exists idx_check_ins_usuario on check_ins(usuario_id, criado_em desc);
create index if not exists idx_check_ins_tenant on check_ins(tenant_id, criado_em desc);
create index if not exists idx_posts_tenant on community_posts(tenant_id, criado_em desc);
create index if not exists idx_posts_tipo on community_posts(tenant_id, tipo, criado_em desc);
create index if not exists idx_comments_post on community_comments(post_id, criado_em);
create index if not exists idx_likes_post on community_likes(post_id);

create or replace function public.atualizar_contagem_likes()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if tg_op = 'INSERT' then
    update community_posts set likes = likes + 1, atualizado_em = now() where id = new.post_id;
    return new;
  elsif tg_op = 'DELETE' then
    update community_posts set likes = greatest(likes - 1, 0), atualizado_em = now() where id = old.post_id;
    return old;
  end if;
  return null;
end;
$$;

drop trigger if exists trg_likes_increment on community_likes;
create trigger trg_likes_increment after insert or delete on community_likes
for each row execute function public.atualizar_contagem_likes();

drop trigger if exists trg_posts_atualizado_em on community_posts;
create trigger trg_posts_atualizado_em before update on community_posts
for each row execute function public.set_atualizado_em();
drop trigger if exists trg_comments_atualizado_em on community_comments;
create trigger trg_comments_atualizado_em before update on community_comments
for each row execute function public.set_atualizado_em();

alter table check_ins enable row level security;
alter table community_posts enable row level security;
alter table community_comments enable row level security;
alter table community_likes enable row level security;

drop policy if exists check_ins_select_own on check_ins;
create policy check_ins_select_own on check_ins for select to authenticated
using (usuario_id = public.current_usuario_id() and tenant_id = public.current_tenant_id());
drop policy if exists check_ins_insert_own on check_ins;
create policy check_ins_insert_own on check_ins for insert to authenticated
with check (usuario_id = public.current_usuario_id() and tenant_id = public.current_tenant_id());
drop policy if exists check_ins_update_own on check_ins;
create policy check_ins_update_own on check_ins for update to authenticated
using (usuario_id = public.current_usuario_id() and tenant_id = public.current_tenant_id())
with check (usuario_id = public.current_usuario_id() and tenant_id = public.current_tenant_id());
drop policy if exists check_ins_delete_own on check_ins;
create policy check_ins_delete_own on check_ins for delete to authenticated
using (usuario_id = public.current_usuario_id() and tenant_id = public.current_tenant_id());

drop policy if exists posts_select_tenant on community_posts;
create policy posts_select_tenant on community_posts for select to authenticated
using (tenant_id = public.current_tenant_id());
drop policy if exists posts_insert_own on community_posts;
create policy posts_insert_own on community_posts for insert to authenticated
with check (usuario_id = public.current_usuario_id() and tenant_id = public.current_tenant_id());
drop policy if exists posts_update_own on community_posts;
create policy posts_update_own on community_posts for update to authenticated
using (usuario_id = public.current_usuario_id() and tenant_id = public.current_tenant_id())
with check (usuario_id = public.current_usuario_id() and tenant_id = public.current_tenant_id());
drop policy if exists posts_delete_own on community_posts;
create policy posts_delete_own on community_posts for delete to authenticated
using (usuario_id = public.current_usuario_id() and tenant_id = public.current_tenant_id());

-- Comentários são visíveis somente quando o post pertence ao tenant atual.
drop policy if exists comments_select_tenant on community_comments;
create policy comments_select_tenant on community_comments for select to authenticated
using (exists (
  select 1 from community_posts p
  where p.id = community_comments.post_id and p.tenant_id = public.current_tenant_id()
));
drop policy if exists comments_insert_own on community_comments;
create policy comments_insert_own on community_comments for insert to authenticated
with check (
  usuario_id = public.current_usuario_id()
  and exists (select 1 from community_posts p where p.id = post_id and p.tenant_id = public.current_tenant_id())
);
drop policy if exists comments_update_own on community_comments;
create policy comments_update_own on community_comments for update to authenticated
using (usuario_id = public.current_usuario_id())
with check (usuario_id = public.current_usuario_id());
drop policy if exists comments_delete_own on community_comments;
create policy comments_delete_own on community_comments for delete to authenticated
using (usuario_id = public.current_usuario_id());

-- Likes: o usuário só pode manipular likes em posts do tenant atual.
drop policy if exists likes_select_own on community_likes;
create policy likes_select_own on community_likes for select to authenticated
using (usuario_id = public.current_usuario_id());
drop policy if exists likes_insert_own on community_likes;
create policy likes_insert_own on community_likes for insert to authenticated
with check (
  usuario_id = public.current_usuario_id()
  and exists (select 1 from community_posts p where p.id = post_id and p.tenant_id = public.current_tenant_id())
);
drop policy if exists likes_delete_own on community_likes;
create policy likes_delete_own on community_likes for delete to authenticated
using (usuario_id = public.current_usuario_id());
