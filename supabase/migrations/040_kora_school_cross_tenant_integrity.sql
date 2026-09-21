-- SCHOOL-CORE-003: fail-closed cross-tenant academic integrity.
-- This migration never repairs ownership data. Any legacy violation aborts
-- before constraints are installed.

do $preflight$
declare
  r record;
  v_count bigint;
  v_samples text[];
begin
  for r in
    select * from (values
      ('SC003-R01','disciplinas','id','curso_id','cursos'),
      ('SC003-R02','aulas','id','disciplina_id','disciplinas'),
      ('SC003-R03','materiais_apoio','id','disciplina_id','disciplinas'),
      ('SC003-R04','turmas','id','curso_id','cursos'),
      ('SC003-R05','turmas','id','unidade_id','unidades'),
      ('SC003-R06','matriculas','id','usuario_id','usuarios'),
      ('SC003-R07','matriculas','id','curso_id','cursos'),
      ('SC003-R08','matriculas','id','turma_id','turmas'),
      ('SC003-R09','matriculas','id','unidade_id','unidades'),
      ('SC003-R10','progresso_aulas','id','usuario_id','usuarios'),
      ('SC003-R11','progresso_aulas','id','aula_id','aulas'),
      ('SC003-R12','professores_turmas','id','usuario_id','usuarios'),
      ('SC003-R13','professores_turmas','id','turma_id','turmas'),
      ('SC003-R14','registros_aula','id','turma_id','turmas'),
      ('SC003-R15','registros_aula','id','disciplina_id','disciplinas'),
      ('SC003-R16','registros_aula','id','professor_id','usuarios'),
      ('SC003-R17','presencas','id','registro_aula_id','registros_aula'),
      ('SC003-R18','presencas','id','usuario_id','usuarios'),
      ('SC003-R19','materiais_professor','id','turma_id','turmas'),
      ('SC003-R20','materiais_professor','id','disciplina_id','disciplinas'),
      ('SC003-R21','materiais_professor','id','professor_id','usuarios'),
      ('SC003-R22','avisos_turma','id','turma_id','turmas'),
      ('SC003-R23','avisos_turma','id','professor_id','usuarios'),
      ('SC003-R24','questoes','id','disciplina_id','disciplinas'),
      ('SC003-R25','questoes','id','criado_por','usuarios'),
      ('SC003-R26','avaliacoes','id','curso_id','cursos'),
      ('SC003-R27','avaliacoes','id','disciplina_id','disciplinas'),
      ('SC003-R28','avaliacoes','id','turma_id','turmas'),
      ('SC003-R29','avaliacoes','id','criado_por','usuarios'),
      ('SC003-R32','avaliacao_tentativas','id','avaliacao_id','avaliacoes'),
      ('SC003-R33','avaliacao_tentativas','id','matricula_id','matriculas'),
      ('SC003-R34','avaliacao_tentativas','id','usuario_id','usuarios'),
      ('SC003-R35','avaliacao_respostas','id','tentativa_id','avaliacao_tentativas'),
      ('SC003-R36','avaliacao_respostas','id','questao_id','questoes'),
      ('SC003-R37','leads','id','curso_id','cursos'),
      ('SC003-R38','leads','id','unidade_id','unidades')
    ) x(relation_id, child_table, child_key, child_fk, parent_table)
  loop
    execute format(
      'select count(*), (array_agg(c.%I::text order by c.%I))[1:10]
         from public.%I c left join public.%I p on p.id = c.%I
        where c.%I is not null and p.id is null',
      r.child_key, r.child_key, r.child_table, r.parent_table,
      r.child_fk, r.child_fk)
      into v_count, v_samples;
    if v_count > 0 then
      raise exception '% ORPHAN count=% samples=%', r.relation_id, v_count, v_samples;
    end if;

    execute format(
      'select count(*), (array_agg(c.%I::text order by c.%I))[1:10]
         from public.%I c join public.%I p on p.id = c.%I
        where c.%I is not null and c.tenant_id is distinct from p.tenant_id',
      r.child_key, r.child_key, r.child_table, r.parent_table,
      r.child_fk, r.child_fk)
      into v_count, v_samples;
    if v_count > 0 then
      raise exception '% TENANT_MISMATCH count=% samples=%', r.relation_id, v_count, v_samples;
    end if;
  end loop;

  select count(*), (array_agg(m.id::text order by m.id))[1:10]
    into v_count, v_samples from public.matriculas m join public.turmas t on t.id=m.turma_id
   where m.curso_id is distinct from t.curso_id;
  if v_count > 0 then raise exception 'SC003-R08 COURSE_MISMATCH count=% samples=%',v_count,v_samples; end if;

  select count(*), (array_agg(ra.id::text order by ra.id))[1:10]
    into v_count,v_samples from public.registros_aula ra join public.turmas t on t.id=ra.turma_id
    join public.disciplinas d on d.id=ra.disciplina_id where d.curso_id is distinct from t.curso_id;
  if v_count > 0 then raise exception 'SC003-R15 COURSE_MISMATCH count=% samples=%',v_count,v_samples; end if;

  select count(*), (array_agg(p.id::text order by p.id))[1:10]
    into v_count,v_samples from public.presencas p join public.registros_aula ra on ra.id=p.registro_aula_id
   where not exists (select 1 from public.matriculas m where m.usuario_id=p.usuario_id and m.turma_id=ra.turma_id);
  if v_count > 0 then raise exception 'SC003-R18 ENROLLMENT_MISMATCH count=% samples=%',v_count,v_samples; end if;

  select count(*), (array_agg(mp.id::text order by mp.id))[1:10]
    into v_count,v_samples from public.materiais_professor mp join public.turmas t on t.id=mp.turma_id
    join public.disciplinas d on d.id=mp.disciplina_id where d.curso_id is distinct from t.curso_id;
  if v_count > 0 then raise exception 'SC003-R20 COURSE_MISMATCH count=% samples=%',v_count,v_samples; end if;

  select count(*), (array_agg(a.id::text order by a.id))[1:10]
    into v_count,v_samples from public.avaliacoes a join public.disciplinas d on d.id=a.disciplina_id
   where a.curso_id is distinct from d.curso_id;
  if v_count > 0 then raise exception 'SC003-R27 COURSE_MISMATCH count=% samples=%',v_count,v_samples; end if;

  select count(*), (array_agg(a.id::text order by a.id))[1:10]
    into v_count,v_samples from public.avaliacoes a join public.turmas t on t.id=a.turma_id
   where a.curso_id is distinct from t.curso_id;
  if v_count > 0 then raise exception 'SC003-R28 COURSE_MISMATCH count=% samples=%',v_count,v_samples; end if;

  select count(*), (array_agg(aq.avaliacao_id::text||':'||aq.questao_id::text))[1:10]
    into v_count,v_samples from public.avaliacao_questoes aq
    left join public.avaliacoes a on a.id=aq.avaliacao_id left join public.questoes q on q.id=aq.questao_id
   where a.id is null or q.id is null or a.tenant_id is distinct from q.tenant_id
      or a.disciplina_id is distinct from q.disciplina_id;
  if v_count > 0 then raise exception 'SC003-R30/R31 ASSESSMENT_QUESTION_MISMATCH count=% samples=%',v_count,v_samples; end if;

  select count(*), (array_agg(at.id::text order by at.id))[1:10]
    into v_count,v_samples from public.avaliacao_tentativas at
    join public.avaliacoes a on a.id=at.avaliacao_id join public.matriculas m on m.id=at.matricula_id
   where at.usuario_id is distinct from m.usuario_id or a.curso_id is distinct from m.curso_id
      or (a.turma_id is not null and a.turma_id is distinct from m.turma_id);
  if v_count > 0 then raise exception 'SC003-R33/R34 ATTEMPT_MISMATCH count=% samples=%',v_count,v_samples; end if;

  select count(*), (array_agg(ar.id::text order by ar.id))[1:10]
    into v_count,v_samples from public.avaliacao_respostas ar
    join public.avaliacao_tentativas at on at.id=ar.tentativa_id
   where not exists (select 1 from public.avaliacao_questoes aq
                      where aq.avaliacao_id=at.avaliacao_id and aq.questao_id=ar.questao_id);
  if v_count > 0 then raise exception 'SC003-R36 QUESTION_NOT_IN_ASSESSMENT count=% samples=%',v_count,v_samples; end if;
