import React, { useCallback, useEffect, useRef, useState } from "react";
import {
  BookOpen, Plus, Pencil, Trash2, RefreshCw, AlertTriangle, Loader2, X,
  ArrowLeft, Archive, ArchiveRestore, Link2, Upload, Video, FileText,
  HelpCircle, Radio, ChevronRight, Eye,
} from "lucide-react";
import {
  listarCursosDoGestor, criarCurso, atualizarCurso, arquivarCurso, reativarCurso,
  listarDisciplinasDoCurso, criarDisciplina, atualizarDisciplina, removerDisciplina,
  listarAulasDaDisciplina, criarAula, atualizarAula, removerAula,
  enviarArquivoConteudoCurso, urlConteudoCurso, aulaUsaArquivoStorage,
} from "./lib/api";

const brl = new Intl.NumberFormat("pt-BR", { style: "currency", currency: "BRL" });

const NIVEIS = [
  { value: "livre", label: "Livre" },
  { value: "tecnico", label: "Técnico" },
  { value: "graduacao", label: "Graduação" },
  { value: "pos", label: "Pós" },
  { value: "eja", label: "EJA" },
];

const TIPOS_AULA = [
  { value: "video", label: "Vídeo", Icon: Video },
  { value: "pdf", label: "PDF", Icon: FileText },
  { value: "quiz", label: "Quiz", Icon: HelpCircle },
  { value: "ao_vivo", label: "Ao vivo", Icon: Radio },
];

const TAMANHO_MAXIMO_CONTEUDO = 200 * 1024 * 1024; // 200MB

function rotuloNivel(v) {
  return NIVEIS.find((n) => n.value === v)?.label || v || "—";
}

function infoTipoAula(v) {
  return TIPOS_AULA.find((t) => t.value === v) || { label: v || "—", Icon: FileText };
}

// Converte "497,00" ou "0" em centavos. Retorna null se vazio, NaN se inválido.
function valorParaCentavos(texto) {
  const t = String(texto ?? "").trim();
  if (!t) return null;
  const limpo = t.replace(/\./g, "").replace(",", ".");
  const num = Number(limpo);
  if (!isFinite(num) || num < 0) return NaN;
  return Math.round(num * 100);
}

function formatarCentavos(centavos) {
  if (centavos == null) return "—";
  return centavos === 0 ? "Gratuito" : brl.format(centavos / 100);
}

function formatarDuracao(seg) {
  if (!seg) return "—";
  const min = Math.floor(seg / 60);
  const s = seg % 60;
  if (min === 0) return `${s}s`;
  return s ? `${min}min${String(s).padStart(2, "0")}s` : `${min} min`;
}

/* ============================================================
   NÍVEL 1 — CURSOS
   ============================================================ */

function CursoModal({ inicial, salvando, onSalvar, onFechar, T }) {
  const [nome, setNome] = useState(inicial?.nome || "");
  const [descricao, setDescricao] = useState(inicial?.descricao || "");
  const [nivel, setNivel] = useState(inicial?.nivel || "livre");
  const [area, setArea] = useState(inicial?.area || "");
  const [cargaHoraria, setCargaHoraria] = useState(inicial?.carga_horaria ?? "");
  const [precoTexto, setPrecoTexto] = useState(
    inicial?.preco_centavos != null ? String(inicial.preco_centavos / 100).replace(".", ",") : ""
  );
  const [imagemUrl, setImagemUrl] = useState(inicial?.imagem_url || "");
  const [erro, setErro] = useState("");

  const corLine = T?.line || "#DDE5E1";
  const corMuted = T?.muted || "#5C6E67";
  const corInk = T?.ink || "#10201A";
  const corForest = T?.forest || "#17604A";
  const corDanger = T?.danger || "#C24A3F";

  const rotulo = { display: "block", fontSize: 12, fontWeight: 600, color: corMuted, marginBottom: 4 };
  const campo = { width: "100%", boxSizing: "border-box", padding: "10px 12px", borderRadius: 10, border: `1.5px solid ${corLine}`, fontSize: 14 };

  const handleSubmit = (e) => {
    e.preventDefault();
    setErro("");
    if (!nome.trim()) { setErro("Informe o nome do curso."); return; }

    const precoCentavos = valorParaCentavos(precoTexto);
    if (Number.isNaN(precoCentavos)) { setErro("Informe um preço válido (ex.: 497,00) ou 0 para gratuito."); return; }

    onSalvar({
      nome: nome.trim(),
      descricao: descricao.trim() || null,
      nivel,
      area: area.trim() || null,
      carga_horaria: cargaHoraria !== "" ? Number(cargaHoraria) : null,
      preco_centavos: precoCentavos,
      imagem_url: imagemUrl.trim() || null,
    });
  };

  return (
    <div onClick={onFechar} style={{ position: "fixed", inset: 0, background: "rgba(16,32,26,0.45)", display: "flex", alignItems: "center", justifyContent: "center", zIndex: 60, padding: 16 }}>
      <div onClick={(e) => e.stopPropagation()} style={{ width: "100%", maxWidth: 560, maxHeight: "85vh", overflowY: "auto", background: "#fff", borderRadius: 16, padding: 20 }}>
        <div style={{ display: "flex", justifyContent: "space-between", alignItems: "center", marginBottom: 16 }}>
          <h2 style={{ fontSize: 16, fontWeight: 800, color: corInk, margin: 0 }}>{inicial ? "Editar curso" : "Novo curso"}</h2>
          <button onClick={onFechar} style={{ background: "none", border: "none", cursor: "pointer", padding: 4 }}><X size={18} color={corMuted} /></button>
        </div>
        <form onSubmit={handleSubmit}>
          <div style={{ marginBottom: 12 }}>
            <label style={rotulo}>Nome *</label>
            <input style={campo} value={nome} onChange={(e) => setNome(e.target.value)} placeholder="Ex.: Excel Avançado" />
          </div>
          <div style={{ marginBottom: 12 }}>
            <label style={rotulo}>Descrição</label>
            <textarea style={{ ...campo, minHeight: 70, fontFamily: "inherit" }} value={descricao} onChange={(e) => setDescricao(e.target.value)} placeholder="Sobre o que é este curso" />
          </div>
          <div style={{ display: "grid", gridTemplateColumns: "1fr 1fr", gap: 10, marginBottom: 12 }}>
            <div>
              <label style={rotulo}>Nível</label>
              <select style={campo} value={nivel} onChange={(e) => setNivel(e.target.value)}>
                {NIVEIS.map((n) => <option key={n.value} value={n.value}>{n.label}</option>)}
              </select>
            </div>
            <div>
              <label style={rotulo}>Área</label>
              <input style={campo} value={area} onChange={(e) => setArea(e.target.value)} placeholder="Ex.: Tecnologia" />
            </div>
          </div>
          <div style={{ display: "grid", gridTemplateColumns: "1fr 1fr", gap: 10, marginBottom: 12 }}>
            <div>
              <label style={rotulo}>Carga horária (horas)</label>
              <input type="number" min={0} style={campo} value={cargaHoraria} onChange={(e) => setCargaHoraria(e.target.value)} placeholder="40" />
            </div>
            <div>
              <label style={rotulo}>Preço</label>
              <input style={campo} value={precoTexto} onChange={(e) => setPrecoTexto(e.target.value)} placeholder="497,00 ou 0 p/ gratuito" inputMode="decimal" />
            </div>
          </div>
          <div style={{ marginBottom: 12 }}>
            <label style={rotulo}>URL da imagem de capa (opcional)</label>
            <input style={campo} value={imagemUrl} onChange={(e) => setImagemUrl(e.target.value)} placeholder="https://..." />
          </div>

          {erro && <div style={{ marginBottom: 12, padding: 10, borderRadius: 10, background: "#FBEFEC", color: corDanger, fontSize: 13, fontWeight: 500 }}>{erro}</div>}

          <div style={{ display: "flex", gap: 8, marginTop: 4 }}>
            <button type="submit" disabled={salvando}
              style={{ flex: 1, padding: "12px 14px", borderRadius: 12, border: "none", background: salvando ? corMuted : corForest, color: "#fff", fontWeight: 700, fontSize: 14, cursor: salvando ? "not-allowed" : "pointer" }}>
              {salvando ? "Salvando..." : inicial ? "Salvar alterações" : "Criar curso"}
            </button>
            <button type="button" onClick={onFechar}
              style={{ padding: "12px 18px", borderRadius: 12, border: `1px solid ${corLine}`, background: "none", color: corInk, fontWeight: 700, fontSize: 14, cursor: "pointer" }}>
              Cancelar
            </button>
          </div>
        </form>
      </div>
    </div>
  );
}

