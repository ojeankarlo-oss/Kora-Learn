-- SCHOOL-CORE-002: session authority. Self allowlist: nome, telefone,
-- avatar_url, pref_fonte, pref_alto_contraste. updated_at is trigger-managed.
create or replace function public.current_usuario_id() returns uuid language sql stable security definer set search_path = '' as $$
  select id from public.usuarios where auth_user_id = auth.uid() and ativo is true limit 1;
$$;
create or replace function public.current_tenant_id() returns uuid language sql stable security definer set search_path = '' as $$
  select tenant_id from public.usuarios where auth_user_id = auth.uid() and ativo is true limit 1;
$$;
create or replace function public.current_perfil() returns public.perfil_usuario language sql stable security definer set search_path = '' as $$
  select perfil from public.usuarios where auth_user_id = auth.uid() and ativo is true limit 1;
$$;
create or replace function public.is_staff() returns boolean language sql stable security definer set search_path = '' as $$
  select coalesce(public.current_perfil() in ('super_admin','gestor'), false);
$$;
create or replace function public.is_docente() returns boolean language sql stable security definer set search_path = '' as $$
  select coalesce(public.current_perfil() in ('super_admin','gestor','professor'), false);
$$;

-- Only an institutional invitation can select a pending identity in a tenant.
create table public.usuario_vinculo_convites (
  usuario_id uuid primary key references public.usuarios(id) on delete cascade,
  tenant_id uuid not null references public.tenants(id),
  token_hash text not null unique,
  expires_at timestamptz not null,
  consumed_at timestamptz
);
alter table public.usuario_vinculo_convites enable row level security;
revoke all on public.usuario_vinculo_convites from public, anon, authenticated;

create or replace function public.criar_convite_vinculo(p_usuario_id uuid)
returns text language plpgsql security definer set search_path = '' as $$
declare v_token text; v_alvo public.usuarios%rowtype;
begin
  if auth.uid() is null or not public.is_staff() then
    raise exception 'staff ativo requerido' using errcode = '42501';
  end if;
  select * into v_alvo from public.usuarios where id = p_usuario_id for update;
  if not found or v_alvo.tenant_id is distinct from public.current_tenant_id()
     or v_alvo.auth_user_id is not null or v_alvo.ativo is not true
     or v_alvo.perfil = 'super_admin' then
    raise exception 'cadastro nao elegivel' using errcode = '42501';
  end if;
  v_token := encode(extensions.gen_random_bytes(32), 'hex');
  insert into public.usuario_vinculo_convites(usuario_id, tenant_id, token_hash, expires_at)
  values (v_alvo.id, v_alvo.tenant_id, encode(extensions.digest(v_token, 'sha256'), 'hex'), now() + interval '24 hours')
  on conflict (usuario_id) do update set token_hash = excluded.token_hash,
    expires_at = excluded.expires_at, consumed_at = null;
  return v_token;
end;
$$;
revoke all on function public.criar_convite_vinculo(uuid) from public, anon, authenticated;
grant execute on function public.criar_convite_vinculo(uuid) to authenticated;

-- Disable the legacy email-only RPC signature.
create or replace function public.vincular_minha_conta() returns boolean language plpgsql
security definer set search_path = '' as $$
begin
  raise exception 'convite institucional requerido' using errcode = '42501';
end;
$$;
revoke all on function public.vincular_minha_conta() from public, anon, authenticated;

create or replace function public.vincular_minha_conta(p_convite text)
returns boolean language plpgsql security definer set search_path = '' as $$
declare v_uid uuid := auth.uid(); v_email text; v_id uuid; v_tenant uuid; v_count integer;
begin
  if v_uid is null or p_convite is null or length(p_convite) <> 64 then
    raise exception 'identidade ou convite invalido' using errcode = '42501';
  end if;
  select email into v_email from auth.users where id = v_uid and email_confirmed_at is not null;
  if v_email is null or exists(select 1 from public.usuarios where auth_user_id = v_uid) then
    raise exception 'identidade nao elegivel' using errcode = '42501';
  end if;
  select c.usuario_id, c.tenant_id into v_id, v_tenant
  from public.usuario_vinculo_convites c
  where c.token_hash = encode(extensions.digest(p_convite, 'sha256'), 'hex')
    and c.expires_at > now() and c.consumed_at is null for update;
  if v_id is null then raise exception 'convite invalido' using errcode = '42501'; end if;
  select count(*) into v_count from public.usuarios u
  where u.id = v_id and u.tenant_id = v_tenant and u.ativo is true
    and u.auth_user_id is null and lower(u.email) = lower(v_email);
  if v_count <> 1 then raise exception 'cadastro ausente ou ambiguo' using errcode = '42501'; end if;
  perform set_config('kora.identity_binding_row', v_id::text, true);
  update public.usuarios set auth_user_id = v_uid where id = v_id and tenant_id = v_tenant
    and ativo is true and auth_user_id is null;
  if not found then raise exception 'vinculo indisponivel' using errcode = '42501'; end if;
  perform set_config('kora.identity_binding_row', '', true);
  update public.usuario_vinculo_convites set consumed_at = now() where usuario_id = v_id;
  return true;
