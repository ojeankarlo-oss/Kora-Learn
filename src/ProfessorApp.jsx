import React, { useCallback, useEffect, useState } from "react";
import {
  ChevronRight, ChevronLeft, FileText, Link2, Video, Book,
  Bell, ClipboardList, Plus, Trash2, RefreshCw, Loader2, AlertTriangle, LogOut, Inbox,
} from "lucide-react";
import {
  minhasTurmasProfessor, materiaisDaTurma, publicarMaterial, removerMaterial,
  avisosDaTurma, criarAvisoTurma, removerAvisoTurma,
} from "./lib/api";
import Chamada from "./Chamada";

const TIPOS_MATERIAL = [
  { value: "artigo", label: "Artigo" },
  { value: "pdf", label: "PDF" },
  { value: "link", label: "Link" },
  { value: "video", label: "Vídeo" },
  { value: "livro_indicado", label: "Livro indicado" },
];

const ICONE_TIPO_MATERIAL = { artigo: FileText, pdf: FileText, link: Link2, video: Video, livro_indicado: Book };

const TIPOS_AVISO = [
  { value: "prova", label: "Prova" },
  { value: "trabalho", label: "Trabalho" },
  { value: "evento", label: "Evento" },
  { value: "aviso_geral", label: "Aviso geral" },
];

function rotuloTipoAviso(tipo) {
  return TIPOS_AVISO.find((t) => t.value === tipo)?.label || tipo || "Aviso";
}

function formatarData(iso) {
  if (!iso) return "";
  const [ano, mes, dia] = String(iso).slice(0, 10).split("-");
  return `${dia}/${mes}/${ano}`;
}

// Prova/trabalho com data nos proximos 7 dias merece destaque na lista.
function avisoEhUrgente(aviso) {
  if (!aviso.data_evento || !["prova", "trabalho"].includes(aviso.tipo)) return false;
  const hoje = new Date(); hoje.setHours(0, 0, 0, 0);
  const data = new Date(`${String(aviso.data_evento).slice(0, 10)}T00:00:00`);
  const diffDias = Math.round((data - hoje) / 86400000);
  return diffDias >= 0 && diffDias <= 7;
}

/* ============================================================
   CABECALHO — marca do tenant, nome do professor, botao Sair
   (mesmo padrao do AlunoLayout, para nunca haver tela sem cabecalho)
   ============================================================ */
function ProfessorLayout({ T, perfil, onLogout, children }) {
  const corLine = T?.line || "#DDE5E1";
  const corMuted = T?.muted || "#5C6E67";
  const corInk = T?.ink || "#10201A";
  const corForest = T?.forest || "#17604A";
  const nomeMarca = T?.nomeMarca || "KORA Learn";

  return (
    <div style={{ minHeight: "100vh", background: T?.paper || "#F1F4F2" }}>
      <div style={{ position: "sticky", top: 0, zIndex: 40, background: T?.paper || "#F1F4F2", borderBottom: `1px solid ${corLine}`, padding: "12px 16px", display: "flex", flexWrap: "wrap", rowGap: 8, justifyContent: "space-between", alignItems: "center" }}>
        <span className="kl-display" style={{ fontWeight: 800, fontSize: 17, color: corInk }}>
          {nomeMarca.split(" ")[0]}<span style={{ color: corForest }}> {nomeMarca.split(" ").slice(1).join(" ")}</span>
        </span>
        <div style={{ display: "flex", gap: 10, alignItems: "center", flexShrink: 0 }}>
          <span style={{ fontSize: 12, fontWeight: 600, color: corMuted }}>{perfil.nome.split(" ")[0]} · Professor</span>
          <button onClick={onLogout} style={{ display: "flex", alignItems: "center", gap: 6, background: "#fff", border: `1px solid ${corLine}`, borderRadius: 999, padding: "6px 12px", color: corMuted, fontSize: 12, fontWeight: 700, cursor: "pointer", flexShrink: 0 }}>
            <LogOut size={15} color={corMuted} /> Sair
          </button>
        </div>
      </div>
      {children}
    </div>
  );
}

/* ============================================================
   MATERIAIS DA TURMA
   ============================================================ */