end
$preflight$;

-- Parent uniqueness required by tenant-aware foreign keys.
create unique index if not exists unidades_id_tenant_key_sc003 on public.unidades(id,tenant_id);
create unique index if not exists usuarios_id_tenant_key_sc003 on public.usuarios(id,tenant_id);
create unique index if not exists cursos_id_tenant_key_sc003 on public.cursos(id,tenant_id);
create unique index if not exists disciplinas_id_tenant_key_sc003 on public.disciplinas(id,tenant_id);
create unique index if not exists disciplinas_id_curso_tenant_key_sc003 on public.disciplinas(id,curso_id,tenant_id);
create unique index if not exists aulas_id_tenant_key_sc003 on public.aulas(id,tenant_id);
create unique index if not exists turmas_id_tenant_key_sc003 on public.turmas(id,tenant_id);
create unique index if not exists turmas_id_curso_tenant_key_sc003 on public.turmas(id,curso_id,tenant_id);
create unique index if not exists matriculas_id_tenant_key_sc003 on public.matriculas(id,tenant_id);
create unique index if not exists registros_aula_id_tenant_key_sc003 on public.registros_aula(id,tenant_id);
create unique index if not exists avaliacoes_id_tenant_key_sc003 on public.avaliacoes(id,tenant_id);
create unique index if not exists questoes_id_tenant_key_sc003 on public.questoes(id,tenant_id);
create unique index if not exists avaliacao_tentativas_id_tenant_key_sc003 on public.avaliacao_tentativas(id,tenant_id);