end;
$$;
revoke all on function public.vincular_minha_conta(text) from public, anon, authenticated;
grant execute on function public.vincular_minha_conta(text) to authenticated;

create or replace function public.trg_usuarios_authority_safe_self_update()
returns trigger language plpgsql security invoker set search_path = '' as $$
declare v_actor public.usuarios%rowtype; v_changed text[];
begin
  if tg_op = 'INSERT' then
    if auth.uid() is null then return new; end if;
    select * into v_actor from public.usuarios where auth_user_id = auth.uid() and ativo is true;
    if not found and current_user = 'postgres' and new.perfil = 'gestor'
       and new.auth_user_id = auth.uid() and not exists(
         select 1 from public.usuarios where auth_user_id = auth.uid()
       ) then return new; end if;
    if not found or v_actor.perfil not in ('gestor','super_admin')
       or v_actor.tenant_id is distinct from new.tenant_id
       or (new.perfil = 'super_admin' and v_actor.perfil <> 'super_admin')
       or new.auth_user_id is not null then
      raise exception 'criacao administrativa proibida' using errcode = '42501';
    end if;
    if new.unidade_id is not null and not exists(
      select 1 from public.unidades where id = new.unidade_id and tenant_id = new.tenant_id
    ) then raise exception 'unidade fora do tenant' using errcode = '42501'; end if;
    return new;
  end if;
  if new.unidade_id is not null and not exists(
    select 1 from public.unidades where id = new.unidade_id and tenant_id = new.tenant_id
  ) then raise exception 'unidade fora do tenant' using errcode = '42501'; end if;
  if auth.uid() is null then return new; end if;
  if old.auth_user_id is null and old.auth_user_id is distinct from new.auth_user_id then
    if current_user <> 'postgres' or
       current_setting('kora.identity_binding_row', true) is distinct from old.id::text then
      raise exception 'vinculo requer convite' using errcode = '42501';
    end if;
    return new;
  end if;
  if old.auth_user_id is distinct from new.auth_user_id then
    raise exception 'rebind proibido' using errcode = '42501';
  end if;
  if old.auth_user_id = auth.uid() then
    if old.ativo is not true then raise exception 'usuario inativo' using errcode = '42501'; end if;
    v_changed := array(select key from jsonb_each(to_jsonb(new))
      where value is distinct from to_jsonb(old)->key);
    if v_changed <@ array['nome','telefone','avatar_url','pref_fonte','pref_alto_contraste']::text[]
      then return new; end if;
    raise exception 'self-update fora da allowlist' using errcode = '42501';
  end if;
  select * into v_actor from public.usuarios where auth_user_id = auth.uid() and ativo is true;
  if not found or v_actor.perfil not in ('gestor','super_admin')
     or v_actor.tenant_id is distinct from old.tenant_id
     or new.tenant_id is distinct from old.tenant_id then
    raise exception 'administracao fora do tenant' using errcode = '42501';
  end if;
  if v_actor.perfil <> 'super_admin' and
     (old.perfil = 'super_admin' or new.perfil = 'super_admin') then
    raise exception 'super_admin global protegido' using errcode = '42501';
  end if;
  if old.id is distinct from new.id or old.created_at is distinct from new.created_at then
    raise exception 'campos estruturais imutaveis' using errcode = '42501';
  end if;
  return new;
end;
$$;
drop trigger if exists trg_usuarios_authority_safe_self_update on public.usuarios;
create trigger trg_usuarios_authority_safe_self_update before insert or update on public.usuarios
for each row execute function public.trg_usuarios_authority_safe_self_update();

drop policy if exists usuarios_update_self on public.usuarios;
create policy usuarios_update_self on public.usuarios for update to authenticated
  using (auth_user_id = auth.uid() and ativo is true)
  with check (auth_user_id = auth.uid() and ativo is true);
drop policy if exists usuarios_write_staff on public.usuarios;
create policy usuarios_write_staff on public.usuarios for all to authenticated
  using (tenant_id = public.current_tenant_id() and public.is_staff())
  with check (tenant_id = public.current_tenant_id() and public.is_staff());