function NivelCursos({ T, toast, onAbrirCurso }) {
  const [cursos, setCursos] = useState(null);
  const [erro, setErro] = useState("");
  const [modalAberto, setModalAberto] = useState(false);
  const [editando, setEditando] = useState(null);
  const [salvando, setSalvando] = useState(false);
  const [processandoId, setProcessandoId] = useState(null);

  const corLine = T?.line || "#DDE5E1";
  const corMuted = T?.muted || "#5C6E67";
  const corInk = T?.ink || "#10201A";
  const corForest = T?.forest || "#17604A";
  const corDanger = T?.danger || "#C24A3F";

  const carregar = useCallback(async () => {
    try {
      setErro("");
      const data = await listarCursosDoGestor();
      setCursos(data);
    } catch (e) {
      console.error(e);
      setErro("Não foi possível carregar os cursos.");
      setCursos([]);
    }
  }, []);

  useEffect(() => { carregar(); }, [carregar]);

  const abrirCriar = () => { setEditando(null); setModalAberto(true); };
  const abrirEditar = (curso) => { setEditando(curso); setModalAberto(true); };
  const fecharModal = () => { if (salvando) return; setModalAberto(false); setEditando(null); };

  const salvar = async (dados) => {
    setSalvando(true);
    try {
      if (editando) {
        await atualizarCurso(editando.id, dados);
        toast?.("Curso atualizado ✓");
      } else {
        await criarCurso(dados);
        toast?.("Curso criado ✓");
      }
      setModalAberto(false);
      setEditando(null);
      await carregar();
    } catch (e) {
      console.error(e);
      toast?.("Erro ao salvar curso");
    } finally {
      setSalvando(false);
    }
  };

  const alternarArquivamento = async (curso) => {
    const acao = curso.ativo ? "Arquivar" : "Reativar";
    if (!window.confirm(`${acao} o curso "${curso.nome}"?`)) return;
    setProcessandoId(curso.id);
    try {
      if (curso.ativo) {
        await arquivarCurso(curso.id);
        toast?.("Curso arquivado — some do formulário público, mas continua aqui.");
      } else {
        await reativarCurso(curso.id);
        toast?.("Curso reativado ✓");
      }
      await carregar();
    } catch (e) {
      console.error(e);
      toast?.(`Erro ao ${acao.toLowerCase()} curso`);
    } finally {
      setProcessandoId(null);
    }
  };

  return (
    <div>
      <div style={{ display: "flex", justifyContent: "space-between", alignItems: "center", gap: 10, flexWrap: "wrap", marginBottom: 12 }}>
        <div style={{ display: "flex", alignItems: "center", gap: 8 }}>
          <BookOpen size={18} color={corForest} />
          <div style={{ fontSize: 15, fontWeight: 800, color: corInk }}>Cursos</div>
        </div>
        <button onClick={abrirCriar}
          style={{ display: "flex", alignItems: "center", gap: 6, background: corForest, color: "#fff", border: "none", borderRadius: 999, padding: "8px 14px", fontSize: 12, fontWeight: 700, cursor: "pointer" }}>
          <Plus size={14} /> Novo curso
        </button>
      </div>

      {erro ? (
        <div style={{ padding: 24, textAlign: "center", border: `1px solid ${corLine}`, borderRadius: 14 }}>
          <AlertTriangle size={26} color={corDanger} />
          <div style={{ fontSize: 13, color: corMuted, marginTop: 6 }}>{erro}</div>
          <button onClick={carregar}
            style={{ marginTop: 10, display: "inline-flex", alignItems: "center", gap: 6, background: corForest, color: "#fff", border: "none", borderRadius: 999, padding: "8px 16px", fontSize: 13, fontWeight: 700, cursor: "pointer" }}>
            <RefreshCw size={13} /> Tentar de novo
          </button>
        </div>
      ) : cursos === null ? (
        <div style={{ display: "flex", alignItems: "center", gap: 8, color: corMuted, fontSize: 13, padding: 24 }}>
          <Loader2 className="kl-spin" size={16} /> Carregando cursos...
        </div>
      ) : cursos.length === 0 ? (
        <div style={{ padding: 24, textAlign: "center", border: `1px solid ${corLine}`, borderRadius: 14 }}>
          <BookOpen size={26} color={corMuted} />
          <div style={{ fontSize: 13, color: corMuted, marginTop: 6 }}>Nenhum curso cadastrado ainda. Crie o primeiro curso da sua escola!</div>
        </div>
      ) : (
        <div style={{ border: `1px solid ${corLine}`, borderRadius: 14, overflow: "hidden" }}>
          {cursos.map((c, i) => {
            const ocupado = processandoId === c.id;
            return (
              <div key={c.id} style={{ padding: "12px 14px", borderTop: i ? `1px solid ${corLine}` : "none", display: "flex", justifyContent: "space-between", alignItems: "center", gap: 8, flexWrap: "wrap" }}>
                <button onClick={() => onAbrirCurso(c)}
                  style={{ display: "flex", alignItems: "center", gap: 6, background: "none", border: "none", cursor: "pointer", textAlign: "left", padding: 0 }}>
                  <div>
                    <div style={{ fontSize: 14, fontWeight: 700, color: corInk }}>{c.nome}</div>
                    <div style={{ fontSize: 12, color: corMuted }}>
                      {rotuloNivel(c.nivel)}{c.carga_horaria ? ` · ${c.carga_horaria}h` : ""} · {formatarCentavos(c.preco_centavos)}
                    </div>
                  </div>
                  <ChevronRight size={16} color={corMuted} />
                </button>
                <div style={{ display: "flex", alignItems: "center", gap: 8, flexWrap: "wrap" }}>
                  <span style={{ fontSize: 11, fontWeight: 700, padding: "4px 10px", borderRadius: 999, background: c.ativo ? "#EAF6F0" : (T?.paper || "#F1F4F2"), color: c.ativo ? (T?.success || "#2E8B63") : corMuted }}>
                    {c.ativo ? "Ativo" : "Arquivado"}
                  </span>
                  <button onClick={() => abrirEditar(c)} disabled={ocupado}
                    style={{ display: "flex", alignItems: "center", gap: 4, background: "none", border: `1px solid ${corLine}`, color: corInk, borderRadius: 10, padding: "6px 10px", fontSize: 12, fontWeight: 700, cursor: ocupado ? "not-allowed" : "pointer" }}>
                    <Pencil size={13} /> Editar
                  </button>
                  <button onClick={() => alternarArquivamento(c)} disabled={ocupado}
                    style={{ display: "flex", alignItems: "center", gap: 4, background: "none", border: `1px solid ${corLine}`, color: corInk, borderRadius: 10, padding: "6px 10px", fontSize: 12, fontWeight: 700, cursor: ocupado ? "not-allowed" : "pointer" }}>
                    {c.ativo ? <Archive size={13} /> : <ArchiveRestore size={13} />} {c.ativo ? "Arquivar" : "Reativar"}
                  </button>
                </div>
              </div>
            );
          })}
        </div>
      )}

      {modalAberto && (
        <CursoModal key={editando?.id || "novo"} inicial={editando} salvando={salvando} onSalvar={salvar} onFechar={fecharModal} T={T} />
      )}
    </div>
  );
}

