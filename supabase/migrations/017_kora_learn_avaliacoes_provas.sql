-- KORA LEARN — Migration 017: Avaliações e Provas (Fase 19)
--
-- Banco de questões por disciplina, provas montadas por seleção de questões,
-- regras manuais ou por coorte, tentativas com ordem aleatória por aluno,
-- correção automática de objetivas e fila de correção dissertativa.
--
-- A ordem e o gabarito são congelados na tentativa. Assim, alterar uma
-- questão depois da aplicação não muda a prova já iniciada nem sua nota.
-- ============================================================

-- ------------------------------------------------------------
-- 0. Tipos
-- ------------------------------------------------------------
do $$ begin
  create type tipo_questao as enum ('objetiva', 'dissertativa');
exception when duplicate_object then null; end $$;

do $$ begin
  create type dificuldade_questao as enum ('facil', 'medio', 'dificil');
exception when duplicate_object then null; end $$;

do $$ begin
  create type situacao_avaliacao as enum ('rascunho', 'publicada', 'encerrada');
exception when duplicate_object then null; end $$;

do $$ begin
  create type situacao_tentativa as enum ('em_andamento', 'enviada', 'corrigida', 'expirada');
exception when duplicate_object then null; end $$;

-- ------------------------------------------------------------
-- 1. Banco de questões
-- alternativas: [{"id":"a","texto":"..."}, ...]
-- resposta_correta guarda somente o ID da alternativa, nunca sua posição.
-- ------------------------------------------------------------
create table if not exists questoes (
  id                uuid primary key default gen_random_uuid(),
  tenant_id         uuid not null references tenants(id) on delete cascade,
  disciplina_id     uuid not null references disciplinas(id) on delete cascade,
  enunciado         text not null,
  tipo              tipo_questao not null default 'objetiva',
  dificuldade       dificuldade_questao not null default 'medio',
  alternativas      jsonb not null default '[]'::jsonb,
  resposta_correta  text,
  pontos            numeric(8,2) not null default 1 check (pontos > 0),
  ativa             boolean not null default true,
  criado_por        uuid references usuarios(id) on delete set null,
  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now(),
  constraint questoes_objetiva_gabarito check (
    tipo = 'dissertativa' or resposta_correta is not null
  )
);
create index if not exists idx_questoes_tenant_disciplina on questoes(tenant_id, disciplina_id, ativa);

-- ------------------------------------------------------------
-- 2. Avaliações / provas
-- Para EAD com coorte, intervalo_dias define o ciclo desde a matrícula:
-- 60 = primeira prova após 60 dias, segunda após 120, e assim por diante.
-- ------------------------------------------------------------
create table if not exists avaliacoes (
  id                    uuid primary key default gen_random_uuid(),
  tenant_id             uuid not null references tenants(id) on delete cascade,
  curso_id              uuid not null references cursos(id) on delete cascade,
  disciplina_id         uuid not null references disciplinas(id) on delete cascade,
  turma_id              uuid references turmas(id) on delete cascade,
  titulo                text not null,
  descricao             text,
  situacao              situacao_avaliacao not null default 'rascunho',
  modo_aplicacao        text not null default 'presencial' check (modo_aplicacao in ('presencial', 'ead')),
  regra_liberacao       text not null default 'manual' check (regra_liberacao in ('manual', 'coorte')),
  intervalo_dias        integer not null default 0 check (intervalo_dias >= 0),
  tentativas_permitidas integer not null default 1 check (tentativas_permitidas between 1 and 10),
  nota_minima           numeric(5,2) not null default 60 check (nota_minima between 0 and 100),
  expira_em_dias        integer check (expira_em_dias is null or expira_em_dias > 0),
  quantidade_questoes   integer check (quantidade_questoes is null or quantidade_questoes > 0),
  embaralhar_questoes   boolean not null default true,
  embaralhar_alternativas boolean not null default true,
  disponivel_em         timestamptz,
  criado_por            uuid references usuarios(id) on delete set null,
  created_at            timestamptz not null default now(),
  updated_at            timestamptz not null default now()
);
create index if not exists idx_avaliacoes_tenant_disciplina on avaliacoes(tenant_id, disciplina_id, situacao);
create index if not exists idx_avaliacoes_turma on avaliacoes(turma_id, situacao);

