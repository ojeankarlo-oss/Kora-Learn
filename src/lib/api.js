// ============================================================
// KORA LEARN — Camada de dados v2 (casa com a migration 001)
// Salvar em: src/lib/api.js
// ============================================================
import { supabase } from "./supabaseClient";

/* ---------------- AUTENTICACAO ---------------- */

export async function entrarComEmail(email, senha) {
  const { data, error } = await supabase.auth.signInWithPassword({
    email,
    password: senha,
  });
  if (error) throw error;
  return data.user;
}

export async function sair() {
  await supabase.auth.signOut();
}

// Perfil de aplicacao (tabela usuarios) do usuario logado
export async function meuPerfil() {
  const { data: { user } } = await supabase.auth.getUser();
  if (!user) return null;
  const { data, error } = await supabase
    .from("usuarios")
    .select("id, tenant_id, perfil, nome, email, avatar_url")
    .eq("auth_user_id", user.id)
    .single();
  if (error) throw error;
  return data;
}

/* ---------------- CATALOGO + PROGRESSO (ALUNO) ---------------- */

export async function meusCursos(usuarioId) {
  const { data, error } = await supabase
    .from("matriculas")
    .select(`
      id, situacao,
      curso:cursos (
        id, nome, imagem_url,
        disciplinas (
          id, nome, ordem,
          aulas (
            id, titulo, tipo, url_video, duracao_seg, ordem,
            progresso:progresso_aulas ( concluida, percentual_assistido )
          )
        )
      )
    `)
    .eq("usuario_id", usuarioId)
    .eq("situacao", "ativa");
  if (error) throw error;
  return data ?? [];
}

export async function concluirAula(usuarioId, tenantId, aulaId) {
  const { error } = await supabase.from("progresso_aulas").upsert(
    {
      usuario_id: usuarioId,
      tenant_id: tenantId,
      aula_id: aulaId,
      percentual_assistido: 100,
      concluida: true,
      data_conclusao: new Date().toISOString(),
    },
    { onConflict: "usuario_id,aula_id" }
  );
  if (error) throw error;
}

/* ---------------- PRE-MATRICULA PUBLICA ---------------- */

export async function criarPreMatricula({ tenantId, cursoId, nome, email, telefone, origem = "site" }) {
  const { error } = await supabase.from("leads").insert({
    tenant_id: tenantId,
    curso_id: cursoId ?? null,
    nome,
    email,
    telefone,
    origem,
  });
  if (error) throw error;
}

/* ---------------- PAINEL DO GESTOR ---------------- */

export async function kpisDoTenant() {
  const hoje = new Date().toISOString().slice(0, 10);
  const inicioMes = hoje.slice(0, 8) + "01";

  const [ativos, matriculasHoje, leadsNovos] = await Promise.all([
    supabase.from("matriculas").select("id", { count: "exact", head: true }).eq("situacao", "ativa"),
    supabase.from("matriculas").select("id", { count: "exact", head: true }).gte("data_matricula", hoje),
    supabase.from("leads").select("id", { count: "exact", head: true }).eq("situacao", "novo").gte("created_at", inicioMes),
  ]);

  return {
    alunosAtivos: ativos.count ?? 0,
    matriculasHoje: matriculasHoje.count ?? 0,
    leadsNovosNoMes: leadsNovos.count ?? 0,
  };
}

export async function listarCursos() {
  const { data, error } = await supabase
    .from("cursos")
    .select("id, nome")
    .eq("ativo", true)
    .order("nome");
  if (error) throw error;
  return data ?? [];
}

export async function listarLeads() {
  const { data, error } = await supabase
    .from("leads")
    .select("id, nome, email, telefone, origem, situacao, created_at, curso:cursos(nome)")
    .order("created_at", { ascending: false })
    .limit(50);
  if (error) throw error;
  return data ?? [];
}

export async function listarMatriculas() {
  const { data, error } = await supabase
    .from("matriculas")
    .select("id, situacao, data_matricula, created_at, aluno:usuarios(id, nome, email, telefone), curso:cursos(id, nome)")
    .order("created_at", { ascending: false })
    .limit(200);
  if (error) throw error;
  return data ?? [];
}

export async function atualizarSituacaoMatricula(matriculaId, situacao) {
  const { error } = await supabase
    .from("matriculas")
    .update({ situacao })
    .eq("id", matriculaId);
  if (error) throw error;
}

export async function listarCursosPublico() {
  const { data, error } = await supabase
    .from("cursos")
    .select("id, nome")
    .eq("ativo", true)
    .order("nome");
  if (error) throw error;
  return data ?? [];
}

export async function primeiroAcesso(email, senha) {
  const { data, error } = await supabase.auth.signUp({ email, password: senha });
  if (error) throw error;
  const { data: vinculado, error: e2 } = await supabase.rpc("vincular_minha_conta");
  if (e2) throw e2;
  return { user: data.user, vinculado, needsConfirmation: !!data.user && !data.session };
}

// Converter lead em aluno matriculado
export async function converterLead(lead, tenantId, cursoId, turmaId = null) {
  const { data: novoAluno, error: e1 } = await supabase
    .from("usuarios")
    .insert({
      tenant_id: tenantId,
      perfil: "aluno",
      nome: lead.nome,
      email: lead.email,
      telefone: lead.telefone,
    })
    .select()
    .single();
  if (e1) throw e1;

  const { error: e2 } = await supabase.from("matriculas").insert({
    tenant_id: tenantId,
    usuario_id: novoAluno.id,
    curso_id: lead?.curso_id ?? cursoId,
    turma_id: turmaId,
    origem: "self_service",
  });
  if (e2) throw e2;

  const { error: e3 } = await supabase
    .from("leads")
    .update({ situacao: "convertido" })
    .eq("id", lead.id);
  if (e3) throw e3;

  return novoAluno;
}