/* ============================================================
   NÍVEL 2 — DISCIPLINAS
   ============================================================ */

function DisciplinaModal({ inicial, salvando, onSalvar, onFechar, T }) {
  const [nome, setNome] = useState(inicial?.nome || "");
  const [descricao, setDescricao] = useState(inicial?.descricao || "");
  const [cargaHoraria, setCargaHoraria] = useState(inicial?.carga_horaria ?? "");
  const [ordem, setOrdem] = useState(inicial?.ordem ?? 0);
  const [erro, setErro] = useState("");

  const corLine = T?.line || "#DDE5E1";
  const corMuted = T?.muted || "#5C6E67";
  const corInk = T?.ink || "#10201A";
  const corForest = T?.forest || "#17604A";
  const corDanger = T?.danger || "#C24A3F";

  const rotulo = { display: "block", fontSize: 12, fontWeight: 600, color: corMuted, marginBottom: 4 };
  const campo = { width: "100%", boxSizing: "border-box", padding: "10px 12px", borderRadius: 10, border: `1.5px solid ${corLine}`, fontSize: 14 };

  const handleSubmit = (e) => {
    e.preventDefault();
    setErro("");
    if (!nome.trim()) { setErro("Informe o nome da disciplina."); return; }
    onSalvar({
      nome: nome.trim(),
      descricao: descricao.trim() || null,
      carga_horaria: cargaHoraria !== "" ? Number(cargaHoraria) : null,
      ordem: ordem !== "" ? Number(ordem) : 0,
    });
  };

  return (
    <div onClick={onFechar} style={{ position: "fixed", inset: 0, background: "rgba(16,32,26,0.45)", display: "flex", alignItems: "center", justifyContent: "center", zIndex: 60, padding: 16 }}>
      <div onClick={(e) => e.stopPropagation()} style={{ width: "100%", maxWidth: 480, maxHeight: "85vh", overflowY: "auto", background: "#fff", borderRadius: 16, padding: 20 }}>
        <div style={{ display: "flex", justifyContent: "space-between", alignItems: "center", marginBottom: 16 }}>
          <h2 style={{ fontSize: 16, fontWeight: 800, color: corInk, margin: 0 }}>{inicial ? "Editar disciplina" : "Nova disciplina"}</h2>
          <button onClick={onFechar} style={{ background: "none", border: "none", cursor: "pointer", padding: 4 }}><X size={18} color={corMuted} /></button>
        </div>
        <form onSubmit={handleSubmit}>
          <div style={{ marginBottom: 12 }}>
            <label style={rotulo}>Nome *</label>
            <input style={campo} value={nome} onChange={(e) => setNome(e.target.value)} placeholder="Ex.: Fórmulas e Funções" />
          </div>
          <div style={{ marginBottom: 12 }}>
            <label style={rotulo}>Descrição</label>
            <textarea style={{ ...campo, minHeight: 60, fontFamily: "inherit" }} value={descricao} onChange={(e) => setDescricao(e.target.value)} placeholder="Opcional" />
          </div>
          <div style={{ display: "grid", gridTemplateColumns: "1fr 1fr", gap: 10, marginBottom: 12 }}>
            <div>
              <label style={rotulo}>Carga horária (horas)</label>
              <input type="number" min={0} style={campo} value={cargaHoraria} onChange={(e) => setCargaHoraria(e.target.value)} placeholder="8" />
            </div>
            <div>
              <label style={rotulo}>Ordem</label>
              <input type="number" min={0} style={campo} value={ordem} onChange={(e) => setOrdem(e.target.value)} />
            </div>
          </div>

          {erro && <div style={{ marginBottom: 12, padding: 10, borderRadius: 10, background: "#FBEFEC", color: corDanger, fontSize: 13, fontWeight: 500 }}>{erro}</div>}

          <div style={{ display: "flex", gap: 8, marginTop: 4 }}>
            <button type="submit" disabled={salvando}
              style={{ flex: 1, padding: "12px 14px", borderRadius: 12, border: "none", background: salvando ? corMuted : corForest, color: "#fff", fontWeight: 700, fontSize: 14, cursor: salvando ? "not-allowed" : "pointer" }}>
              {salvando ? "Salvando..." : inicial ? "Salvar alterações" : "Criar disciplina"}
            </button>
            <button type="button" onClick={onFechar}
              style={{ padding: "12px 18px", borderRadius: 12, border: `1px solid ${corLine}`, background: "none", color: corInk, fontWeight: 700, fontSize: 14, cursor: "pointer" }}>
              Cancelar
            </button>
          </div>
        </form>
      </div>
    </div>
  );
}

