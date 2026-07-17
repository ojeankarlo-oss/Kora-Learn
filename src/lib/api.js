// ============================================================
// KORA LEARN — Camada de dados v2 (casa com a migration 001)
// Salvar em: src/lib/api.js
// ============================================================
import { supabase } from "./supabaseClient";

/* ---------------- AUTENTICACAO ---------------- */

export async function cadastrarNovaConta(email, senha) {
  const { data, error } = await supabase.auth.signUp({ email, password: senha });
  if (error) throw error;
  return data; // data.session pode vir nulo se o projeto exigir confirmação de e-mail
}

export async function meuStatusOnboarding() {
  const { data, error } = await supabase.rpc("meu_status_onboarding");
  if (error) throw error;
  return data; // { tem_tenant, email }
}

export async function criarMinhaEscola({ nomeEscola, slug, nomeGestor }) {
  const { data, error } = await supabase.rpc("criar_minha_escola", {
    p_nome_escola: nomeEscola,
    p_slug: slug,
    p_nome_gestor: nomeGestor,
  });
  if (error) throw error; // error.message já vem em português (RAISE EXCEPTION da função)
  return data; // { tenant_id, slug, usuario_id }
}

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
      id, situacao, unidade_id,
      unidade:unidades ( id, nome ),
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

export async function criarPreMatricula({ tenantId, cursoId, nome, email, telefone, origem = "site", unidadeId = null }) {
  const { error } = await supabase.from("leads").insert({
    tenant_id: tenantId,
    curso_id: cursoId ?? null,
    unidade_id: unidadeId ?? null,
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

export async function listarLeads(unidadeId) {
  let query = supabase
    .from("leads")
    .select("id, nome, email, telefone, origem, situacao, created_at, unidade_id, curso:cursos(nome), unidade:unidades(id, nome)")
    .order("created_at", { ascending: false })
    .limit(50);
  if (unidadeId) query = query.eq("unidade_id", unidadeId);
  const { data, error } = await query;
  if (error) throw error;
  return data ?? [];
}

export async function listarMatriculas(unidadeId) {
  let query = supabase
    .from("matriculas")
    .select("id, situacao, data_matricula, created_at, unidade_id, aluno:usuarios(id, nome, email, telefone), curso:cursos(id, nome), unidade:unidades(id, nome)")
    .order("created_at", { ascending: false })
    .limit(200);
  if (unidadeId) query = query.eq("unidade_id", unidadeId);
  const { data, error } = await query;
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
    unidade_id: lead?.unidade_id ?? null,
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

/* ---------------- TENANT (white-label) ---------------- */

export async function obterTenantPublico(slug) {
  const { data, error } = await supabase.rpc("obter_tenant_publico", { p_slug: slug });
  if (error) throw error;
  return data; // jsonb ou null
}

export async function meuTenant() {
  const { data, error } = await supabase
    .from("tenants")
    .select("id, nome, slug, logo_url, config")
    .single();
  if (error) throw error;
  return data;
}

export async function salvarConfigTenant({ nome, logo_url, config }) {
  const atual = await meuTenant();
  const { error } = await supabase
    .from("tenants")
    .update({
      nome: nome ?? atual.nome,
      logo_url: logo_url ?? atual.logo_url,
      config: { ...(atual.config || {}), ...(config || {}) },
    })
    .eq("id", atual.id);
  if (error) throw error;
}


/* ---------------- UNIDADES / POLOS ---------------- */

export async function listarUnidades() {
  const { data, error } = await supabase
    .from("unidades")
    .select("id, nome, cidade, estado, pais, ativo")
    .order("nome");
  if (error) throw error;
  return data ?? [];
}

export async function criarUnidade({ nome, cidade, estado, pais = "BR" }) {
  const perfil = await meuPerfil();
  const { error } = await supabase.from("unidades").insert({
    tenant_id: perfil.tenant_id, nome, cidade, estado, pais,
  });
  if (error) throw error;
}

export async function alternarUnidade(unidadeId, ativo) {
  const { error } = await supabase.from("unidades").update({ ativo }).eq("id", unidadeId);
  if (error) throw error;
}

export async function listarUnidadesPublico(tenantId) {
  const { data, error } = await supabase.rpc("listar_unidades_publico", { p_tenant_id: tenantId });
  if (error) throw error;
  return data ?? [];
}

/* ---------------- CONTRATO DE MATRICULA ---------------- */

export async function contratoAtivo() {
  const { data, error } = await supabase
    .from("contratos")
    .select("id, corpo_md, versao, ativo")
    .eq("ativo", true)
    .order("versao", { ascending: false })
    .limit(1)
    .maybeSingle();
  if (error) throw error;
  return data ?? null;
}

export async function salvarContrato(corpo_md) {
  const perfil = await meuPerfil();

  const { data: atual } = await supabase
    .from("contratos")
    .select("versao")
    .order("versao", { ascending: false })
    .limit(1)
    .maybeSingle();
  const novaVersao = (Number(atual?.versao) || 0) + 1;

  const { error: errDesativar } = await supabase
    .from("contratos")
    .update({ ativo: false })
    .eq("tenant_id", perfil.tenant_id)
    .eq("ativo", true);
  if (errDesativar) throw errDesativar;

  const { error: errInserir } = await supabase.from("contratos").insert({
    tenant_id: perfil.tenant_id,
    corpo_md,
    versao: novaVersao,
    ativo: true,
  });
  if (errInserir) throw errInserir;
}

/* ---------------- ACEITES (CONTRATO / LGPD) ---------------- */

export async function registrarAceite({ tipo, contratoId, versao, hash, matriculaId }) {
  const perfil = await meuPerfil();
  const { error } = await supabase.from("aceites").insert({
    tenant_id: perfil.tenant_id,
    usuario_id: perfil.id,
    tipo,
    contrato_id: contratoId ?? null,
    matricula_id: matriculaId ?? null,
    versao: String(versao),
    hash_conteudo: hash,
    user_agent: navigator.userAgent,
  });
  // Ignora erro de duplicidade (constraint unique de aceite ja registrado)
  if (error && error.code !== "23505") throw error;
}

export async function meusAceites() {
  const perfil = await meuPerfil();
  const { data, error } = await supabase
    .from("aceites")
    .select("id, tipo, versao, contrato_id, aceito_em")
    .eq("usuario_id", perfil.id)
    .order("aceito_em", { ascending: false });
  if (error) throw error;
  return data ?? [];
}

/* ---------------- DOCUMENTOS ---------------- */

export async function enviarDocumento({ usuarioId, tenantId, matriculaId, tipo, file }) {
  const path = `${tenantId}/${usuarioId}/${Date.now()}_${file.name}`;
  const { error: errUpload } = await supabase.storage
    .from("documentos")
    .upload(path, file, { upsert: false });
  if (errUpload) throw errUpload;

  const { error } = await supabase.from("documentos").insert({
    tenant_id: tenantId,
    usuario_id: usuarioId,
    matricula_id: matriculaId ?? null,
    tipo,
    nome_arquivo: file.name,
    storage_path: path,
    situacao: "pendente",
    motivo: null,
  });
  if (error) throw error;
}

export async function meusDocumentos(usuarioId) {
  const { data, error } = await supabase
    .from("documentos")
    .select("id, tipo, nome_arquivo, storage_path, situacao, motivo, created_at")
    .eq("usuario_id", usuarioId)
    .order("created_at", { ascending: false });
  if (error) throw error;
  return data ?? [];
}

export async function documentosDoTenant() {
  const { data, error } = await supabase
    .from("documentos")
    .select("id, tipo, nome_arquivo, storage_path, situacao, motivo, created_at, usuario:usuarios(id, nome, email)")
    .order("created_at", { ascending: false });
  if (error) throw error;
  const ordem = { pendente: 0, reprovado: 1, aprovado: 2 };
  return (data ?? []).slice().sort((a, b) => (ordem[a.situacao] ?? 9) - (ordem[b.situacao] ?? 9));
}

export async function avaliarDocumento(id, situacao, motivo) {
  const { error } = await supabase
    .from("documentos")
    .update({ situacao, motivo: motivo ?? null })
    .eq("id", id);
  if (error) throw error;
}

export async function urlDocumento(storage_path) {
  const { data, error } = await supabase.storage
    .from("documentos")
    .createSignedUrl(storage_path, 300);
  if (error) throw error;
  return data.signedUrl;
}

/* ---------------- RH (colaboradores) ---------------- */

// Lista colaboradores. Se souPerfilGestor=true, inclui salario (tabela completa);
// senao usa a view colaboradores_sem_salario, que nao possui a coluna salario_centavos.
export async function listarColaboradores({ souPerfilGestor, unidadeId, busca } = {}) {
  const tabela = souPerfilGestor ? "colaboradores" : "colaboradores_sem_salario";
  let query = supabase
    .from(tabela)
    .select("*")
    .order("nome", { ascending: true })
    .limit(300);
  if (unidadeId) query = query.eq("unidade_id", unidadeId);
  if (busca) query = query.ilike("nome", `%${busca}%`);
  const { data, error } = await query;
  if (error) throw error;
  return data ?? [];
}

export async function criarColaborador(dados) {
  const { data, error } = await supabase.from("colaboradores").insert(dados).select().single();
  if (error) throw error;
  return data;
}

export async function atualizarColaborador(id, dados) {
  const { data, error } = await supabase.from("colaboradores").update(dados).eq("id", id).select().single();
  if (error) throw error;
  return data;
}

export async function desligarColaborador(id, dataDesligamento) {
  const { data, error } = await supabase
    .from("colaboradores")
    .update({ situacao: "desligado", data_desligamento: dataDesligamento })
    .eq("id", id)
    .select()
    .single();
  if (error) throw error;
  return data;
}

export async function reativarColaborador(id) {
  const { data, error } = await supabase
    .from("colaboradores")
    .update({ situacao: "ativo", data_desligamento: null })
    .eq("id", id)
    .select()
    .single();
  if (error) throw error;
  return data;
}

/* ---------------- TURMAS / PROFESSORES / CHAMADA / FREQUENCIA ---------------- */

export async function listarVinculosProfessorTurma() {
  const { data, error } = await supabase
    .from("professores_turmas")
    .select("id, usuario_id, turma_id, professor:usuarios(id, nome), turma:turmas(id, nome)")
    .order("turma_id");
  if (error) throw error;
  return data ?? [];
}

// Usuarios com perfil 'professor', para o dropdown de vinculo.
export async function listarProfessores() {
  const { data, error } = await supabase
    .from("usuarios")
    .select("id, nome, email")
    .eq("perfil", "professor")
    .order("nome");
  if (error) throw error;
  return data ?? [];
}

// Turmas ativas do tenant, para o dropdown de vinculo.
export async function listarTurmasAtivas() {
  const { data, error } = await supabase
    .from("turmas")
    .select("id, nome")
    .eq("ativa", true)
    .order("nome");
  if (error) throw error;
  return data ?? [];
}

export async function vincularProfessorTurma(usuarioId, turmaId) {
  const perfil = await meuPerfil();
  const { error } = await supabase.from("professores_turmas").insert({
    tenant_id: perfil.tenant_id,
    usuario_id: usuarioId,
    turma_id: turmaId,
  });
  if (error) throw error;
}

export async function desvincularProfessorTurma(vinculoId) {
  const { error } = await supabase.from("professores_turmas").delete().eq("id", vinculoId);
  if (error) throw error;
}

// Junta cada turma com a primeira disciplina do seu curso (MVP: 1 disciplina por turma).
function montarTurmasComDisciplina(turmas) {
  return (turmas ?? []).filter(Boolean).map((t) => {
    const disciplinas = (t.curso?.disciplinas ?? []).slice().sort((a, b) => (a.ordem ?? 0) - (b.ordem ?? 0));
    return {
      id: t.id,
      nome: t.nome,
      disciplinaId: disciplinas[0]?.id ?? null,
      disciplinaNome: disciplinas[0]?.nome ?? "",
    };
  });
}

// Turmas as quais o usuario logado tem acesso para lancar presenca.
// Gestor/super_admin: todas as turmas ativas do tenant. Demais perfis: so as vinculadas via professores_turmas.
export async function minhasTurmasParaChamada() {
  const perfil = await meuPerfil();
  const souStaffGestor = perfil?.perfil === "gestor" || perfil?.perfil === "super_admin";

  if (souStaffGestor) {
    const { data, error } = await supabase
      .from("turmas")
      .select("id, nome, curso:cursos(id, nome, disciplinas(id, nome, ordem))")
      .eq("ativa", true)
      .order("nome");
    if (error) throw error;
    return montarTurmasComDisciplina(data);
  }

  const { data, error } = await supabase
    .from("professores_turmas")
    .select("turma:turmas(id, nome, curso:cursos(id, nome, disciplinas(id, nome, ordem)))")
    .eq("usuario_id", perfil.id);
  if (error) throw error;
  return montarTurmasComDisciplina((data ?? []).map((v) => v.turma));
}

export async function criarRegistroAula({ turmaId, disciplinaId, dataAula, tipo, ambiente, observacao }) {
  const perfil = await meuPerfil();
  const { data, error } = await supabase
    .from("registros_aula")
    .insert({
      tenant_id: perfil.tenant_id,
      turma_id: turmaId,
      disciplina_id: disciplinaId,
      professor_id: perfil.id,
      data_aula: dataAula,
      tipo,
      ambiente: ambiente || null,
      observacao: observacao || null,
    })
    .select()
    .single();
  if (error) throw error;
  return data;
}

export async function alunosDaTurma(turmaId) {
  const { data, error } = await supabase
    .from("matriculas")
    .select("usuario:usuarios(id, nome)")
    .eq("turma_id", turmaId)
    .eq("situacao", "ativa");
  if (error) throw error;
  return (data ?? []).map((m) => m.usuario).filter(Boolean);
}

// listaPresencas: [{ usuario_id, situacao }, ...]
export async function lancarPresencas(registroAulaId, listaPresencas) {
  const perfil = await meuPerfil();
  const registros = (listaPresencas ?? []).map((p) => ({
    tenant_id: perfil.tenant_id,
    registro_aula_id: registroAulaId,
    usuario_id: p.usuario_id,
    situacao: p.situacao,
  }));
  const { error } = await supabase
    .from("presencas")
    .upsert(registros, { onConflict: "registro_aula_id,usuario_id" });
  if (error) throw error;
}

export async function historicoAulasTurma(turmaId) {
  const { data, error } = await supabase
    .from("registros_aula")
    .select("id, data_aula, tipo, ambiente, observacao, presencas(situacao)")
    .eq("turma_id", turmaId)
    .order("data_aula", { ascending: false })
    .limit(50);
  if (error) throw error;
  return data ?? [];
}

// Enriquece a frequencia_consolidada com nome de turma/disciplina (a view so tem os ids).
async function enriquecerFrequencia(linhas) {
  const turmaIds = [...new Set(linhas.map((l) => l.turma_id).filter(Boolean))];
  const disciplinaIds = [...new Set(linhas.map((l) => l.disciplina_id).filter(Boolean))];

  const [turmasRes, disciplinasRes] = await Promise.all([
    turmaIds.length ? supabase.from("turmas").select("id, nome").in("id", turmaIds) : Promise.resolve({ data: [] }),
    disciplinaIds.length ? supabase.from("disciplinas").select("id, nome").in("id", disciplinaIds) : Promise.resolve({ data: [] }),
  ]);

  const turmaPorId = Object.fromEntries((turmasRes.data ?? []).map((t) => [t.id, t.nome]));
  const disciplinaPorId = Object.fromEntries((disciplinasRes.data ?? []).map((d) => [d.id, d.nome]));

  return linhas.map((l) => ({
    ...l,
    turma_nome: turmaPorId[l.turma_id] ?? "Turma",
    disciplina_nome: disciplinaPorId[l.disciplina_id] ?? "Disciplina",
  }));
}

export async function minhaFrequencia() {
  const perfil = await meuPerfil();
  const { data, error } = await supabase
    .from("frequencia_consolidada")
    .select("*")
    .eq("usuario_id", perfil.id);
  if (error) throw error;
  return enriquecerFrequencia(data ?? []);
}

export async function frequenciaDoAluno(usuarioId) {
  const { data, error } = await supabase
    .from("frequencia_consolidada")
    .select("*")
    .eq("usuario_id", usuarioId);
  if (error) throw error;
  return data ?? [];
}

/* ---------------- FINANCEIRO (titulos) ---------------- */

// Titulos do aluno logado (RLS garante que retorna apenas os proprios).
export async function meusTitulos() {
  const { data, error } = await supabase
    .from("titulos")
    .select("id, descricao, valor_centavos, data_vencimento, data_pagamento, situacao, forma_pagamento, observacao")
    .order("data_vencimento", { ascending: true });
  if (error) throw error;
  return data ?? [];
}

// Titulos do tenant (staff). RLS restringe ao tenant do usuario.
export async function listarTitulos({ situacao, busca } = {}) {
  let query = supabase
    .from("titulos")
    .select("id, descricao, valor_centavos, data_vencimento, data_pagamento, situacao, forma_pagamento, observacao, usuario_id, matricula_id, aluno:usuarios!titulos_usuario_id_fkey(id, nome, email)")
    .order("data_vencimento", { ascending: true })
    .limit(300);
  if (situacao) query = query.eq("situacao", situacao);
  const { data, error } = await query;
  if (error) throw error;
  let lista = data ?? [];
  const termo = (busca ?? "").trim().toLowerCase();
  if (termo) {
    lista = lista.filter((t) => (t.aluno?.nome ?? "").toLowerCase().includes(termo));
  }
  return lista;
}

// Gera N titulos de mensalidade em um unico insert.
export async function gerarMensalidades({ matriculaId, usuarioId, tenantId, cursoNome, valorCentavos, parcelas, diaVencimento, primeiraCompetencia }) {
  const n = Number(parcelas) || 0;
  const dia = Number(diaVencimento) || 1;
  // primeiraCompetencia no formato "AAAA-MM" (input type="month").
  const [anoBase, mesBase] = String(primeiraCompetencia).split("-").map((v) => parseInt(v, 10));
  const registros = [];
  for (let k = 0; k < n; k++) {
    const d = new Date(anoBase, mesBase - 1 + k, 1);
    const ano = d.getFullYear();
    const mes = d.getMonth(); // 0-11
    const ultimoDia = new Date(ano, mes + 1, 0).getDate();
    const diaFinal = Math.min(dia, ultimoDia);
    const venc = `${ano}-${String(mes + 1).padStart(2, "0")}-${String(diaFinal).padStart(2, "0")}`;
    registros.push({
      usuario_id: usuarioId,
      tenant_id: tenantId,
      matricula_id: matriculaId,
      descricao: `Mensalidade ${k + 1}/${n} — ${cursoNome}`,
      valor_centavos: valorCentavos,
      data_vencimento: venc,
      situacao: "aberto",
    });
  }
  const { data, error } = await supabase.from("titulos").insert(registros).select();
  if (error) throw error;
  return data ?? [];
}

export async function criarTituloAvulso({ usuarioId, tenantId, matriculaId, descricao, valorCentavos, dataVencimento }) {
  const { data, error } = await supabase
    .from("titulos")
    .insert([{
      usuario_id: usuarioId,
      tenant_id: tenantId,
      matricula_id: matriculaId ?? null,
      descricao,
      valor_centavos: valorCentavos,
      data_vencimento: dataVencimento,
      situacao: "aberto",
    }])
    .select()
    .single();
  if (error) throw error;
  return data;
}

// Baixa manual: marca como pago com a data de hoje.
export async function darBaixaTitulo(tituloId, formaPagamento) {
  const hoje = new Date().toISOString().slice(0, 10);
  const { data, error } = await supabase
    .from("titulos")
    .update({ situacao: "pago", data_pagamento: hoje, forma_pagamento: formaPagamento })
    .eq("id", tituloId)
    .select()
    .single();
  if (error) throw error;
  return data;
}

export async function cancelarTitulo(tituloId, observacao) {
  const { data, error } = await supabase
    .from("titulos")
    .update({ situacao: "cancelado", observacao: observacao ?? null })
    .eq("id", tituloId)
    .select()
    .single();
  if (error) throw error;
  return data;
}

// KPIs do mes corrente (somas em centavos + contagens). RLS restringe ao tenant.
export async function kpisFinanceiro() {
  const agora = new Date();
  const ano = agora.getFullYear();
  const mes = agora.getMonth();
  const primeiroDiaMes = `${ano}-${String(mes + 1).padStart(2, "0")}-01`;
  const ultimoDiaMes = `${ano}-${String(mes + 1).padStart(2, "0")}-${String(new Date(ano, mes + 1, 0).getDate()).padStart(2, "0")}`;
  const hoje = agora.toISOString().slice(0, 10);

  const { data, error } = await supabase
    .from("titulos")
    .select("valor_centavos, data_vencimento, data_pagamento, situacao");
  if (error) throw error;
  const lista = data ?? [];

  const kpis = {
    aReceberMes: { total: 0, qtd: 0 },
    recebidoMes: { total: 0, qtd: 0 },
    vencidos: { total: 0, qtd: 0 },
  };
  for (const t of lista) {
    if (t.situacao === "aberto" && t.data_vencimento >= primeiroDiaMes && t.data_vencimento <= ultimoDiaMes) {
      kpis.aReceberMes.total += t.valor_centavos || 0;
      kpis.aReceberMes.qtd += 1;
    }
    if (t.situacao === "pago" && t.data_pagamento && t.data_pagamento >= primeiroDiaMes && t.data_pagamento <= ultimoDiaMes) {
      kpis.recebidoMes.total += t.valor_centavos || 0;
      kpis.recebidoMes.qtd += 1;
    }
    if (t.situacao === "aberto" && t.data_vencimento < hoje) {
      kpis.vencidos.total += t.valor_centavos || 0;
      kpis.vencidos.qtd += 1;
    }
  }
  return kpis;
}