alter table public.avaliacao_questoes add column tenant_id uuid;
update public.avaliacao_questoes aq set tenant_id=a.tenant_id from public.avaliacoes a where a.id=aq.avaliacao_id;
alter table public.avaliacao_questoes alter column tenant_id set not null;
create index avaliacao_questoes_tenant_sc003 on public.avaliacao_questoes(tenant_id);

-- Tenant-aware foreign keys. Existing single-column FKs remain until every
-- replacement has validated, preserving controlled failure semantics.
alter table public.disciplinas add constraint disciplinas_curso_tenant_fk_sc003 foreign key(curso_id,tenant_id) references public.cursos(id,tenant_id) on delete cascade not valid;
alter table public.aulas add constraint aulas_disciplina_tenant_fk_sc003 foreign key(disciplina_id,tenant_id) references public.disciplinas(id,tenant_id) on delete cascade not valid;
alter table public.materiais_apoio add constraint materiais_apoio_disciplina_tenant_fk_sc003 foreign key(disciplina_id,tenant_id) references public.disciplinas(id,tenant_id) on delete cascade not valid;
alter table public.turmas add constraint turmas_curso_tenant_fk_sc003 foreign key(curso_id,tenant_id) references public.cursos(id,tenant_id) on delete cascade not valid;
alter table public.turmas add constraint turmas_unidade_tenant_fk_sc003 foreign key(unidade_id,tenant_id) references public.unidades(id,tenant_id) on delete set null (unidade_id) not valid;
alter table public.matriculas add constraint matriculas_usuario_tenant_fk_sc003 foreign key(usuario_id,tenant_id) references public.usuarios(id,tenant_id) on delete cascade not valid;
alter table public.matriculas add constraint matriculas_curso_tenant_fk_sc003 foreign key(curso_id,tenant_id) references public.cursos(id,tenant_id) on delete cascade not valid;
alter table public.matriculas add constraint matriculas_turma_curso_tenant_fk_sc003 foreign key(turma_id,curso_id,tenant_id) references public.turmas(id,curso_id,tenant_id) on delete set null (turma_id) not valid;
alter table public.matriculas add constraint matriculas_unidade_tenant_fk_sc003 foreign key(unidade_id,tenant_id) references public.unidades(id,tenant_id) on delete set null (unidade_id) not valid;
alter table public.progresso_aulas add constraint progresso_usuario_tenant_fk_sc003 foreign key(usuario_id,tenant_id) references public.usuarios(id,tenant_id) on delete cascade not valid;
alter table public.progresso_aulas add constraint progresso_aula_tenant_fk_sc003 foreign key(aula_id,tenant_id) references public.aulas(id,tenant_id) on delete cascade not valid;
alter table public.professores_turmas add constraint professores_turmas_usuario_tenant_fk_sc003 foreign key(usuario_id,tenant_id) references public.usuarios(id,tenant_id) on delete cascade not valid;
alter table public.professores_turmas add constraint professores_turmas_turma_tenant_fk_sc003 foreign key(turma_id,tenant_id) references public.turmas(id,tenant_id) on delete cascade not valid;
alter table public.registros_aula add constraint registros_aula_turma_tenant_fk_sc003 foreign key(turma_id,tenant_id) references public.turmas(id,tenant_id) on delete cascade not valid;
alter table public.registros_aula add constraint registros_aula_disciplina_tenant_fk_sc003 foreign key(disciplina_id,tenant_id) references public.disciplinas(id,tenant_id) on delete set null (disciplina_id) not valid;
alter table public.registros_aula add constraint registros_aula_professor_tenant_fk_sc003 foreign key(professor_id,tenant_id) references public.usuarios(id,tenant_id) on delete set null (professor_id) not valid;
alter table public.presencas add constraint presencas_registro_tenant_fk_sc003 foreign key(registro_aula_id,tenant_id) references public.registros_aula(id,tenant_id) on delete cascade not valid;
alter table public.presencas add constraint presencas_usuario_tenant_fk_sc003 foreign key(usuario_id,tenant_id) references public.usuarios(id,tenant_id) on delete cascade not valid;
alter table public.materiais_professor add constraint materiais_prof_turma_tenant_fk_sc003 foreign key(turma_id,tenant_id) references public.turmas(id,tenant_id) on delete cascade not valid;
alter table public.materiais_professor add constraint materiais_prof_disciplina_tenant_fk_sc003 foreign key(disciplina_id,tenant_id) references public.disciplinas(id,tenant_id) on delete set null (disciplina_id) not valid;
alter table public.materiais_professor add constraint materiais_prof_professor_tenant_fk_sc003 foreign key(professor_id,tenant_id) references public.usuarios(id,tenant_id) on delete cascade not valid;
alter table public.avisos_turma add constraint avisos_turma_turma_tenant_fk_sc003 foreign key(turma_id,tenant_id) references public.turmas(id,tenant_id) on delete cascade not valid;
alter table public.avisos_turma add constraint avisos_turma_professor_tenant_fk_sc003 foreign key(professor_id,tenant_id) references public.usuarios(id,tenant_id) on delete set null (professor_id) not valid;
alter table public.questoes add constraint questoes_disciplina_tenant_fk_sc003 foreign key(disciplina_id,tenant_id) references public.disciplinas(id,tenant_id) on delete cascade not valid;
alter table public.questoes add constraint questoes_criador_tenant_fk_sc003 foreign key(criado_por,tenant_id) references public.usuarios(id,tenant_id) on delete set null (criado_por) not valid;
alter table public.avaliacoes add constraint avaliacoes_curso_tenant_fk_sc003 foreign key(curso_id,tenant_id) references public.cursos(id,tenant_id) on delete cascade not valid;
alter table public.avaliacoes add constraint avaliacoes_disciplina_curso_tenant_fk_sc003 foreign key(disciplina_id,curso_id,tenant_id) references public.disciplinas(id,curso_id,tenant_id) on delete cascade not valid;
alter table public.avaliacoes add constraint avaliacoes_turma_curso_tenant_fk_sc003 foreign key(turma_id,curso_id,tenant_id) references public.turmas(id,curso_id,tenant_id) on delete cascade not valid;
alter table public.avaliacoes add constraint avaliacoes_criador_tenant_fk_sc003 foreign key(criado_por,tenant_id) references public.usuarios(id,tenant_id) on delete set null (criado_por) not valid;
alter table public.avaliacao_questoes add constraint avaliacao_questoes_avaliacao_tenant_fk_sc003 foreign key(avaliacao_id,tenant_id) references public.avaliacoes(id,tenant_id) on delete cascade not valid;
alter table public.avaliacao_questoes add constraint avaliacao_questoes_questao_tenant_fk_sc003 foreign key(questao_id,tenant_id) references public.questoes(id,tenant_id) on delete restrict not valid;
alter table public.avaliacao_tentativas add constraint tentativas_avaliacao_tenant_fk_sc003 foreign key(avaliacao_id,tenant_id) references public.avaliacoes(id,tenant_id) on delete cascade not valid;
alter table public.avaliacao_tentativas add constraint tentativas_matricula_tenant_fk_sc003 foreign key(matricula_id,tenant_id) references public.matriculas(id,tenant_id) on delete cascade not valid;
alter table public.avaliacao_tentativas add constraint tentativas_usuario_tenant_fk_sc003 foreign key(usuario_id,tenant_id) references public.usuarios(id,tenant_id) on delete cascade not valid;
alter table public.avaliacao_respostas add constraint respostas_tentativa_tenant_fk_sc003 foreign key(tentativa_id,tenant_id) references public.avaliacao_tentativas(id,tenant_id) on delete cascade not valid;
alter table public.avaliacao_respostas add constraint respostas_questao_tenant_fk_sc003 foreign key(questao_id,tenant_id) references public.questoes(id,tenant_id) on delete restrict not valid;
alter table public.leads add constraint leads_curso_tenant_fk_sc003 foreign key(curso_id,tenant_id) references public.cursos(id,tenant_id) on delete set null (curso_id) not valid;
alter table public.leads add constraint leads_unidade_tenant_fk_sc003 foreign key(unidade_id,tenant_id) references public.unidades(id,tenant_id) on delete set null (unidade_id) not valid;