function NivelDisciplinas({ T, toast, curso, onVoltar, onAbrirDisciplina }) {
  const [disciplinas, setDisciplinas] = useState(null);
  const [erro, setErro] = useState("");
  const [modalAberto, setModalAberto] = useState(false);
  const [editando, setEditando] = useState(null);
  const [salvando, setSalvando] = useState(false);
  const [removendoId, setRemovendoId] = useState(null);

  const corLine = T?.line || "#DDE5E1";
  const corMuted = T?.muted || "#5C6E67";
  const corInk = T?.ink || "#10201A";
  const corForest = T?.forest || "#17604A";
  const corDanger = T?.danger || "#C24A3F";

  const carregar = useCallback(async () => {
    try {
      setErro("");
      const data = await listarDisciplinasDoCurso(curso.id);
      setDisciplinas(data);
    } catch (e) {
      console.error(e);
      setErro("Não foi possível carregar as disciplinas.");
      setDisciplinas([]);
    }
  }, [curso.id]);

  useEffect(() => { carregar(); }, [carregar]);

  const abrirCriar = () => { setEditando(null); setModalAberto(true); };
  const abrirEditar = (disc) => { setEditando(disc); setModalAberto(true); };
  const fecharModal = () => { if (salvando) return; setModalAberto(false); setEditando(null); };

  const salvar = async (dados) => {
    setSalvando(true);
    try {
      if (editando) {
        await atualizarDisciplina(editando.id, dados);
        toast?.("Disciplina atualizada ✓");
      } else {
        await criarDisciplina({ cursoId: curso.id, nome: dados.nome, descricao: dados.descricao, ordem: dados.ordem, cargaHoraria: dados.carga_horaria });
        toast?.("Disciplina criada ✓");
      }
      setModalAberto(false);
      setEditando(null);
      await carregar();
    } catch (e) {
      console.error(e);
      toast?.("Erro ao salvar disciplina");
    } finally {
      setSalvando(false);
    }
  };

  const remover = async (disc) => {
    if (!window.confirm(`Remover a disciplina "${disc.nome}"? As aulas cadastradas nela também serão removidas.`)) return;
    setRemovendoId(disc.id);
    try {
      await removerDisciplina(disc.id);
      toast?.("Disciplina removida");
      await carregar();
    } catch (e) {
      console.error(e);
      toast?.("Erro ao remover disciplina");
    } finally {
      setRemovendoId(null);
    }
  };

  return (
    <div>
      <button onClick={onVoltar} style={{ display: "flex", alignItems: "center", gap: 6, background: "none", border: "none", color: corForest, fontSize: 13, fontWeight: 700, cursor: "pointer", padding: 0, marginBottom: 12 }}>
        <ArrowLeft size={15} /> Voltar aos cursos
      </button>

      <div style={{ display: "flex", justifyContent: "space-between", alignItems: "center", gap: 10, flexWrap: "wrap", marginBottom: 4 }}>
        <div style={{ fontSize: 15, fontWeight: 800, color: corInk }}>{curso.nome}</div>
      </div>
      <div style={{ fontSize: 12, color: corMuted, marginBottom: 12 }}>Disciplinas deste curso</div>

      <div style={{ display: "flex", justifyContent: "flex-end", marginBottom: 12 }}>
        <button onClick={abrirCriar}
          style={{ display: "flex", alignItems: "center", gap: 6, background: corForest, color: "#fff", border: "none", borderRadius: 999, padding: "8px 14px", fontSize: 12, fontWeight: 700, cursor: "pointer" }}>
          <Plus size={14} /> Nova disciplina
        </button>
      </div>

      {erro ? (
        <div style={{ padding: 24, textAlign: "center", border: `1px solid ${corLine}`, borderRadius: 14 }}>
          <AlertTriangle size={26} color={corDanger} />
          <div style={{ fontSize: 13, color: corMuted, marginTop: 6 }}>{erro}</div>
          <button onClick={carregar}
            style={{ marginTop: 10, display: "inline-flex", alignItems: "center", gap: 6, background: corForest, color: "#fff", border: "none", borderRadius: 999, padding: "8px 16px", fontSize: 13, fontWeight: 700, cursor: "pointer" }}>
            <RefreshCw size={13} /> Tentar de novo
          </button>
        </div>
      ) : disciplinas === null ? (
        <div style={{ display: "flex", alignItems: "center", gap: 8, color: corMuted, fontSize: 13, padding: 24 }}>
          <Loader2 className="kl-spin" size={16} /> Carregando disciplinas...
        </div>
      ) : disciplinas.length === 0 ? (
        <div style={{ padding: 24, textAlign: "center", border: `1px solid ${corLine}`, borderRadius: 14 }}>
          <div style={{ fontSize: 13, color: corMuted }}>Nenhuma disciplina cadastrada ainda neste curso.</div>
        </div>
      ) : (
        <div style={{ border: `1px solid ${corLine}`, borderRadius: 14, overflow: "hidden" }}>
          {disciplinas.map((d, i) => {
            const ocupado = removendoId === d.id;
            return (
              <div key={d.id} style={{ padding: "12px 14px", borderTop: i ? `1px solid ${corLine}` : "none", display: "flex", justifyContent: "space-between", alignItems: "center", gap: 8, flexWrap: "wrap" }}>
                <button onClick={() => onAbrirDisciplina(d)}
                  style={{ display: "flex", alignItems: "center", gap: 6, background: "none", border: "none", cursor: "pointer", textAlign: "left", padding: 0 }}>
                  <div>
                    <div style={{ fontSize: 14, fontWeight: 700, color: corInk }}>{d.nome}</div>
                    <div style={{ fontSize: 12, color: corMuted }}>
                      {d.carga_horaria ? `${d.carga_horaria}h` : "Carga horária não informada"} · ordem {d.ordem}
                    </div>
                  </div>
                  <ChevronRight size={16} color={corMuted} />
                </button>
                <div style={{ display: "flex", alignItems: "center", gap: 8, flexWrap: "wrap" }}>
                  <button onClick={() => abrirEditar(d)} disabled={ocupado}
                    style={{ display: "flex", alignItems: "center", gap: 4, background: "none", border: `1px solid ${corLine}`, color: corInk, borderRadius: 10, padding: "6px 10px", fontSize: 12, fontWeight: 700, cursor: ocupado ? "not-allowed" : "pointer" }}>
                    <Pencil size={13} /> Editar
                  </button>
                  <button onClick={() => remover(d)} disabled={ocupado}
                    style={{ display: "flex", alignItems: "center", gap: 4, background: corDanger, color: "#fff", border: "none", borderRadius: 10, padding: "6px 10px", fontSize: 12, fontWeight: 700, cursor: ocupado ? "not-allowed" : "pointer" }}>
                    <Trash2 size={13} /> Remover
                  </button>
                </div>
              </div>
            );
          })}
        </div>
      )}

      {modalAberto && (
        <DisciplinaModal key={editando?.id || "novo"} inicial={editando} salvando={salvando} onSalvar={salvar} onFechar={fecharModal} T={T} />
      )}
    </div>
  );
}