create table if not exists avaliacao_questoes (
  avaliacao_id uuid not null references avaliacoes(id) on delete cascade,
  questao_id   uuid not null references questoes(id) on delete restrict,
  ordem        integer not null default 0,
  primary key (avaliacao_id, questao_id)
);
create index if not exists idx_avaliacao_questoes_questao on avaliacao_questoes(questao_id);

-- ------------------------------------------------------------
-- 3. Tentativas e respostas
-- questoes_ordem é o snapshot público da prova; gabarito_snapshot nunca
-- é retornado ao aluno e fica somente para correção no servidor.
-- ------------------------------------------------------------
create table if not exists avaliacao_tentativas (
  id                 uuid primary key default gen_random_uuid(),
  tenant_id          uuid not null references tenants(id) on delete cascade,
  avaliacao_id       uuid not null references avaliacoes(id) on delete cascade,
  matricula_id       uuid not null references matriculas(id) on delete cascade,
  usuario_id         uuid not null references usuarios(id) on delete cascade,
  numero_tentativa   integer not null check (numero_tentativa > 0),
  situacao           situacao_tentativa not null default 'em_andamento',
  iniciada_em        timestamptz not null default now(),
  expira_em          timestamptz,
  enviada_em         timestamptz,
  nota               numeric(8,2),
  nota_maxima        numeric(8,2),
  percentual         numeric(5,2),
  aprovada           boolean,
  questoes_ordem     jsonb not null default '[]'::jsonb,
  gabarito_snapshot  jsonb not null default '{}'::jsonb,
  created_at         timestamptz not null default now(),
  unique (avaliacao_id, matricula_id, numero_tentativa)
);
create index if not exists idx_tentativas_tenant_usuario on avaliacao_tentativas(tenant_id, usuario_id, situacao);
create index if not exists idx_tentativas_avaliacao on avaliacao_tentativas(avaliacao_id, matricula_id);

create table if not exists avaliacao_respostas (
  id             uuid primary key default gen_random_uuid(),
  tenant_id      uuid not null references tenants(id) on delete cascade,
  tentativa_id   uuid not null references avaliacao_tentativas(id) on delete cascade,
  questao_id     uuid not null references questoes(id) on delete restrict,
  alternativa_id text,
  resposta_texto text,
  pontos_obtidos numeric(8,2) not null default 0,
  corrigida      boolean not null default false,
  comentario     text,
  created_at     timestamptz not null default now(),
  unique (tentativa_id, questao_id)
);
create index if not exists idx_respostas_tentativa on avaliacao_respostas(tentativa_id);
create index if not exists idx_respostas_pendentes on avaliacao_respostas(tenant_id, corrigida);

-- ------------------------------------------------------------
-- 4. RLS: banco e montagem para docentes; tentativas próprias para alunos.
--    Os alunos recebem as questões somente pelos RPCs abaixo, sem acesso
--    direto ao banco de questões nem ao gabarito.
-- ------------------------------------------------------------
alter table questoes enable row level security;
alter table avaliacoes enable row level security;
alter table avaliacao_questoes enable row level security;
alter table avaliacao_tentativas enable row level security;
alter table avaliacao_respostas enable row level security;

drop policy if exists questoes_docente on questoes;
create policy questoes_docente on questoes
  for all to authenticated
  using (tenant_id = public.current_tenant_id() and public.is_docente())
  with check (tenant_id = public.current_tenant_id() and public.is_docente());

drop policy if exists avaliacoes_docente on avaliacoes;
create policy avaliacoes_docente on avaliacoes
  for all to authenticated
  using (tenant_id = public.current_tenant_id() and public.is_docente())
  with check (tenant_id = public.current_tenant_id() and public.is_docente());

drop policy if exists avaliacao_questoes_docente on avaliacao_questoes;
create policy avaliacao_questoes_docente on avaliacao_questoes
  for all to authenticated
  using (exists (
    select 1 from avaliacoes a
    where a.id = avaliacao_questoes.avaliacao_id
      and a.tenant_id = public.current_tenant_id()
      and public.is_docente()
  ))
  with check (exists (
    select 1 from avaliacoes a
    where a.id = avaliacao_questoes.avaliacao_id
      and a.tenant_id = public.current_tenant_id()
      and public.is_docente()
  ));

