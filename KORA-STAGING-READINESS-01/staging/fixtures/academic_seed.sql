\set ON_ERROR_STOP on
-- ============================================================================
-- KORA-STAGING-READINESS-01 — seed acadêmico SINTÉTICO e idempotente.
-- Pré-requisitos: migrations 001-040 aplicadas; usuários auth criados por
-- scripts/seed-auth.mjs (e-mails @kora-staging.invalid).
-- Executado como role "postgres" do stack DESCARTÁVEL (auth.uid() = null).
-- Atalho de fixture: usuarios.auth_user_id é vinculado diretamente pelo owner.
-- O fluxo real de convite (criar_convite_vinculo/vincular_minha_conta) é
-- exercitado separadamente em tests/01-auth-session.test.mjs com "pendenteA".
-- NUNCA executar em banco com dados não sintéticos: o bloco abaixo aborta.
-- ============================================================================

begin;

-- Fail-closed: o alvo precisa estar vazio ou conter apenas dados sintéticos.
do $$
declare v_foreign_tenants int; v_foreign_users int;
begin
  select count(*) into v_foreign_tenants from public.tenants where slug not like 'kora-stg-%';
  select count(*) into v_foreign_users from auth.users
   where email is null or email not like '%@kora-staging.invalid';
  if v_foreign_tenants > 0 or v_foreign_users > 0 then
    raise exception 'KORA-STG SEED ABORT: alvo contém dados não sintéticos (tenants=%, auth.users=%)',
      v_foreign_tenants, v_foreign_users;
  end if;
  if (select count(*) from auth.users where email like '%@kora-staging.invalid') < 10 then
    raise exception 'KORA-STG SEED ABORT: usuários auth sintéticos ausentes; rode seed-auth.mjs antes';
  end if;
end $$;

insert into public.tenants(id,nome,slug) values
 ('f1000000-0000-4000-8000-000000000001','Escola Sintética Alfa','kora-stg-escola-alfa'),
 ('f1000000-0000-4000-8000-000000000002','Escola Sintética Beta','kora-stg-escola-beta')
on conflict (id) do nothing;

insert into public.unidades(id,tenant_id,nome) values
 ('f2000000-0000-4000-8000-000000000001','f1000000-0000-4000-8000-000000000001','Unidade Alfa Centro'),
 ('f2000000-0000-4000-8000-000000000002','f1000000-0000-4000-8000-000000000002','Unidade Beta Centro')
on conflict (id) do nothing;

-- Usuários de aplicação. auth_user_id resolvido por e-mail (null para pendenteA).
insert into public.usuarios(id,auth_user_id,tenant_id,unidade_id,perfil,nome,email,ativo)
select v.id::uuid, (select u.id from auth.users u where u.email = v.email and v.bind),
       v.tenant::uuid, v.unidade::uuid, v.perfil::public.perfil_usuario, v.nome, v.email, v.ativo
from (values
 ('f3000000-0000-4000-8000-000000000001','f1000000-0000-4000-8000-000000000001','f2000000-0000-4000-8000-000000000001','gestor','Gestor A Sintético','gestor-a@kora-staging.invalid',true,true),
 ('f3000000-0000-4000-8000-000000000002','f1000000-0000-4000-8000-000000000001','f2000000-0000-4000-8000-000000000001','professor','Professor A1 Sintético','prof-a1@kora-staging.invalid',true,true),
 ('f3000000-0000-4000-8000-000000000003','f1000000-0000-4000-8000-000000000001','f2000000-0000-4000-8000-000000000001','professor','Professor A2 Sintético','prof-a2@kora-staging.invalid',true,true),
 ('f3000000-0000-4000-8000-000000000004','f1000000-0000-4000-8000-000000000001','f2000000-0000-4000-8000-000000000001','aluno','Aluno A1 Sintético','aluno-a1@kora-staging.invalid',true,true),
 ('f3000000-0000-4000-8000-000000000005','f1000000-0000-4000-8000-000000000001','f2000000-0000-4000-8000-000000000001','aluno','Aluno A1b Sintético','aluno-a1b@kora-staging.invalid',true,true),
 ('f3000000-0000-4000-8000-000000000006','f1000000-0000-4000-8000-000000000001','f2000000-0000-4000-8000-000000000001','aluno','Aluno A2 Sintético','aluno-a2@kora-staging.invalid',true,true),
 ('f3000000-0000-4000-8000-000000000007','f1000000-0000-4000-8000-000000000001','f2000000-0000-4000-8000-000000000001','aluno','Inativo A Sintético','inativo-a@kora-staging.invalid',false,true),
 ('f3000000-0000-4000-8000-000000000008','f1000000-0000-4000-8000-000000000001','f2000000-0000-4000-8000-000000000001','aluno','Pendente A Sintético','pendente-a@kora-staging.invalid',true,false),
 ('f3000000-0000-4000-8000-000000000011','f1000000-0000-4000-8000-000000000002','f2000000-0000-4000-8000-000000000002','gestor','Gestor B Sintético','gestor-b@kora-staging.invalid',true,true),
 ('f3000000-0000-4000-8000-000000000012','f1000000-0000-4000-8000-000000000002','f2000000-0000-4000-8000-000000000002','professor','Professor B1 Sintético','prof-b1@kora-staging.invalid',true,true),
 ('f3000000-0000-4000-8000-000000000014','f1000000-0000-4000-8000-000000000002','f2000000-0000-4000-8000-000000000002','aluno','Aluno B1 Sintético','aluno-b1@kora-staging.invalid',true,true)
) as v(id,tenant,unidade,perfil,nome,email,ativo,bind)
on conflict (id) do nothing;