function MateriaisTurma({ turmaId, disciplinaId, T, toast }) {
  const [materiais, setMateriais] = useState(null);
  const [erro, setErro] = useState("");
  const [tipo, setTipo] = useState("artigo");
  const [titulo, setTitulo] = useState("");
  const [descricao, setDescricao] = useState("");
  const [url, setUrl] = useState("");
  const [publicando, setPublicando] = useState(false);
  const [removendoId, setRemovendoId] = useState(null);

  const corLine = T?.line || "#DDE5E1";
  const corMuted = T?.muted || "#5C6E67";
  const corInk = T?.ink || "#10201A";
  const corForest = T?.forest || "#17604A";
  const corDanger = T?.danger || "#C24A3F";

  const carregar = useCallback(async () => {
    try {
      setErro("");
      const data = await materiaisDaTurma(turmaId);
      setMateriais(data);
    } catch (e) {
      console.error(e);
      setErro("Não foi possível carregar os materiais.");
      setMateriais([]);
    }
  }, [turmaId]);

  useEffect(() => { setMateriais(null); carregar(); }, [carregar]);

  const publicar = async (e) => {
    e.preventDefault();
    if (!titulo.trim()) { toast?.("Informe o título do material."); return; }
    setPublicando(true);
    try {
      await publicarMaterial({ turmaId, disciplinaId, tipo, titulo: titulo.trim(), descricao: descricao.trim(), url: url.trim() });
      toast?.("Material publicado ✓");
      setTitulo(""); setDescricao(""); setUrl(""); setTipo("artigo");
      await carregar();
    } catch (err) {
      console.error(err);
      toast?.("Erro ao publicar material");
    } finally {
      setPublicando(false);
    }
  };

  const remover = async (m) => {
    if (!window.confirm(`Remover o material "${m.titulo}"?`)) return;
    setRemovendoId(m.id);
    try {
      await removerMaterial(m.id);
      toast?.("Material removido");
      await carregar();
    } catch (err) {
      console.error(err);
      toast?.("Erro ao remover material");
    } finally {
      setRemovendoId(null);
    }
  };

  const box = { background: T?.card || "#fff", borderRadius: 14, border: `1px solid ${corLine}`, padding: 16, marginBottom: 16 };
  const rotulo = { display: "block", fontSize: 12, fontWeight: 700, color: corMuted, marginBottom: 4 };
  const campo = { width: "100%", padding: "8px 10px", borderRadius: 8, border: `1px solid ${corLine}`, fontSize: 13, boxSizing: "border-box" };

  return (
    <div>
      <div style={box}>
        <div style={{ fontSize: 14, fontWeight: 800, color: corInk, marginBottom: 12, display: "flex", alignItems: "center", gap: 8 }}>
          <Plus size={16} color={corForest} /> Publicar material
        </div>
        <form onSubmit={publicar}>
          <div style={{ display: "grid", gridTemplateColumns: "1fr 1fr", gap: 10, marginBottom: 10 }}>
            <div>
              <label style={rotulo}>Tipo</label>
              <select style={campo} value={tipo} onChange={(e) => setTipo(e.target.value)}>
                {TIPOS_MATERIAL.map((op) => <option key={op.value} value={op.value}>{op.label}</option>)}
              </select>
            </div>
            <div>
              <label style={rotulo}>Título</label>
              <input style={campo} value={titulo} onChange={(e) => setTitulo(e.target.value)} placeholder="Ex.: Capítulo 3 — Frações" />
            </div>
          </div>
          <div style={{ marginBottom: 10 }}>
            <label style={rotulo}>Descrição (opcional)</label>
            <input style={campo} value={descricao} onChange={(e) => setDescricao(e.target.value)} placeholder="Breve descrição do material" />
          </div>
          <div style={{ marginBottom: 12 }}>
            <label style={rotulo}>URL (opcional)</label>
            <input style={campo} value={url} onChange={(e) => setUrl(e.target.value)} placeholder="https://..." />
          </div>
          <button type="submit" disabled={publicando}
            style={{ background: corForest, color: "#fff", border: "none", borderRadius: 10, padding: "8px 16px", fontSize: 13, fontWeight: 700, cursor: publicando ? "not-allowed" : "pointer" }}>
            {publicando ? "Publicando..." : "Publicar material"}
          </button>
        </form>
      </div>

      <div style={box}>
        <div style={{ fontSize: 14, fontWeight: 800, color: corInk, marginBottom: 12 }}>Materiais publicados</div>
        {erro ? (
          <div>
            <div style={{ color: corDanger, fontSize: 13, marginBottom: 8 }}>{erro}</div>
            <button onClick={carregar} style={{ display: "inline-flex", alignItems: "center", gap: 6, border: `1px solid ${corLine}`, background: "none", borderRadius: 999, padding: "6px 14px", fontSize: 13, fontWeight: 700, cursor: "pointer", color: corInk }}>
              <RefreshCw size={14} /> Tentar de novo
            </button>
          </div>
        ) : materiais === null ? (
          <div style={{ display: "flex", alignItems: "center", gap: 8, color: corMuted, fontSize: 13 }}>
            <Loader2 size={16} className="kl-spin" /> Carregando materiais...
          </div>
        ) : materiais.length === 0 ? (
          <div style={{ color: corMuted, fontSize: 13 }}>Nenhum material publicado ainda nesta turma.</div>
        ) : (
          <div style={{ display: "flex", flexDirection: "column", gap: 8 }}>
            {materiais.map((m) => {
              const Icone = ICONE_TIPO_MATERIAL[m.tipo] || FileText;
              return (
                <div key={m.id} style={{ padding: "10px 12px", border: `1px solid ${corLine}`, borderRadius: 10 }}>
                  <div style={{ display: "flex", justifyContent: "space-between", gap: 8, flexWrap: "wrap" }}>
                    <div style={{ display: "flex", alignItems: "flex-start", gap: 8 }}>
                      <Icone size={16} color={corForest} style={{ marginTop: 2, flexShrink: 0 }} />
                      <div>
                        <div style={{ fontSize: 13, fontWeight: 700, color: corInk }}>{m.titulo}</div>
                        {m.descricao && <div style={{ fontSize: 12, color: corMuted, marginTop: 2 }}>{m.descricao}</div>}
                        {m.url && (
                          <a href={m.url} target="_blank" rel="noreferrer" style={{ fontSize: 12, color: corForest, fontWeight: 600, display: "inline-block", marginTop: 2 }}>
                            Abrir material
                          </a>
                        )}
                      </div>
                    </div>
                    <button onClick={() => remover(m)} disabled={removendoId === m.id}
                      style={{ display: "flex", alignItems: "center", gap: 4, background: "none", border: `1px solid ${corDanger}`, color: corDanger, borderRadius: 10, padding: "5px 10px", fontSize: 12, fontWeight: 700, cursor: removendoId === m.id ? "not-allowed" : "pointer", flexShrink: 0 }}>
                      <Trash2 size={13} /> Remover
                    </button>
                  </div>
                </div>
              );
            })}
          </div>
        )}
      </div>
    </div>
  );
}