/* ============================================================
   NÍVEL 3 — AULAS
   ============================================================ */

function AulaModal({ inicial, salvando, enviandoArquivo, onSalvar, onFechar, T }) {
  const [titulo, setTitulo] = useState(inicial?.titulo || "");
  const [tipo, setTipo] = useState(inicial?.tipo || "video");
  const [fonte, setFonte] = useState(() => (inicial && aulaUsaArquivoStorage(inicial.url_video)) ? "arquivo" : "link");
  const [url, setUrl] = useState(fonte === "link" ? (inicial?.url_video || "") : "");
  const [arquivo, setArquivo] = useState(null);
  const [duracaoMin, setDuracaoMin] = useState(inicial?.duracao_seg ? String(Math.round(inicial.duracao_seg / 60)) : "");
  const [ordem, setOrdem] = useState(inicial?.ordem ?? 0);
  const [obrigatoria, setObrigatoria] = useState(inicial?.obrigatoria ?? true);
  const [erro, setErro] = useState("");
  const inputRef = useRef(null);

  const corLine = T?.line || "#DDE5E1";
  const corMuted = T?.muted || "#5C6E67";
  const corInk = T?.ink || "#10201A";
  const corForest = T?.forest || "#17604A";
  const corDanger = T?.danger || "#C24A3F";

  const rotulo = { display: "block", fontSize: 12, fontWeight: 600, color: corMuted, marginBottom: 4 };
  const campo = { width: "100%", boxSizing: "border-box", padding: "10px 12px", borderRadius: 10, border: `1.5px solid ${corLine}`, fontSize: 14 };

  const jaTinhaArquivo = !!(inicial && aulaUsaArquivoStorage(inicial.url_video));

  const escolherArquivo = (e) => {
    const file = e.target.files?.[0];
    e.target.value = "";
    if (!file) return;
    if (file.size > TAMANHO_MAXIMO_CONTEUDO) {
      setErro("Arquivo muito grande. O limite é 200MB.");
      return;
    }
    setErro("");
    setArquivo(file);
  };

  const handleSubmit = (e) => {
    e.preventDefault();
    setErro("");
    if (!titulo.trim()) { setErro("Informe o título da aula."); return; }
    if (fonte === "link" && !url.trim()) { setErro("Informe o link do conteúdo."); return; }
    if (fonte === "arquivo" && !arquivo && !jaTinhaArquivo) { setErro("Selecione um arquivo para enviar."); return; }

    const duracaoNum = duracaoMin !== "" ? Number(duracaoMin) : null;
    if (duracaoMin !== "" && (Number.isNaN(duracaoNum) || duracaoNum < 0)) { setErro("Informe uma duração válida em minutos."); return; }

    onSalvar({
      titulo: titulo.trim(),
      tipo,
      fonte,
      url: url.trim(),
      arquivo,
      duracaoSeg: duracaoNum != null ? Math.round(duracaoNum * 60) : null,
      ordem: ordem !== "" ? Number(ordem) : 0,
      obrigatoria: !!obrigatoria,
    });
  };

  const ocupado = salvando || enviandoArquivo;

  return (
    <div onClick={ocupado ? undefined : onFechar} style={{ position: "fixed", inset: 0, background: "rgba(16,32,26,0.45)", display: "flex", alignItems: "center", justifyContent: "center", zIndex: 60, padding: 16 }}>
      <div onClick={(e) => e.stopPropagation()} style={{ width: "100%", maxWidth: 560, maxHeight: "85vh", overflowY: "auto", background: "#fff", borderRadius: 16, padding: 20 }}>
        <div style={{ display: "flex", justifyContent: "space-between", alignItems: "center", marginBottom: 16 }}>
          <h2 style={{ fontSize: 16, fontWeight: 800, color: corInk, margin: 0 }}>{inicial ? "Editar aula" : "Nova aula"}</h2>
          <button onClick={onFechar} disabled={ocupado} style={{ background: "none", border: "none", cursor: ocupado ? "not-allowed" : "pointer", padding: 4 }}><X size={18} color={corMuted} /></button>
        </div>
        <form onSubmit={handleSubmit}>
          <div style={{ marginBottom: 12 }}>
            <label style={rotulo}>Título *</label>
            <input style={campo} value={titulo} onChange={(e) => setTitulo(e.target.value)} placeholder="Ex.: Introdução às fórmulas" />
          </div>

          <div style={{ marginBottom: 12 }}>
            <label style={rotulo}>Tipo</label>
            <select style={campo} value={tipo} onChange={(e) => setTipo(e.target.value)}>
              {TIPOS_AULA.map((t) => <option key={t.value} value={t.value}>{t.label}</option>)}
            </select>
          </div>

          <div style={{ marginBottom: 12 }}>
            <label style={rotulo}>Fonte do conteúdo</label>
            <div style={{ display: "flex", gap: 8 }}>
              <button type="button" onClick={() => setFonte("link")}
                style={{ flex: 1, display: "flex", alignItems: "center", justifyContent: "center", gap: 6, padding: "10px 12px", borderRadius: 10, border: `1.5px solid ${fonte === "link" ? corForest : corLine}`, background: fonte === "link" ? corForest : "none", color: fonte === "link" ? "#fff" : corInk, fontWeight: 700, fontSize: 13, cursor: "pointer" }}>
                <Link2 size={14} /> Link externo
              </button>
              <button type="button" onClick={() => setFonte("arquivo")}
                style={{ flex: 1, display: "flex", alignItems: "center", justifyContent: "center", gap: 6, padding: "10px 12px", borderRadius: 10, border: `1.5px solid ${fonte === "arquivo" ? corForest : corLine}`, background: fonte === "arquivo" ? corForest : "none", color: fonte === "arquivo" ? "#fff" : corInk, fontWeight: 700, fontSize: 13, cursor: "pointer" }}>
                <Upload size={14} /> Enviar arquivo
              </button>
            </div>
          </div>

          {fonte === "link" ? (
            <div style={{ marginBottom: 12 }}>
              <label style={rotulo}>URL do conteúdo</label>
              <input style={campo} value={url} onChange={(e) => setUrl(e.target.value)} placeholder="YouTube (não listado), Vimeo, Bunny.net..." />
            </div>
          ) : (
            <div style={{ marginBottom: 12 }}>
              <label style={rotulo}>Arquivo (PDF ou vídeo, até 200MB)</label>
              <input ref={inputRef} type="file" accept="application/pdf,video/*" style={{ display: "none" }} onChange={escolherArquivo} />
              <button type="button" onClick={() => inputRef.current?.click()} disabled={ocupado}
                style={{ display: "flex", alignItems: "center", gap: 6, background: "none", border: `1.5px solid ${corLine}`, color: corInk, borderRadius: 10, padding: "10px 12px", fontSize: 13, fontWeight: 700, cursor: ocupado ? "not-allowed" : "pointer" }}>
                <Upload size={14} />
                {arquivo ? arquivo.name : jaTinhaArquivo ? "Trocar arquivo enviado" : "Escolher arquivo"}
              </button>
              <div style={{ fontSize: 11, color: corMuted, marginTop: 6, lineHeight: 1.4 }}>
                Arquivos grandes consomem o armazenamento do plano da escola. Prefira "Link externo" para vídeos longos sempre que possível.
                {jaTinhaArquivo && !arquivo ? " Deixe em branco para manter o arquivo já enviado." : ""}
              </div>
            </div>
          )}

          <div style={{ display: "grid", gridTemplateColumns: "1fr 1fr", gap: 10, marginBottom: 12 }}>
            <div>
              <label style={rotulo}>Duração (minutos)</label>
              <input type="number" min={0} step="0.5" style={campo} value={duracaoMin} onChange={(e) => setDuracaoMin(e.target.value)} placeholder="12" />
            </div>
            <div>
              <label style={rotulo}>Ordem</label>
              <input type="number" min={0} style={campo} value={ordem} onChange={(e) => setOrdem(e.target.value)} />
            </div>
          </div>

          <label style={{ display: "flex", alignItems: "center", gap: 8, marginBottom: 12, fontSize: 13, color: corInk, cursor: "pointer" }}>
            <input type="checkbox" checked={obrigatoria} onChange={(e) => setObrigatoria(e.target.checked)} />
            Aula obrigatória
          </label>

          {erro && <div style={{ marginBottom: 12, padding: 10, borderRadius: 10, background: "#FBEFEC", color: corDanger, fontSize: 13, fontWeight: 500 }}>{erro}</div>}

          <div style={{ display: "flex", gap: 8, marginTop: 4 }}>
            <button type="submit" disabled={ocupado}
              style={{ flex: 1, padding: "12px 14px", borderRadius: 12, border: "none", background: ocupado ? corMuted : corForest, color: "#fff", fontWeight: 700, fontSize: 14, cursor: ocupado ? "not-allowed" : "pointer" }}>
              {enviandoArquivo ? "Enviando arquivo..." : salvando ? "Salvando..." : inicial ? "Salvar alterações" : "Criar aula"}
            </button>
            <button type="button" onClick={onFechar} disabled={ocupado}
              style={{ padding: "12px 18px", borderRadius: 12, border: `1px solid ${corLine}`, background: "none", color: corInk, fontWeight: 700, fontSize: 14, cursor: ocupado ? "not-allowed" : "pointer" }}>
              Cancelar
            </button>
          </div>
        </form>
      </div>
    </div>
  );
}