drop policy if exists tentativas_docente on avaliacao_tentativas;
create policy tentativas_docente on avaliacao_tentativas
  for select to authenticated
  using (tenant_id = public.current_tenant_id() and public.is_docente());

drop policy if exists tentativas_aluno on avaliacao_tentativas;
create policy tentativas_aluno on avaliacao_tentativas
  for select to authenticated
  using (usuario_id = public.current_usuario_id());

drop policy if exists respostas_docente on avaliacao_respostas;
create policy respostas_docente on avaliacao_respostas
  for all to authenticated
  using (tenant_id = public.current_tenant_id() and public.is_docente())
  with check (tenant_id = public.current_tenant_id() and public.is_docente());

drop policy if exists respostas_aluno on avaliacao_respostas;
create policy respostas_aluno on avaliacao_respostas
  for select to authenticated
  using (exists (
    select 1 from avaliacao_tentativas t
    where t.id = avaliacao_respostas.tentativa_id
      and t.usuario_id = public.current_usuario_id()
  ));

-- ------------------------------------------------------------
-- 5. RPC: avaliações disponíveis ao aluno
-- ------------------------------------------------------------
create or replace function public.avaliacoes_disponiveis_aluno()
returns table (
  avaliacao_id uuid,
  matricula_id uuid,
  curso_id uuid,
  disciplina_id uuid,
  turma_id uuid,
  titulo text,
  descricao text,
  disciplina_nome text,
  modo_aplicacao text,
  regra_liberacao text,
  intervalo_dias integer,
  tentativas_permitidas integer,
  tentativas_usadas integer,
  nota_minima numeric,
  disponivel boolean,
  motivo text
)
language plpgsql stable security definer
set search_path = public
as $$
begin
  return query
  select
    a.id,
    m.id,
    a.curso_id,
    a.disciplina_id,
    a.turma_id,
    a.titulo,
    a.descricao,
    d.nome,
    a.modo_aplicacao,
    a.regra_liberacao,
    a.intervalo_dias,
    a.tentativas_permitidas,
    coalesce((select count(*)::integer from avaliacao_tentativas t
      where t.avaliacao_id = a.id and t.matricula_id = m.id), 0),
    a.nota_minima,
    (
      a.situacao = 'publicada'
      and (a.disponivel_em is null or a.disponivel_em <= now())
      and (a.turma_id is null or a.turma_id = m.turma_id)
      and (a.regra_liberacao = 'manual' or
        current_date >= m.data_matricula + (a.intervalo_dias * greatest(1, coalesce((
          select count(*) + 1 from avaliacao_tentativas t2
          where t2.avaliacao_id = a.id and t2.matricula_id = m.id
        ), 1)))::integer)
      and coalesce((select count(*) from avaliacao_tentativas t3
        where t3.avaliacao_id = a.id and t3.matricula_id = m.id
          and t3.situacao <> 'expirada'), 0) < a.tentativas_permitidas
    ),
    case
      when a.situacao <> 'publicada' then 'Não publicada'
      when a.disponivel_em is not null and a.disponivel_em > now() then 'Disponível em breve'
      when a.regra_liberacao = 'coorte' and current_date < m.data_matricula + (a.intervalo_dias * greatest(1, coalesce((
        select count(*) + 1 from avaliacao_tentativas t4
        where t4.avaliacao_id = a.id and t4.matricula_id = m.id
      ), 1)))::integer then 'Aguardando etapa da coorte'
      when coalesce((select count(*) from avaliacao_tentativas t5
        where t5.avaliacao_id = a.id and t5.matricula_id = m.id
          and t5.situacao <> 'expirada'), 0) >= a.tentativas_permitidas then 'Tentativas esgotadas'
      else null
    end
  from avaliacoes a
  join disciplinas d on d.id = a.disciplina_id
  join matriculas m on m.curso_id = a.curso_id
    and m.usuario_id = public.current_usuario_id()
    and m.tenant_id = public.current_tenant_id()
    and m.situacao = 'ativa'
  where a.tenant_id = public.current_tenant_id();