-- Todos os vínculos esperados existem (fail-closed se seed-auth falhou parcialmente).
do $$ begin
  if (select count(*) from public.usuarios where id::text like 'f3000000-%' and auth_user_id is not null) <> 10 then
    raise exception 'KORA-STG SEED ABORT: esperados 10 usuarios vinculados a auth.users';
  end if;
end $$;

insert into public.cursos(id,tenant_id,nome) values
 ('f4000000-0000-4000-8000-000000000001','f1000000-0000-4000-8000-000000000001','Curso Sintético Alfa'),
 ('f4000000-0000-4000-8000-000000000002','f1000000-0000-4000-8000-000000000002','Curso Sintético Beta')
on conflict (id) do nothing;

insert into public.disciplinas(id,curso_id,tenant_id,nome) values
 ('f5000000-0000-4000-8000-000000000001','f4000000-0000-4000-8000-000000000001','f1000000-0000-4000-8000-000000000001','Matemática Sintética A'),
 ('f5000000-0000-4000-8000-000000000002','f4000000-0000-4000-8000-000000000002','f1000000-0000-4000-8000-000000000002','Matemática Sintética B')
on conflict (id) do nothing;

insert into public.turmas(id,tenant_id,curso_id,unidade_id,nome) values
 ('f6000000-0000-4000-8000-000000000001','f1000000-0000-4000-8000-000000000001','f4000000-0000-4000-8000-000000000001','f2000000-0000-4000-8000-000000000001','Turma A1'),
 ('f6000000-0000-4000-8000-000000000002','f1000000-0000-4000-8000-000000000001','f4000000-0000-4000-8000-000000000001','f2000000-0000-4000-8000-000000000001','Turma A2'),
 ('f6000000-0000-4000-8000-000000000003','f1000000-0000-4000-8000-000000000002','f4000000-0000-4000-8000-000000000002','f2000000-0000-4000-8000-000000000002','Turma B1')
on conflict (id) do nothing;

insert into public.matriculas(id,tenant_id,usuario_id,curso_id,turma_id,unidade_id,situacao,data_matricula) values
 ('f7000000-0000-4000-8000-000000000001','f1000000-0000-4000-8000-000000000001','f3000000-0000-4000-8000-000000000004','f4000000-0000-4000-8000-000000000001','f6000000-0000-4000-8000-000000000001','f2000000-0000-4000-8000-000000000001','ativa',current_date - 30),
 ('f7000000-0000-4000-8000-000000000002','f1000000-0000-4000-8000-000000000001','f3000000-0000-4000-8000-000000000005','f4000000-0000-4000-8000-000000000001','f6000000-0000-4000-8000-000000000001','f2000000-0000-4000-8000-000000000001','ativa',current_date - 30),
 ('f7000000-0000-4000-8000-000000000003','f1000000-0000-4000-8000-000000000001','f3000000-0000-4000-8000-000000000006','f4000000-0000-4000-8000-000000000001','f6000000-0000-4000-8000-000000000002','f2000000-0000-4000-8000-000000000001','ativa',current_date - 30),
 ('f7000000-0000-4000-8000-000000000004','f1000000-0000-4000-8000-000000000002','f3000000-0000-4000-8000-000000000014','f4000000-0000-4000-8000-000000000002','f6000000-0000-4000-8000-000000000003','f2000000-0000-4000-8000-000000000002','ativa',current_date - 30)
on conflict (id) do nothing;

insert into public.professores_turmas(id,tenant_id,usuario_id,turma_id) values
 ('f8000000-0000-4000-8000-000000000001','f1000000-0000-4000-8000-000000000001','f3000000-0000-4000-8000-000000000002','f6000000-0000-4000-8000-000000000001'),
 ('f8000000-0000-4000-8000-000000000002','f1000000-0000-4000-8000-000000000001','f3000000-0000-4000-8000-000000000003','f6000000-0000-4000-8000-000000000002'),
 ('f8000000-0000-4000-8000-000000000003','f1000000-0000-4000-8000-000000000002','f3000000-0000-4000-8000-000000000012','f6000000-0000-4000-8000-000000000003')