function NivelAulas({ T, toast, perfil, curso, disciplina, onVoltar }) {
  const [aulas, setAulas] = useState(null);
  const [erro, setErro] = useState("");
  const [modalAberto, setModalAberto] = useState(false);
  const [editando, setEditando] = useState(null);
  const [salvando, setSalvando] = useState(false);
  const [enviandoArquivo, setEnviandoArquivo] = useState(false);
  const [removendoId, setRemovendoId] = useState(null);
  const [abrindoId, setAbrindoId] = useState(null);

  const corLine = T?.line || "#DDE5E1";
  const corMuted = T?.muted || "#5C6E67";
  const corInk = T?.ink || "#10201A";
  const corForest = T?.forest || "#17604A";
  const corDanger = T?.danger || "#C24A3F";

  const carregar = useCallback(async () => {
    try {
      setErro("");
      const data = await listarAulasDaDisciplina(disciplina.id);
      setAulas(data);
    } catch (e) {
      console.error(e);
      setErro("Não foi possível carregar as aulas.");
      setAulas([]);
    }
  }, [disciplina.id]);

  useEffect(() => { carregar(); }, [carregar]);

  const abrirCriar = () => { setEditando(null); setModalAberto(true); };
  const abrirEditar = (aula) => { setEditando(aula); setModalAberto(true); };
  const fecharModal = () => { if (salvando || enviandoArquivo) return; setModalAberto(false); setEditando(null); };

  const salvar = async (form) => {
    setSalvando(true);
    try {
      let urlVideo;
      if (form.fonte === "arquivo") {
        if (form.arquivo) {
          setEnviandoArquivo(true);
          try {
            urlVideo = await enviarArquivoConteudoCurso({ tenantId: perfil.tenant_id, disciplinaId: disciplina.id, file: form.arquivo });
          } finally {
            setEnviandoArquivo(false);
          }
        } else {
          urlVideo = editando?.url_video || null; // mantém o arquivo já enviado antes
        }
      } else {
        urlVideo = form.url;
      }

      const dadosComuns = {
        titulo: form.titulo,
        tipo: form.tipo,
        duracao_seg: form.duracaoSeg,
        ordem: form.ordem,
        obrigatoria: form.obrigatoria,
      };

      if (editando) {
        await atualizarAula(editando.id, { ...dadosComuns, url_video: urlVideo });
        toast?.("Aula atualizada ✓");
      } else {
        await criarAula({ disciplinaId: disciplina.id, urlVideo, ...dadosComuns });
        toast?.("Aula criada ✓");
      }
      setModalAberto(false);
      setEditando(null);
      await carregar();
    } catch (e) {
      console.error(e);
      toast?.("Erro ao salvar aula. Verifique o arquivo/link e tente novamente.");
    } finally {
      setSalvando(false);
    }
  };

  const remover = async (aula) => {
    if (!window.confirm(`Remover a aula "${aula.titulo}"?`)) return;
    setRemovendoId(aula.id);
    try {
      await removerAula(aula.id, aula.url_video);
      toast?.("Aula removida");
      await carregar();
    } catch (e) {
      console.error(e);
      toast?.("Erro ao remover aula");
    } finally {
      setRemovendoId(null);
    }
  };

  const abrirConteudo = async (aula) => {
    setAbrindoId(aula.id);
    try {
      const url = aulaUsaArquivoStorage(aula.url_video) ? await urlConteudoCurso(aula.url_video) : aula.url_video;
      window.open(url, "_blank", "noopener,noreferrer");
    } catch (e) {
      console.error(e);
      toast?.("Não foi possível abrir o conteúdo desta aula.");
    } finally {
      setAbrindoId(null);
    }
  };

  return (
    <div>
      <button onClick={onVoltar} style={{ display: "flex", alignItems: "center", gap: 6, background: "none", border: "none", color: corForest, fontSize: 13, fontWeight: 700, cursor: "pointer", padding: 0, marginBottom: 12 }}>
        <ArrowLeft size={15} /> Voltar à disciplina
      </button>

      <div style={{ fontSize: 15, fontWeight: 800, color: corInk }}>{disciplina.nome}</div>
      <div style={{ fontSize: 12, color: corMuted, marginBottom: 12 }}>{curso.nome} · Aulas desta disciplina</div>

      <div style={{ display: "flex", justifyContent: "flex-end", marginBottom: 12 }}>
        <button onClick={abrirCriar}
          style={{ display: "flex", alignItems: "center", gap: 6, background: corForest, color: "#fff", border: "none", borderRadius: 999, padding: "8px 14px", fontSize: 12, fontWeight: 700, cursor: "pointer" }}>
          <Plus size={14} /> Nova aula
        </button>
      </div>

      {erro ? (
        <div style={{ padding: 24, textAlign: "center", border: `1px solid ${corLine}`, borderRadius: 14 }}>
          <AlertTriangle size={26} color={corDanger} />
          <div style={{ fontSize: 13, color: corMuted, marginTop: 6 }}>{erro}</div>
          <button onClick={carregar}
            style={{ marginTop: 10, display: "inline-flex", alignItems: "center", gap: 6, background: corForest, color: "#fff", border: "none", borderRadius: 999, padding: "8px 16px", fontSize: 13, fontWeight: 700, cursor: "pointer" }}>
            <RefreshCw size={13} /> Tentar de novo
          </button>
        </div>
      ) : aulas === null ? (
        <div style={{ display: "flex", alignItems: "center", gap: 8, color: corMuted, fontSize: 13, padding: 24 }}>
          <Loader2 className="kl-spin" size={16} /> Carregando aulas...
        </div>
      ) : aulas.length === 0 ? (
        <div style={{ padding: 24, textAlign: "center", border: `1px solid ${corLine}`, borderRadius: 14 }}>
          <div style={{ fontSize: 13, color: corMuted }}>Nenhuma aula cadastrada ainda nesta disciplina.</div>
        </div>
      ) : (
        <div style={{ border: `1px solid ${corLine}`, borderRadius: 14, overflow: "hidden" }}>
          {aulas.map((a, i) => {
            const { label: tipoLabel, Icon: TipoIcon } = infoTipoAula(a.tipo);
            const ocupado = removendoId === a.id;
            return (
              <div key={a.id} style={{ padding: "12px 14px", borderTop: i ? `1px solid ${corLine}` : "none", display: "flex", justifyContent: "space-between", alignItems: "center", gap: 8, flexWrap: "wrap" }}>
                <div style={{ display: "flex", alignItems: "center", gap: 8 }}>
                  <TipoIcon size={16} color={corForest} />
                  <div>
                    <div style={{ fontSize: 14, fontWeight: 700, color: corInk }}>{a.titulo}</div>
                    <div style={{ fontSize: 12, color: corMuted }}>
                      {tipoLabel} · {formatarDuracao(a.duracao_seg)} · ordem {a.ordem}{a.obrigatoria ? " · obrigatória" : ""}
                      {a.url_video ? ` · ${aulaUsaArquivoStorage(a.url_video) ? "arquivo enviado" : "link externo"}` : " · sem conteúdo"}
                    </div>
                  </div>
                </div>
                <div style={{ display: "flex", alignItems: "center", gap: 8, flexWrap: "wrap" }}>
                  {a.url_video && (
                    <button onClick={() => abrirConteudo(a)} disabled={abrindoId === a.id}
                      style={{ display: "flex", alignItems: "center", gap: 4, background: "none", border: `1px solid ${corLine}`, color: corInk, borderRadius: 10, padding: "6px 10px", fontSize: 12, fontWeight: 700, cursor: abrindoId === a.id ? "not-allowed" : "pointer" }}>
                      <Eye size={13} /> Abrir
                    </button>
                  )}
                  <button onClick={() => abrirEditar(a)} disabled={ocupado}
                    style={{ display: "flex", alignItems: "center", gap: 4, background: "none", border: `1px solid ${corLine}`, color: corInk, borderRadius: 10, padding: "6px 10px", fontSize: 12, fontWeight: 700, cursor: ocupado ? "not-allowed" : "pointer" }}>
                    <Pencil size={13} /> Editar
                  </button>
                  <button onClick={() => remover(a)} disabled={ocupado}
                    style={{ display: "flex", alignItems: "center", gap: 4, background: corDanger, color: "#fff", border: "none", borderRadius: 10, padding: "6px 10px", fontSize: 12, fontWeight: 700, cursor: ocupado ? "not-allowed" : "pointer" }}>
                    <Trash2 size={13} /> Remover
                  </button>
                </div>
              </div>
            );
          })}
        </div>
      )}

      {modalAberto && (
        <AulaModal key={editando?.id || "novo"} inicial={editando} salvando={salvando} enviandoArquivo={enviandoArquivo} onSalvar={salvar} onFechar={fecharModal} T={T} />
      )}
    </div>
  );
}