create or replace function public.sc003_validate_registro_aula() returns trigger
language plpgsql security invoker set search_path='' as $$
begin
  if new.disciplina_id is not null and not exists (
    select 1 from public.turmas t join public.disciplinas d on d.id=new.disciplina_id
     where t.id=new.turma_id and t.tenant_id=new.tenant_id and d.tenant_id=new.tenant_id and d.curso_id=t.curso_id
  ) then raise exception 'SC003_R15_COURSE_MISMATCH' using errcode='23514'; end if;
  return new;
end $$;
create trigger sc003_registro_aula_integrity before insert or update of tenant_id,turma_id,disciplina_id on public.registros_aula for each row execute function public.sc003_validate_registro_aula();

create or replace function public.sc003_validate_presenca() returns trigger
language plpgsql security invoker set search_path='' as $$
begin
  if not exists (select 1 from public.registros_aula ra join public.matriculas m on m.turma_id=ra.turma_id
                  where ra.id=new.registro_aula_id and ra.tenant_id=new.tenant_id
                    and m.usuario_id=new.usuario_id and m.tenant_id=new.tenant_id)
  then raise exception 'SC003_R18_ENROLLMENT_MISMATCH' using errcode='23514'; end if;
  return new;
end $$;
create trigger sc003_presenca_integrity before insert or update of tenant_id,registro_aula_id,usuario_id on public.presencas for each row execute function public.sc003_validate_presenca();