on conflict (id) do nothing;

insert into public.questoes(id,tenant_id,disciplina_id,enunciado,tipo,alternativas,resposta_correta,pontos,criado_por) values
 ('f9000000-0000-4000-8000-000000000001','f1000000-0000-4000-8000-000000000001','f5000000-0000-4000-8000-000000000001','Sintética A: quanto é 2+2?','objetiva',
  '[{"id":"a","texto":"3"},{"id":"b","texto":"4"},{"id":"c","texto":"5"}]'::jsonb,'b',2,'f3000000-0000-4000-8000-000000000002'),
 ('f9000000-0000-4000-8000-000000000002','f1000000-0000-4000-8000-000000000001','f5000000-0000-4000-8000-000000000001','Sintética A: explique a soma.','dissertativa',
  '[]'::jsonb,null,3,'f3000000-0000-4000-8000-000000000002'),
 ('f9000000-0000-4000-8000-000000000003','f1000000-0000-4000-8000-000000000002','f5000000-0000-4000-8000-000000000002','Sintética B: quanto é 2+2?','objetiva',
  '[{"id":"a","texto":"3"},{"id":"b","texto":"4"},{"id":"c","texto":"5"}]'::jsonb,'b',2,'f3000000-0000-4000-8000-000000000012'),
 ('f9000000-0000-4000-8000-000000000004','f1000000-0000-4000-8000-000000000002','f5000000-0000-4000-8000-000000000002','Sintética B: explique a soma.','dissertativa',
  '[]'::jsonb,null,3,'f3000000-0000-4000-8000-000000000012')
on conflict (id) do nothing;

-- Avaliações publicadas, sem embaralhamento (resultado determinístico), 1 tentativa.
insert into public.avaliacoes(id,tenant_id,curso_id,disciplina_id,turma_id,titulo,situacao,tentativas_permitidas,nota_minima,embaralhar_questoes,embaralhar_alternativas,criado_por) values
 ('fa000000-0000-4000-8000-000000000001','f1000000-0000-4000-8000-000000000001','f4000000-0000-4000-8000-000000000001','f5000000-0000-4000-8000-000000000001','f6000000-0000-4000-8000-000000000001','STG A1 fluxo','publicada',1,60,false,false,'f3000000-0000-4000-8000-000000000002'),
 ('fa000000-0000-4000-8000-000000000002','f1000000-0000-4000-8000-000000000001','f4000000-0000-4000-8000-000000000001','f5000000-0000-4000-8000-000000000001','f6000000-0000-4000-8000-000000000002','STG A2 fluxo','publicada',1,60,false,false,'f3000000-0000-4000-8000-000000000003'),
 ('fa000000-0000-4000-8000-000000000003','f1000000-0000-4000-8000-000000000002','f4000000-0000-4000-8000-000000000002','f5000000-0000-4000-8000-000000000002','f6000000-0000-4000-8000-000000000003','STG B1 fluxo','publicada',1,60,false,false,'f3000000-0000-4000-8000-000000000012'),
 ('fa000000-0000-4000-8000-000000000004','f1000000-0000-4000-8000-000000000001','f4000000-0000-4000-8000-000000000001','f5000000-0000-4000-8000-000000000001','f6000000-0000-4000-8000-000000000001','STG A1 concorrência envio','publicada',1,60,false,false,'f3000000-0000-4000-8000-000000000002'),
 ('fa000000-0000-4000-8000-000000000005','f1000000-0000-4000-8000-000000000001','f4000000-0000-4000-8000-000000000001','f5000000-0000-4000-8000-000000000001','f6000000-0000-4000-8000-000000000001','STG A1 sigilo e turma','publicada',1,60,false,false,'f3000000-0000-4000-8000-000000000002'),
 ('fa000000-0000-4000-8000-000000000006','f1000000-0000-4000-8000-000000000001','f4000000-0000-4000-8000-000000000001','f5000000-0000-4000-8000-000000000001','f6000000-0000-4000-8000-000000000001','STG A1 concorrência início','publicada',1,60,false,false,'f3000000-0000-4000-8000-000000000002')
on conflict (id) do nothing;