/* ============================================================
   RAIZ — drill-down curso -> disciplina -> aula
   ============================================================ */

export default function Cursos({ perfil, toast, T }) {
  const [nivel, setNivel] = useState("cursos"); // "cursos" | "disciplinas" | "aulas"
  const [cursoSelecionado, setCursoSelecionado] = useState(null);
  const [disciplinaSelecionada, setDisciplinaSelecionada] = useState(null);

  const abrirCurso = (curso) => {
    setCursoSelecionado(curso);
    setDisciplinaSelecionada(null);
    setNivel("disciplinas");
  };

  const abrirDisciplina = (disciplina) => {
    setDisciplinaSelecionada(disciplina);
    setNivel("aulas");
  };

  const voltarACursos = () => { setNivel("cursos"); setCursoSelecionado(null); setDisciplinaSelecionada(null); };
  const voltarADisciplinas = () => { setNivel("disciplinas"); setDisciplinaSelecionada(null); };

  return (
    <div style={{ marginTop: 20 }}>
      {nivel === "cursos" && (
        <NivelCursos T={T} toast={toast} onAbrirCurso={abrirCurso} />
      )}
      {nivel === "disciplinas" && cursoSelecionado && (
        <NivelDisciplinas T={T} toast={toast} curso={cursoSelecionado} onVoltar={voltarACursos} onAbrirDisciplina={abrirDisciplina} />
      )}
      {nivel === "aulas" && cursoSelecionado && disciplinaSelecionada && (
        <NivelAulas T={T} toast={toast} perfil={perfil} curso={cursoSelecionado} disciplina={disciplinaSelecionada} onVoltar={voltarADisciplinas} />
      )}
    </div>
  );
}