end;
$$;

revoke all on function public.avaliacoes_disponiveis_aluno() from public;
grant execute on function public.avaliacoes_disponiveis_aluno() to authenticated;

-- ------------------------------------------------------------
-- 6. RPC: iniciar tentativa e congelar sorteio/gabarito
-- ------------------------------------------------------------
create or replace function public.iniciar_tentativa_avaliacao(p_avaliacao_id uuid, p_matricula_id uuid)
returns jsonb
language plpgsql security definer
set search_path = public
as $$
declare
  v_avaliacao avaliacoes%rowtype;
  v_matricula matriculas%rowtype;
  v_usuario_id uuid := public.current_usuario_id();
  v_numero integer;
  v_tentativa avaliacao_tentativas%rowtype;
  v_questoes jsonb;
  v_gabarito jsonb;
  v_qtd integer;
  v_agora timestamptz := now();
begin
  select * into v_avaliacao from avaliacoes
  where id = p_avaliacao_id and tenant_id = public.current_tenant_id();
  if not found then raise exception 'Avaliação não encontrada'; end if;
  select * into v_matricula from matriculas
  where id = p_matricula_id and usuario_id = v_usuario_id
    and tenant_id = public.current_tenant_id() and situacao = 'ativa';
  if not found or v_matricula.curso_id <> v_avaliacao.curso_id then
    raise exception 'Matrícula inválida para esta avaliação';
  end if;
  if v_avaliacao.situacao <> 'publicada' or (v_avaliacao.disponivel_em is not null and v_avaliacao.disponivel_em > v_agora) then
    raise exception 'Avaliação ainda não está disponível';
  end if;

  select coalesce(max(numero_tentativa), 0) + 1 into v_numero
  from avaliacao_tentativas
  where avaliacao_id = p_avaliacao_id and matricula_id = p_matricula_id;
  if v_numero > v_avaliacao.tentativas_permitidas then raise exception 'Limite de tentativas atingido'; end if;
  if v_avaliacao.regra_liberacao = 'coorte'
     and current_date < v_matricula.data_matricula + (v_avaliacao.intervalo_dias * v_numero)::integer then
    raise exception 'Esta etapa da coorte ainda não está disponível';
  end if;

  v_qtd := coalesce(v_avaliacao.quantidade_questoes, 1000000);
  select coalesce(jsonb_agg(jsonb_build_object(
    'questao_id', q.id,
    'enunciado', q.enunciado,
    'tipo', q.tipo,
    'dificuldade', q.dificuldade,
    'pontos', q.pontos,
    'alternativas', case when q.tipo = 'objetiva' and v_avaliacao.embaralhar_alternativas then
      coalesce((select jsonb_agg(alt order by random()) from jsonb_array_elements(q.alternativas) alt), '[]'::jsonb)
      else q.alternativas end,
    '_gabarito', q.resposta_correta
  ) order by case when v_avaliacao.embaralhar_questoes then random() else q.ordem end), '[]'::jsonb)
  into v_questoes
  from (
    select q.*, aq.ordem
    from avaliacao_questoes aq join questoes q on q.id = aq.questao_id
    where aq.avaliacao_id = p_avaliacao_id and q.ativa = true
    order by case when v_avaliacao.embaralhar_questoes then random() else aq.ordem end
    limit v_qtd
  ) q;
  if jsonb_array_length(v_questoes) = 0 then raise exception 'A avaliação não possui questões ativas'; end if;
  select coalesce(jsonb_object_agg(item->>'questao_id', item->>'_gabarito'), '{}'::jsonb) into v_gabarito
  from jsonb_array_elements(v_questoes) item;
  select coalesce(jsonb_agg(item - '_gabarito'), '[]'::jsonb) into v_questoes
  from jsonb_array_elements(v_questoes) item;

  insert into avaliacao_tentativas (
    tenant_id, avaliacao_id, matricula_id, usuario_id, numero_tentativa,
    expira_em, nota_maxima, questoes_ordem, gabarito_snapshot
  ) values (
    v_avaliacao.tenant_id, v_avaliacao.id, v_matricula.id, v_usuario_id, v_numero,
    case when v_avaliacao.expira_em_dias is null then null else v_agora + (v_avaliacao.expira_em_dias || ' days')::interval end,
    (select coalesce(sum((item->>'pontos')::numeric), 0) from jsonb_array_elements(v_questoes) item),
    v_questoes, v_gabarito
  ) returning * into v_tentativa;

  return jsonb_build_object(
    'id', v_tentativa.id,
    'avaliacao_id', v_tentativa.avaliacao_id,
    'numero_tentativa', v_tentativa.numero_tentativa,
    'situacao', v_tentativa.situacao,
    'iniciada_em', v_tentativa.iniciada_em,
    'expira_em', v_tentativa.expira_em,
    'nota_maxima', v_tentativa.nota_maxima,
    'questoes', v_tentativa.questoes_ordem
  );