/* ============================================================
   AGENDA / AVISOS DA TURMA
   ============================================================ */
function AvisosTurma({ turmaId, T, toast }) {
  const [avisos, setAvisos] = useState(null);
  const [erro, setErro] = useState("");
  const [tipo, setTipo] = useState("aviso_geral");
  const [titulo, setTitulo] = useState("");
  const [descricao, setDescricao] = useState("");
  const [dataEvento, setDataEvento] = useState("");
  const [criando, setCriando] = useState(false);
  const [removendoId, setRemovendoId] = useState(null);

  const corLine = T?.line || "#DDE5E1";
  const corMuted = T?.muted || "#5C6E67";
  const corInk = T?.ink || "#10201A";
  const corForest = T?.forest || "#17604A";
  const corDanger = T?.danger || "#C24A3F";
  const corAmber = T?.amber || "#E9A13B";

  const carregar = useCallback(async () => {
    try {
      setErro("");
      const data = await avisosDaTurma(turmaId);
      setAvisos(data);
    } catch (e) {
      console.error(e);
      setErro("Não foi possível carregar os avisos.");
      setAvisos([]);
    }
  }, [turmaId]);

  useEffect(() => { setAvisos(null); carregar(); }, [carregar]);

  const criar = async (e) => {
    e.preventDefault();
    if (!titulo.trim()) { toast?.("Informe o título do aviso."); return; }
    setCriando(true);
    try {
      await criarAvisoTurma({ turmaId, tipo, titulo: titulo.trim(), descricao: descricao.trim(), dataEvento: dataEvento || null });
      toast?.("Aviso criado ✓");
      setTitulo(""); setDescricao(""); setDataEvento(""); setTipo("aviso_geral");
      await carregar();
    } catch (err) {
      console.error(err);
      toast?.("Erro ao criar aviso");
    } finally {
      setCriando(false);
    }
  };

  const remover = async (a) => {
    if (!window.confirm(`Remover o aviso "${a.titulo}"?`)) return;
    setRemovendoId(a.id);
    try {
      await removerAvisoTurma(a.id);
      toast?.("Aviso removido");
      await carregar();
    } catch (err) {
      console.error(err);
      toast?.("Erro ao remover aviso");
    } finally {
      setRemovendoId(null);
    }
  };

  const box = { background: T?.card || "#fff", borderRadius: 14, border: `1px solid ${corLine}`, padding: 16, marginBottom: 16 };
  const rotulo = { display: "block", fontSize: 12, fontWeight: 700, color: corMuted, marginBottom: 4 };
  const campo = { width: "100%", padding: "8px 10px", borderRadius: 8, border: `1px solid ${corLine}`, fontSize: 13, boxSizing: "border-box" };

  return (
    <div>
      <div style={box}>
        <div style={{ fontSize: 14, fontWeight: 800, color: corInk, marginBottom: 12, display: "flex", alignItems: "center", gap: 8 }}>
          <Plus size={16} color={corForest} /> Criar aviso
        </div>
        <form onSubmit={criar}>
          <div style={{ display: "grid", gridTemplateColumns: "1fr 1fr", gap: 10, marginBottom: 10 }}>
            <div>
              <label style={rotulo}>Tipo</label>
              <select style={campo} value={tipo} onChange={(e) => setTipo(e.target.value)}>
                {TIPOS_AVISO.map((op) => <option key={op.value} value={op.value}>{op.label}</option>)}
              </select>
            </div>
            <div>
              <label style={rotulo}>Data (opcional)</label>
              <input type="date" style={campo} value={dataEvento} onChange={(e) => setDataEvento(e.target.value)} />
            </div>
          </div>
          <div style={{ marginBottom: 10 }}>
            <label style={rotulo}>Título</label>
            <input style={campo} value={titulo} onChange={(e) => setTitulo(e.target.value)} placeholder="Ex.: Prova de Matemática — Unidade 2" />
          </div>
          <div style={{ marginBottom: 12 }}>
            <label style={rotulo}>Descrição (opcional)</label>
            <input style={campo} value={descricao} onChange={(e) => setDescricao(e.target.value)} placeholder="Detalhes do aviso" />
          </div>
          <button type="submit" disabled={criando}
            style={{ background: corForest, color: "#fff", border: "none", borderRadius: 10, padding: "8px 16px", fontSize: 13, fontWeight: 700, cursor: criando ? "not-allowed" : "pointer" }}>
            {criando ? "Criando..." : "Criar aviso"}
          </button>
        </form>
      </div>

      <div style={box}>
        <div style={{ fontSize: 14, fontWeight: 800, color: corInk, marginBottom: 12 }}>Agenda da turma</div>
        {erro ? (
          <div>
            <div style={{ color: corDanger, fontSize: 13, marginBottom: 8 }}>{erro}</div>
            <button onClick={carregar} style={{ display: "inline-flex", alignItems: "center", gap: 6, border: `1px solid ${corLine}`, background: "none", borderRadius: 999, padding: "6px 14px", fontSize: 13, fontWeight: 700, cursor: "pointer", color: corInk }}>
              <RefreshCw size={14} /> Tentar de novo
            </button>
          </div>
        ) : avisos === null ? (
          <div style={{ display: "flex", alignItems: "center", gap: 8, color: corMuted, fontSize: 13 }}>
            <Loader2 size={16} className="kl-spin" /> Carregando avisos...
          </div>
        ) : avisos.length === 0 ? (
          <div style={{ color: corMuted, fontSize: 13 }}>Nenhum aviso cadastrado ainda nesta turma.</div>
        ) : (
          <div style={{ display: "flex", flexDirection: "column", gap: 8 }}>
            {avisos.map((a) => {
              const urgente = avisoEhUrgente(a);
              return (
                <div key={a.id} style={{ padding: "10px 12px", border: `1px solid ${urgente ? corAmber : corLine}`, background: urgente ? "#FFF5E3" : "transparent", borderRadius: 10 }}>
                  <div style={{ display: "flex", justifyContent: "space-between", gap: 8, flexWrap: "wrap" }}>
                    <div>
                      <div style={{ display: "flex", alignItems: "center", gap: 6 }}>
                        <span style={{ fontSize: 11, fontWeight: 700, padding: "2px 8px", borderRadius: 999, background: urgente ? corAmber : corLine, color: urgente ? "#fff" : corMuted }}>
                          {rotuloTipoAviso(a.tipo)}
                        </span>
                        {a.data_evento && <span style={{ fontSize: 12, color: corMuted, fontWeight: 600 }}>{formatarData(a.data_evento)}</span>}
                      </div>
                      <div style={{ fontSize: 13, fontWeight: 700, color: corInk, marginTop: 4 }}>{a.titulo}</div>
                      {a.descricao && <div style={{ fontSize: 12, color: corMuted, marginTop: 2 }}>{a.descricao}</div>}
                    </div>
                    <button onClick={() => remover(a)} disabled={removendoId === a.id}
                      style={{ display: "flex", alignItems: "center", gap: 4, background: "none", border: `1px solid ${corDanger}`, color: corDanger, borderRadius: 10, padding: "5px 10px", fontSize: 12, fontWeight: 700, cursor: removendoId === a.id ? "not-allowed" : "pointer", flexShrink: 0, height: "fit-content" }}>
                      <Trash2 size={13} /> Remover
                    </button>
                  </div>
                </div>
              );
            })}
          </div>
        )}
      </div>
    </div>
  );
}