create or replace function public.sc003_validate_material_professor() returns trigger
language plpgsql security invoker set search_path='' as $$
begin
  if new.disciplina_id is not null and not exists (
    select 1 from public.turmas t join public.disciplinas d on d.id=new.disciplina_id
     where t.id=new.turma_id and t.tenant_id=new.tenant_id and d.tenant_id=new.tenant_id and d.curso_id=t.curso_id
  ) then raise exception 'SC003_R20_COURSE_MISMATCH' using errcode='23514'; end if;
  return new;
end $$;
create trigger sc003_material_professor_integrity before insert or update of tenant_id,turma_id,disciplina_id on public.materiais_professor for each row execute function public.sc003_validate_material_professor();

create or replace function public.sc003_validate_avaliacao_questao() returns trigger
language plpgsql security invoker set search_path='' as $$
declare v_tenant uuid;
begin
  select tenant_id into v_tenant from public.avaliacoes where id=new.avaliacao_id;
  if v_tenant is null then raise exception 'SC003_R30_ASSESSMENT_MISSING' using errcode='23503'; end if;
  if new.tenant_id is null then new.tenant_id := v_tenant; end if;
  if not exists (select 1 from public.avaliacoes a join public.questoes q on q.id=new.questao_id
                  where a.id=new.avaliacao_id and a.tenant_id=new.tenant_id
                    and q.tenant_id=new.tenant_id and q.disciplina_id=a.disciplina_id)
  then raise exception 'SC003_R31_DISCIPLINA_MISMATCH' using errcode='23514'; end if;
  return new;