-- Cada avaliação: objetiva (2 pts, ordem 1) + dissertativa (3 pts, ordem 2) => nota máxima 5.
insert into public.avaliacao_questoes(avaliacao_id,questao_id,ordem)
select a.id, q.id, q.ordem from (values
 ('fa000000-0000-4000-8000-000000000001'::uuid,'A'),('fa000000-0000-4000-8000-000000000002'::uuid,'A'),
 ('fa000000-0000-4000-8000-000000000003'::uuid,'B'),('fa000000-0000-4000-8000-000000000004'::uuid,'A'),
 ('fa000000-0000-4000-8000-000000000005'::uuid,'A'),('fa000000-0000-4000-8000-000000000006'::uuid,'A')
) as a(id,t)
join (values
 ('f9000000-0000-4000-8000-000000000001'::uuid,'A',1),('f9000000-0000-4000-8000-000000000002'::uuid,'A',2),
 ('f9000000-0000-4000-8000-000000000003'::uuid,'B',1),('f9000000-0000-4000-8000-000000000004'::uuid,'B',2)
) as q(id,t,ordem) on q.t = a.t
on conflict (avaliacao_id,questao_id) do nothing;

insert into public.registros_aula(id,tenant_id,turma_id,disciplina_id,professor_id,observacao) values
 ('fb000000-0000-4000-8000-000000000001','f1000000-0000-4000-8000-000000000001','f6000000-0000-4000-8000-000000000001','f5000000-0000-4000-8000-000000000001','f3000000-0000-4000-8000-000000000002','STG registro A1'),
 ('fb000000-0000-4000-8000-000000000002','f1000000-0000-4000-8000-000000000001','f6000000-0000-4000-8000-000000000002','f5000000-0000-4000-8000-000000000001','f3000000-0000-4000-8000-000000000003','STG registro A2')
on conflict (id) do nothing;

insert into public.presencas(id,tenant_id,registro_aula_id,usuario_id,situacao) values
 ('fc000000-0000-4000-8000-000000000001','f1000000-0000-4000-8000-000000000001','fb000000-0000-4000-8000-000000000001','f3000000-0000-4000-8000-000000000004','presente'),
 ('fc000000-0000-4000-8000-000000000002','f1000000-0000-4000-8000-000000000001','fb000000-0000-4000-8000-000000000001','f3000000-0000-4000-8000-000000000005','ausente'),
 ('fc000000-0000-4000-8000-000000000003','f1000000-0000-4000-8000-000000000001','fb000000-0000-4000-8000-000000000002','f3000000-0000-4000-8000-000000000006','presente')
on conflict (id) do nothing;

insert into public.materiais_professor(id,tenant_id,turma_id,disciplina_id,professor_id,titulo) values
 ('fd000000-0000-4000-8000-000000000001','f1000000-0000-4000-8000-000000000001','f6000000-0000-4000-8000-000000000001','f5000000-0000-4000-8000-000000000001','f3000000-0000-4000-8000-000000000002','STG material A1'),
 ('fd000000-0000-4000-8000-000000000002','f1000000-0000-4000-8000-000000000001','f6000000-0000-4000-8000-000000000002','f5000000-0000-4000-8000-000000000001','f3000000-0000-4000-8000-000000000003','STG material A2')
on conflict (id) do nothing;

insert into public.avisos_turma(id,tenant_id,turma_id,professor_id,titulo) values
 ('fe000000-0000-4000-8000-000000000001','f1000000-0000-4000-8000-000000000001','f6000000-0000-4000-8000-000000000001','f3000000-0000-4000-8000-000000000002','STG aviso A1'),
 ('fe000000-0000-4000-8000-000000000002','f1000000-0000-4000-8000-000000000001','f6000000-0000-4000-8000-000000000002','f3000000-0000-4000-8000-000000000003','STG aviso A2')
on conflict (id) do nothing;

commit;

-- Checksum determinístico (colunas estáveis) para provar reprodutibilidade.
select 'KORA_STG_FIXTURE_CHECKSUM|' || md5(string_agg(x, '|' order by x)) as checksum from (
  select 'T'||id||slug from public.tenants where slug like 'kora-stg-escola-%'
  union all select 'U'||id||tenant_id||perfil||email||ativo from public.usuarios where id::text like 'f3000000-%'
  union all select 'C'||id||tenant_id from public.cursos where id::text like 'f4000000-%'
  union all select 'R'||id||tenant_id||curso_id from public.turmas where id::text like 'f6000000-%'
  union all select 'M'||id||usuario_id||turma_id from public.matriculas where id::text like 'f7000000-%'
  union all select 'P'||id||usuario_id||turma_id from public.professores_turmas where id::text like 'f8000000-%'
  union all select 'Q'||id||tenant_id||pontos from public.questoes where id::text like 'f9000000-%'
  union all select 'A'||id||tenant_id||coalesce(turma_id::text,'-') from public.avaliacoes where id::text like 'fa000000-%'
  union all select 'AQ'||avaliacao_id||questao_id||ordem from public.avaliacao_questoes where avaliacao_id::text like 'fa000000-%'
) s;