end;
$$;

revoke all on function public.iniciar_tentativa_avaliacao(uuid, uuid) from public;
grant execute on function public.iniciar_tentativa_avaliacao(uuid, uuid) to authenticated;

-- ------------------------------------------------------------
-- 7. RPC: envio e correção automática de objetivas
-- ------------------------------------------------------------
create or replace function public.enviar_tentativa_avaliacao(p_tentativa_id uuid, p_respostas jsonb)
returns jsonb
language plpgsql security definer
set search_path = public
as $$
declare
  v_tentativa avaliacao_tentativas%rowtype;
  v_avaliacao avaliacoes%rowtype;
  v_item jsonb;
  v_questao_id uuid;
  v_alternativa text;
  v_texto text;
  v_gabarito text;
  v_pontos numeric;
  v_max numeric := 0;
  v_nota numeric := 0;
  v_pendentes integer := 0;
  v_percentual numeric := 0;
  v_situacao situacao_tentativa;
  v_expirada boolean;
begin
  select * into v_tentativa from avaliacao_tentativas
  where id = p_tentativa_id and usuario_id = public.current_usuario_id();
  if not found then raise exception 'Tentativa não encontrada'; end if;
  if v_tentativa.situacao <> 'em_andamento' then raise exception 'Tentativa já enviada'; end if;
  v_expirada := v_tentativa.expira_em is not null and v_tentativa.expira_em < now();
  if v_expirada then
    update avaliacao_tentativas set situacao = 'expirada', enviada_em = now() where id = v_tentativa.id;
    raise exception 'O prazo desta tentativa expirou';
  end if;
  select * into v_avaliacao from avaliacoes where id = v_tentativa.avaliacao_id;

  for v_item in select * from jsonb_array_elements(coalesce(p_respostas, '[]'::jsonb)) loop
    v_questao_id := (v_item->>'questao_id')::uuid;
    v_alternativa := nullif(v_item->>'alternativa_id', '');
    v_texto := nullif(v_item->>'resposta_texto', '');
    if not exists (select 1 from jsonb_array_elements(v_tentativa.questoes_ordem) q where (q->>'questao_id')::uuid = v_questao_id) then
      raise exception 'Questão inválida para esta tentativa';
    end if;
    v_gabarito := v_tentativa.gabarito_snapshot->>v_questao_id::text;
    v_pontos := coalesce(((select q->>'pontos' from jsonb_array_elements(v_tentativa.questoes_ordem) q where (q->>'questao_id')::uuid = v_questao_id))::numeric, 0);
    insert into avaliacao_respostas (tenant_id, tentativa_id, questao_id, alternativa_id, resposta_texto, pontos_obtidos, corrigida)
    values (v_tentativa.tenant_id, v_tentativa.id, v_questao_id, v_alternativa, v_texto,
      case when v_gabarito is not null and v_alternativa = v_gabarito then v_pontos else 0 end,
      v_gabarito is not null)
    on conflict (tentativa_id, questao_id) do update set
      alternativa_id = excluded.alternativa_id,
      resposta_texto = excluded.resposta_texto,
      pontos_obtidos = excluded.pontos_obtidos,
      corrigida = excluded.corrigida;
  end loop;

  select coalesce(sum((q->>'pontos')::numeric), 0) into v_max from jsonb_array_elements(v_tentativa.questoes_ordem) q;
  select coalesce(sum(r.pontos_obtidos), 0), count(*) filter (where not r.corrigida)
    into v_nota, v_pendentes
  from avaliacao_respostas r where r.tentativa_id = v_tentativa.id;
  v_percentual := case when v_max = 0 then 0 else round(100 * v_nota / v_max, 2) end;
  v_situacao := case when v_pendentes > 0 then 'enviada' else 'corrigida' end;
  update avaliacao_tentativas set
    situacao = v_situacao, enviada_em = now(), nota = v_nota, nota_maxima = v_max,
    percentual = v_percentual, aprovada = case when v_pendentes > 0 then null else v_percentual >= v_avaliacao.nota_minima end
  where id = v_tentativa.id;
  return jsonb_build_object('id', v_tentativa.id, 'situacao', v_situacao, 'nota', v_nota, 'nota_maxima', v_max, 'percentual', v_percentual, 'pendentes_correcao', v_pendentes);