/* ============================================================
   PROFESSOR APP
   ============================================================ */
export default function ProfessorApp({ perfil, onLogout, toast, T }) {
  const [turmas, setTurmas] = useState(null);
  const [erroTurmas, setErroTurmas] = useState("");
  const [turmaSelecionadaId, setTurmaSelecionadaId] = useState(null);
  const [aba, setAba] = useState("materiais");

  const corLine = T?.line || "#DDE5E1";
  const corMuted = T?.muted || "#5C6E67";
  const corInk = T?.ink || "#10201A";
  const corForest = T?.forest || "#17604A";
  const corDanger = T?.danger || "#C24A3F";

  const carregarTurmas = useCallback(async () => {
    try {
      setErroTurmas("");
      const data = await minhasTurmasProfessor();
      setTurmas(data);
    } catch (e) {
      console.error(e);
      setErroTurmas("Não foi possível carregar suas turmas.");
      setTurmas([]);
    }
  }, []);

  useEffect(() => { carregarTurmas(); }, [carregarTurmas]);

  const turmaSelecionada = (turmas || []).find((t) => String(t.turmaId) === String(turmaSelecionadaId));

  const box = { background: T?.card || "#fff", borderRadius: 14, border: `1px solid ${corLine}`, padding: 16, marginBottom: 16 };

  const ABAS = [
    { id: "materiais", label: "Materiais", icon: FileText },
    { id: "avisos", label: "Agenda", icon: Bell },
    { id: "chamada", label: "Chamada", icon: ClipboardList },
  ];

  return (
    <ProfessorLayout T={T} perfil={perfil} onLogout={onLogout}>
      <div style={{ padding: "16px 16px 60px", maxWidth: 720, margin: "0 auto" }}>
        <div style={{ fontSize: 13, fontWeight: 700, color: corMuted, textTransform: "uppercase", letterSpacing: "0.06em" }}>
          Portal do professor
        </div>
        <h1 className="kl-display" style={{ fontSize: 22, fontWeight: 800, color: corInk, margin: "4px 0 16px" }}>
          Olá, {perfil.nome.split(" ")[0]}!
        </h1>

        {erroTurmas ? (
          <div style={{ ...box, textAlign: "center" }}>
            <AlertTriangle size={26} color={corDanger} />
            <div style={{ fontSize: 13, color: corMuted, marginTop: 6 }}>{erroTurmas}</div>
            <button onClick={carregarTurmas}
              style={{ marginTop: 10, display: "inline-flex", alignItems: "center", gap: 6, background: corForest, color: "#fff", border: "none", borderRadius: 999, padding: "8px 16px", fontSize: 13, fontWeight: 700, cursor: "pointer" }}>
              <RefreshCw size={13} /> Tentar de novo
            </button>
          </div>
        ) : turmas === null ? (
          <div style={{ display: "flex", alignItems: "center", gap: 8, color: corMuted, fontSize: 13 }}>
            <Loader2 size={16} className="kl-spin" /> Carregando suas turmas...
          </div>
        ) : turmas.length === 0 ? (
          <div style={{ ...box, textAlign: "center" }}>
            <Inbox size={26} color={corMuted} />
            <div style={{ fontSize: 13, color: corMuted, marginTop: 6 }}>
              Nenhuma turma vinculada ainda — fale com a coordenação.
            </div>
          </div>
        ) : !turmaSelecionada ? (
          <div style={{ display: "flex", flexDirection: "column", gap: 10 }}>
            {turmas.map((t) => (
              <button key={t.turmaId} onClick={() => { setTurmaSelecionadaId(t.turmaId); setAba("materiais"); }}
                style={{ ...box, textAlign: "left", cursor: "pointer", display: "flex", justifyContent: "space-between", alignItems: "center", marginBottom: 0 }}>
                <div>
                  <div style={{ fontWeight: 800, fontSize: 15, color: corInk }}>{t.turmaNome}</div>
                  <div style={{ fontSize: 12, color: corMuted, marginTop: 2 }}>{t.cursoNome}</div>
                </div>
                <ChevronRight size={18} color={corMuted} />
              </button>
            ))}
          </div>
        ) : (
          <>
            <button onClick={() => setTurmaSelecionadaId(null)}
              style={{ display: "flex", alignItems: "center", gap: 4, background: "none", border: "none", color: corForest, fontSize: 13, fontWeight: 700, cursor: "pointer", padding: 0, marginBottom: 10 }}>
              <ChevronLeft size={16} /> Minhas turmas
            </button>
            <div style={{ fontWeight: 800, fontSize: 17, color: corInk, marginBottom: 4 }}>{turmaSelecionada.turmaNome}</div>
            <div style={{ fontSize: 12, color: corMuted, marginBottom: 14 }}>{turmaSelecionada.cursoNome}</div>

            <div style={{ display: "flex", gap: 8, marginBottom: 16, flexWrap: "wrap" }}>
              {ABAS.map(({ id, label, icon: Icon }) => (
                <button key={id} onClick={() => setAba(id)}
                  style={{ display: "flex", alignItems: "center", gap: 6, background: aba === id ? corForest : "none", color: aba === id ? "#fff" : corMuted, border: aba === id ? "none" : `1px solid ${corLine}`, borderRadius: 999, padding: "6px 14px", fontSize: 12, fontWeight: 700, cursor: "pointer" }}>
                  <Icon size={13} /> {label}
                </button>
              ))}
            </div>

            {aba === "materiais" && (
              <MateriaisTurma turmaId={turmaSelecionada.turmaId} disciplinaId={turmaSelecionada.disciplinaId} T={T} toast={toast} />
            )}
            {aba === "avisos" && (
              <AvisosTurma turmaId={turmaSelecionada.turmaId} T={T} toast={toast} />
            )}
            {aba === "chamada" && (
              <Chamada perfil={perfil} toast={toast} T={T} />
            )}
          </>
        )}
      </div>
    </ProfessorLayout>
  );
}
