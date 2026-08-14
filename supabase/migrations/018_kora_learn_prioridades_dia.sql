-- KORA LEARN — Migration 018: Painel de Prioridades do Dia
-- Feed agregado para a visão geral do gestor, sem expor dados entre tenants.
-- ============================================================

create or replace function public.prioridades_do_dia(p_unidade_id uuid default null)
returns table (
  categoria text,
  titulo text,
  descricao text,
  quantidade bigint,
  quantidade_critica bigint,
  prioridade integer,
  rota text
)
language sql stable security definer
set search_path = public
as $$
  with chamados_resumo as (
    select
      count(*)::bigint as total,
      count(*) filter (where c.prazo_resposta is not null and c.prazo_resposta < now())::bigint as criticos
    from chamados c
    where public.is_staff()
      and c.tenant_id = public.current_tenant_id()
      and c.situacao in ('aberto', 'em_andamento')
  ),
  titulos_resumo as (
    select
      count(*)::bigint as total,
      count(*) filter (where t.data_vencimento < current_date)::bigint as criticos
    from titulos t
    left join matriculas m on m.id = t.matricula_id
    where public.is_staff()
      and t.tenant_id = public.current_tenant_id()
      and t.situacao = 'aberto'
      and (p_unidade_id is null or m.unidade_id = p_unidade_id)
  ),
  frequencia_resumo as (
    select
      count(*)::bigint as total,
      count(*)::bigint as criticos
    from frequencia_consolidada f
    left join matriculas m on m.usuario_id = f.usuario_id
      and m.turma_id = f.turma_id
      and m.tenant_id = f.tenant_id
    where public.is_staff()
      and f.tenant_id = public.current_tenant_id()
      and f.percentual_frequencia < 75
      and (p_unidade_id is null or m.unidade_id = p_unidade_id)
  ),
  documentos_resumo as (
    select
      count(*)::bigint as total,
      count(*) filter (where d.created_at < now() - interval '72 hours')::bigint as criticos
    from documentos d
    left join matriculas m on m.id = d.matricula_id
    where public.is_staff()
      and d.tenant_id = public.current_tenant_id()
      and d.situacao = 'pendente'
      and (p_unidade_id is null or m.unidade_id = p_unidade_id)
  )
  select 'chamados', 'Chamados vencendo',
    case when r.criticos > 0 then r.criticos || ' fora do prazo de resposta' else 'Nenhum chamado fora do prazo' end,
    r.total, r.criticos,
    case when r.criticos > 0 then 1 when r.total > 0 then 2 else 4 end,
    'chamados'
  from chamados_resumo r
  union all
  select 'financeiro', 'Mensalidades atrasadas',
    case when r.criticos > 0 then r.criticos || ' mensalidade(s) vencida(s)' else 'Nenhuma mensalidade vencida' end,
    r.total, r.criticos,
    case when r.criticos > 0 then 1 when r.total > 0 then 3 else 4 end,
    'financeiro'
  from titulos_resumo r
  union all
  select 'frequencia', 'Alunos com frequência baixa',
    case when r.criticos > 0 then r.criticos || ' abaixo de 75%' else 'Todos dentro do mínimo de 75%' end,
    r.total, r.criticos,
    case when r.criticos > 0 then 1 else 4 end,
    'alunos'
  from frequencia_resumo r
  union all
  select 'documentos', 'Documentos aguardando análise',
    case when r.criticos > 0 then r.criticos || ' há mais de 72 horas na fila' else 'Nenhum documento fora do SLA' end,
    r.total, r.criticos,
    case when r.criticos > 0 then 2 when r.total > 0 then 3 else 4 end,
    'alunos'
  from documentos_resumo r
  order by prioridade, categoria;
$$;

revoke all on function public.prioridades_do_dia(uuid) from public;
grant execute on function public.prioridades_do_dia(uuid) to authenticated;

-- Verificação opcional:
-- select * from public.prioridades_do_dia(null);
-- ============================================================