end;
$$;

revoke all on function public.enviar_tentativa_avaliacao(uuid, jsonb) from public;
grant execute on function public.enviar_tentativa_avaliacao(uuid, jsonb) to authenticated;

-- ------------------------------------------------------------
-- 8. RPC docente: corrigir dissertativa e recalcular resultado
-- ------------------------------------------------------------
create or replace function public.corrigir_resposta_avaliacao(p_resposta_id uuid, p_pontos numeric, p_comentario text default null)
returns jsonb
language plpgsql security definer
set search_path = public
as $$
declare
  v_resposta avaliacao_respostas%rowtype;
  v_tentativa avaliacao_tentativas%rowtype;
  v_avaliacao avaliacoes%rowtype;
  v_max numeric;
  v_nota numeric;
  v_pendentes integer;
  v_percentual numeric;
begin
  if not public.is_docente() then raise exception 'Somente docentes podem corrigir respostas'; end if;
  select * into v_resposta from avaliacao_respostas
  where id = p_resposta_id and tenant_id = public.current_tenant_id();
  if not found then raise exception 'Resposta não encontrada'; end if;
  select * into v_tentativa from avaliacao_tentativas where id = v_resposta.tentativa_id;
  select * into v_avaliacao from avaliacoes where id = v_tentativa.avaliacao_id;
  if p_pontos < 0 or p_pontos > coalesce(((select q->>'pontos' from jsonb_array_elements(v_tentativa.questoes_ordem) q where (q->>'questao_id')::uuid = v_resposta.questao_id))::numeric, 0) then
    raise exception 'Pontuação fora do limite da questão';
  end if;
  update avaliacao_respostas set pontos_obtidos = p_pontos, comentario = p_comentario, corrigida = true where id = p_resposta_id;
  select coalesce(sum((q->>'pontos')::numeric), 0) into v_max from jsonb_array_elements(v_tentativa.questoes_ordem) q;
  select coalesce(sum(pontos_obtidos), 0), count(*) filter (where not corrigida) into v_nota, v_pendentes from avaliacao_respostas where tentativa_id = v_tentativa.id;
  v_percentual := case when v_max = 0 then 0 else round(100 * v_nota / v_max, 2) end;
  update avaliacao_tentativas set nota = v_nota, nota_maxima = v_max, percentual = v_percentual,
    situacao = case when v_pendentes = 0 then 'corrigida' else 'enviada' end,
    aprovada = case when v_pendentes = 0 then v_percentual >= v_avaliacao.nota_minima else null end
  where id = v_tentativa.id;
  return jsonb_build_object('tentativa_id', v_tentativa.id, 'situacao', case when v_pendentes = 0 then 'corrigida' else 'enviada' end, 'percentual', v_percentual);
end;
$$;

revoke all on function public.corrigir_resposta_avaliacao(uuid, numeric, text) from public;
grant execute on function public.corrigir_resposta_avaliacao(uuid, numeric, text) to authenticated;

-- ------------------------------------------------------------
-- 9. Verificação opcional
-- ------------------------------------------------------------
-- select * from public.avaliacoes_disponiveis_aluno();
-- ============================================================