end $$;
create trigger sc003_avaliacao_questao_integrity before insert or update of tenant_id,avaliacao_id,questao_id on public.avaliacao_questoes for each row execute function public.sc003_validate_avaliacao_questao();

create or replace function public.sc003_validate_tentativa() returns trigger
language plpgsql security invoker set search_path='' as $$
begin
  if not exists (select 1 from public.avaliacoes a join public.matriculas m on m.id=new.matricula_id
                  where a.id=new.avaliacao_id and a.tenant_id=new.tenant_id and m.tenant_id=new.tenant_id
                    and m.usuario_id=new.usuario_id and m.curso_id=a.curso_id
                    and (a.turma_id is null or a.turma_id=m.turma_id))
  then raise exception 'SC003_R33_R34_ATTEMPT_MISMATCH' using errcode='23514'; end if;
  return new;
end $$;
create trigger sc003_tentativa_integrity before insert or update of tenant_id,avaliacao_id,matricula_id,usuario_id on public.avaliacao_tentativas for each row execute function public.sc003_validate_tentativa();

create or replace function public.sc003_validate_resposta() returns trigger
language plpgsql security invoker set search_path='' as $$
begin
  if not exists (select 1 from public.avaliacao_tentativas at join public.avaliacao_questoes aq
                    on aq.avaliacao_id=at.avaliacao_id and aq.questao_id=new.questao_id and aq.tenant_id=new.tenant_id
                  where at.id=new.tentativa_id and at.tenant_id=new.tenant_id)
  then raise exception 'SC003_R36_QUESTION_NOT_IN_ASSESSMENT' using errcode='23514'; end if;
  return new;
end $$;
create trigger sc003_resposta_integrity before insert or update of tenant_id,tentativa_id,questao_id on public.avaliacao_respostas for each row execute function public.sc003_validate_resposta();

drop policy if exists avaliacao_questoes_docente on public.avaliacao_questoes;
create policy avaliacao_questoes_docente on public.avaliacao_questoes for all to authenticated
 using (tenant_id=public.current_tenant_id() and public.is_docente())
 with check (tenant_id=public.current_tenant_id() and public.is_docente());

-- Validate after all write guards are active.
do $validate$
declare r record;
begin
  for r in select conrelid::regclass as rel, conname from pg_constraint
            where conname like '%\_sc003' escape '\' and contype='f' and not convalidated
  loop execute format('alter table %s validate constraint %I',r.rel,r.conname); end loop;
end
$validate$;

-- Helpful child-side indexes for composite FK checks and joins.
create index if not exists disciplinas_curso_tenant_sc003 on public.disciplinas(curso_id,tenant_id);
create index if not exists aulas_disciplina_tenant_sc003 on public.aulas(disciplina_id,tenant_id);
create index if not exists matriculas_turma_curso_tenant_sc003 on public.matriculas(turma_id,curso_id,tenant_id);
create index if not exists progresso_aula_tenant_sc003 on public.progresso_aulas(aula_id,tenant_id);
create index if not exists presencas_registro_tenant_sc003 on public.presencas(registro_aula_id,tenant_id);
create index if not exists tentativas_avaliacao_tenant_sc003 on public.avaliacao_tentativas(avaliacao_id,tenant_id);
create index if not exists respostas_tentativa_tenant_sc003 on public.avaliacao_respostas(tentativa_id,tenant_id);

do $postconditions$
declare v_unvalidated bigint;
begin
  select count(*) into v_unvalidated from pg_constraint
   where conname like '%\_sc003' escape '\' and contype='f' and not convalidated;
  if v_unvalidated <> 0 then raise exception 'SC003_POSTCONDITION_UNVALIDATED_FKS count=%',v_unvalidated; end if;
  if exists(select 1 from public.avaliacao_questoes where tenant_id is null)
  then raise exception 'SC003_POSTCONDITION_NULL_ASSESSMENT_TENANT'; end if;
end
$postconditions$;
