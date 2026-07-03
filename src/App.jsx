// ============================================================
// KORA LEARN â App conectado ao Supabase
// Salvar em: src/App.jsx  (projeto Vite React)
// Depende de: src/lib/supabaseClient.js e src/lib/api.js
// ============================================================
import React, { useState, useEffect, useCallback } from "react";
import {
  Home, PlayCircle, BookOpen, Bell, ChevronRight, CheckCircle2, Lock,
  Flame, Trophy, Star, Users, AlertTriangle, LogOut, GraduationCap,
  FileText, Clock, TrendingUp, Loader2, Inbox, UserPlus, RefreshCw
} from "lucide-react";
import { supabase } from "./lib/supabaseClient";
import {
  entrarComEmail, sair, meuPerfil, meusCursos, concluirAula,
  kpisDoTenant, listarLeads, listarCursos, converterLead
} from "./lib/api";

/* ---------- Identidade visual ---------- */
const T = {
  ink: "#10201A", forest: "#17604A", forestDark: "#0E4536",
  amber: "#E9A13B", amberSoft: "#FBEFDA", paper: "#F1F4F2",
  card: "#FFFFFF", line: "#DDE5E1", muted: "#5C6E67",
  danger: "#C24A3F", success: "#2E8B63",
};

const fontStyles = `
@import url('https://fonts.googleapis.com/css2?family=Archivo:wght@500;600;700;800&family=Inter:wght@400;500;600;700&display=swap');
.kl-display { font-family: 'Archivo', sans-serif; letter-spacing: -0.02em; }
.kl-body { font-family: 'Inter', sans-serif; }
.kl-eyebrow { font-family: 'Archivo', sans-serif; letter-spacing: 0.14em; text-transform: uppercase; font-size: 11px; font-weight: 700; }
.kl-fade { animation: klfade .35s ease; }
@keyframes klfade { from { opacity: 0; transform: translateY(6px);} to { opacity: 1; transform: none;} }
.kl-string { transition: stroke .4s ease, opacity .4s ease; }
.kl-spin { animation: klspin 1s linear infinite; }
@keyframes klspin { to { transform: rotate(360deg); } }
button { cursor: pointer; }
body { margin: 0; }
`;

/* ---------- Assinatura: cordas de kora ---------- */
function KoraStrings({ total, done, height = 46, gap = 9 }) {
  if (!total) return null;
  const width = (total - 1) * gap + 8;
  return (
    <svg width={width} height={height} viewBox={`0 0 ${width} ${height}`}>
      {Array.from({ length: total }).map((_, i) => {
        const x = 4 + i * gap;
        const lit = i < done;
        return (
          <g key={i}>
            <line className="kl-string" x1={x} y1={4} x2={x} y2={height - 8}
              stroke={lit ? T.amber : T.line} strokeWidth={lit ? 2.4 : 1.6}
              strokeLinecap="round" />
            <circle cx={x} cy={height - 5} r={lit ? 2.6 : 1.8} fill={lit ? T.forest : T.line} />
          </g>
        );
      })}
    </svg>
  );
}

function LogoKora({ light = false, size = 20 }) {
  return (
    <div style={{ display: "flex", alignItems: "center", gap: 8 }}>
      <svg width={size + 6} height={size + 6} viewBox="0 0 26 26">
        <rect width="26" height="26" rx="7" fill={light ? "#FFFFFF" : T.forest} />
        {[7, 11, 15, 19].map((x, i) => (
          <line key={x} x1={x} y1={6} x2={x} y2={20}
            stroke={light ? T.forest : (i < 3 ? T.amber : "#FFFFFF55")}
            strokeWidth="2" strokeLinecap="round" />
        ))}
      </svg>
      <span className="kl-display" style={{ fontWeight: 800, fontSize: size, color: light ? "#fff" : T.ink }}>
        KORA<span style={{ color: light ? T.amber : T.forest }}> Learn</span>
      </span>
    </div>
  );
}

function Card({ children, style = {} }) {
  return (
    <div style={{ background: T.card, border: `1px solid ${T.line}`, borderRadius: 18, ...style }}>
      {children}
    </div>
  );
}

function Eyebrow({ children, color = T.muted }) {
  return <div className="kl-eyebrow" style={{ color }}>{children}</div>;
}

function Toast({ msg }) {
  if (!msg) return null;
  return (
    <div className="kl-fade" style={{ position: "fixed", bottom: 84, left: "50%", transform: "translateX(-50%)", zIndex: 50 }}>
      <div style={{ background: T.ink, color: "#fff", padding: "8px 16px", borderRadius: 999, fontSize: 14, fontWeight: 500 }}>
        {msg}
      </div>
    </div>
  );
}

function Spinner({ label = "Carregandoâ¦" }) {
  return (
    <div style={{ display: "flex", flexDirection: "column", alignItems: "center", gap: 10, padding: 48, color: T.muted }}>
      <Loader2 size={28} className="kl-spin" color={T.forest} />
      <span style={{ fontSize: 13 }}>{label}</span>
    </div>
  );
}

/* ============================================================
   LOGIN (real)
   ============================================================ */
function LoginScreen({ onLogged }) {
  const [email, setEmail] = useState("");
  const [senha, setSenha] = useState("");
  const [erro, setErro] = useState("");
  const [loading, setLoading] = useState(false);

  const entrar = async () => {
    setErro(""); setLoading(true);
    try {
      await entrarComEmail(email.trim(), senha);
      onLogged();
    } catch (e) {
      setErro(
        e?.message?.includes("Invalid login")
          ? "E-mail ou senha incorretos."
          : "Não foi possível entrar. Verifique sua conexão e tente de novo."
      );
    } finally {
      setLoading(false);
    }
  };

  return (
    <div className="kl-body" style={{ minHeight: "100vh", background: T.forestDark, display: "flex", flexDirection: "column", justifyContent: "center", alignItems: "center", padding: 24 }}>
      <svg width="180" height="70" viewBox="0 0 180 70" style={{ marginBottom: 20 }}>
        {Array.from({ length: 21 }).map((_, i) => (
          <line key={i} x1={8 + i * 8.2} y1={i % 2 ? 10 : 16} x2={8 + i * 8.2} y2={i % 3 === 0 ? 62 : 56}
            stroke={i % 4 === 0 ? T.amber : "#FFFFFF33"} strokeWidth={i % 4 === 0 ? 2.2 : 1.2} strokeLinecap="round" />
        ))}
      </svg>
      <LogoKora light size={26} />
      <p style={{ color: "#CFE0D8", fontSize: 14, maxWidth: 300, textAlign: "center", marginTop: 10 }}>
        Cada aula aprendida, uma vida se transforma.
      </p>

      <div style={{ background: "#fff", borderRadius: 24, padding: 24, width: "100%", maxWidth: 380, marginTop: 28 }}>
        <div className="kl-display" style={{ fontSize: 18, fontWeight: 700, color: T.ink }}>Entrar na plataforma</div>

        <label style={{ display: "block", marginTop: 16, fontSize: 12, fontWeight: 600, color: T.muted }}>E-mail</label>
        <input value={email} onChange={(e) => setEmail(e.target.value)} placeholder="voce@exemplo.com"
          onKeyDown={(e) => e.key === "Enter" && entrar()}
          style={{ width: "100%", boxSizing: "border-box", marginTop: 4, padding: "10px 12px", borderRadius: 12, border: `1.5px solid ${T.line}`, fontSize: 14, color: T.ink, outline: "none" }} />

        <label style={{ display: "block", marginTop: 12, fontSize: 12, fontWeight: 600, color: T.muted }}>Senha</label>
        <input type="password" value={senha} onChange={(e) => setSenha(e.target.value)} placeholder="â¢â¢â¢â¢â¢â¢â¢â¢"
          onKeyDown={(e) => e.key === "Enter" && entrar()}
          style={{ width: "100%", boxSizing: "border-box", marginTop: 4, padding: "10px 12px", borderRadius: 12, border: `1.5px solid ${T.line}`, fontSize: 14, color: T.ink, outline: "none" }} />

        {erro && (
          <div style={{ marginTop: 12, padding: 10, borderRadius: 12, background: "#FBEFEC", color: T.danger, fontSize: 13, fontWeight: 500 }}>
            {erro}
          </div>
        )}

        <button onClick={entrar} disabled={loading || !email || !senha}
          style={{ width: "100%", marginTop: 18, padding: 13, borderRadius: 12, border: "none", background: loading ? "#9DB5AC" : T.forest, color: "#fff", fontWeight: 600, fontSize: 14 }}>
          {loading ? "Entrandoâ¦" : "Entrar"}
        </button>
      </div>
      <div style={{ marginTop: 20, fontSize: 12, color: "#9DBBAF" }}>
        KORA Gestão Educacional · MVP
      </div>
    </div>
  );
}

/* ============================================================
   ALUNO
   ============================================================ */
function AlunoApp({ perfil, onLogout, toast }) {
  const [tab, setTab] = useState("home");
  const [cursos, setCursos] = useState(null); // null = carregando
  const [erro, setErro] = useState("");

  const carregar = useCallback(async () => {
    try {
      const data = await meusCursos(perfil.id);
      const vm = data.map((m) => {
        const aulas = (m.curso?.disciplinas ?? [])
          .sort((a, b) => a.ordem - b.ordem)
          .flatMap((d) => (d.aulas ?? []).sort((a, b) => a.ordem - b.ordem).map((a) => ({
            id: a.id,
            titulo: a.titulo,
            dur: a.duracao_seg ? `${Math.round(a.duracao_seg / 60)} min` : "",
            done: a.progresso?.[0]?.concluida ?? false,
          })));
        return {
          id: m.curso.id,
          nome: m.curso.nome,
          disciplina: m.curso?.disciplinas?.[0]?.nome ?? "",
          aulas,
        };
      });
      setCursos(vm);
    } catch (e) {
      console.error(e);
      setErro("Não foi possível carregar seus cursos.");
      setCursos([]);
    }
  }, [perfil.id]);

  useEffect(() => { carregar(); }, [carregar]);

  const concluir = async (cursoId, aulaId) => {
    try {
      await concluirAula(perfil.id, perfil.tenant_id, aulaId);
      setCursos((prev) => prev.map((c) =>
        c.id !== cursoId ? c : { ...c, aulas: c.aulas.map((a) => a.id === aulaId ? { ...a, done: true } : a) }
      ));
      toast("+1 Aula concluÃ­da â progresso salvo");
    } catch (e) {
      console.error(e);
      toast("Erro ao salvar progresso");
    }
  };

  const curso = cursos?.[0];

  return (
    <>
      {/* Topbar */}
      <div style={{ position: "sticky", top: 0, zIndex: 40, background: T.paper, borderBottom: `1px solid ${T.line}`, padding: "12px 16px", display: "flex", justifyContent: "space-between", alignItems: "center" }}>
        <LogoKora size={17} />
        <div style={{ display: "flex", gap: 10, alignItems: "center" }}>
          <span style={{ fontSize: 12, fontWeight: 600, color: T.muted }}>{perfil.nome.split(" ")[0]}</span>
          <button onClick={onLogout} style={{ background: "#fff", border: `1px solid ${T.line}`, borderRadius: 999, padding: 6 }}>
            <LogOut size={15} color={T.muted} />
          </button>
        </div>
      </div>

      <div style={{ padding: "16px 16px 110px", maxWidth: 560, margin: "0 auto" }}>
        {cursos === null && <Spinner label="Carregando seus cursosâ¦" />}

        {cursos !== null && erro && (
          <Card style={{ padding: 16, textAlign: "center" }}>
            <div style={{ color: T.danger, fontSize: 14, fontWeight: 600 }}>{erro}</div>
            <button onClick={() => { setCursos(null); setErro(""); carregar(); }}
              style={{ marginTop: 10, padding: "8px 16px", borderRadius: 10, border: "none", background: T.forest, color: "#fff", fontWeight: 600, fontSize: 13 }}>
              <RefreshCw size={13} style={{ verticalAlign: -2, marginRight: 6 }} />Tentar de novo
            </button>
          </Card>
        )}

        {cursos !== null && !erro && cursos.length === 0 && (
          <Card style={{ padding: 24, textAlign: "center" }}>
            <Inbox size={28} color={T.muted} />
            <div className="kl-display" style={{ fontWeight: 700, color: T.ink, marginTop: 8 }}>
              Nenhuma matrícula ativa
            </div>
            <div style={{ fontSize: 13, color: T.muted, marginTop: 4 }}>
              Fale com a secretaria da sua unidade para ativar seu curso.
            </div>
          </Card>
        )}

        {curso && tab === "home" && (
          <div className="kl-fade">
            <Eyebrow>Seu progresso</Eyebrow>
            <h1 className="kl-display" style={{ fontSize: 24, fontWeight: 800, color: T.ink, margin: "4px 0 0" }}>
              OlÃ¡, {perfil.nome.split(" ")[0]}! í ½í±
            </h1>

            <Card style={{ marginTop: 16, padding: 16, background: T.forestDark, border: "none" }}>
              <Eyebrow color={T.amber}>Continue de onde parou</Eyebrow>
              <div className="kl-display" style={{ color: "#fff", fontWeight: 700, fontSize: 17, marginTop: 4 }}>
                {curso.nome}
              </div>
              <div style={{ fontSize: 12, color: "#B9D2C8", marginTop: 2 }}>{curso.disciplina}</div>
              <div style={{ display: "flex", justifyContent: "space-between", alignItems: "flex-end", marginTop: 12 }}>
                <KoraStrings total={curso.aulas.length} done={curso.aulas.filter(a => a.done).length} />
                <button onClick={() => setTab("player")}
                  style={{ background: T.amber, color: T.forestDark, fontWeight: 600, fontSize: 14, padding: "10px 16px", borderRadius: 12, border: "none" }}>
                  Continuar
                </button>
              </div>
              <div style={{ fontSize: 11, color: "#8FB3A5", marginTop: 8 }}>
                {curso.aulas.filter(a => a.done).length} de {curso.aulas.length} aulas concluÃ­das
              </div>
            </Card>

            <div style={{ marginTop: 20 }}><Eyebrow>Minhas disciplinas</Eyebrow></div>
            {cursos.map((c) => {
              const d = c.aulas.filter(a => a.done).length;
              const pct = c.aulas.length ? Math.round((d / c.aulas.length) * 100) : 0;
              return (
                <Card key={c.id} style={{ marginTop: 8, padding: 14, display: "flex", justifyContent: "space-between", alignItems: "center" }}>
                  <div>
                    <div className="kl-display" style={{ fontWeight: 700, fontSize: 14, color: T.ink }}>{c.nome}</div>
                    <div style={{ fontSize: 12, color: T.muted, marginTop: 2 }}>{d}/{c.aulas.length} aulas · {pct}%</div>
                    <div style={{ marginTop: 6 }}>
                      <KoraStrings total={c.aulas.length} done={d} height={30} gap={7} />
                    </div>
                  </div>
                  <button onClick={() => setTab("player")}
                    style={{ background: T.amberSoft, border: "none", borderRadius: 999, padding: 8 }}>
                    <ChevronRight size={18} color={T.forestDark} />
                  </button>
                </Card>
              );
            })}
          </div>
        )}

        {curso && tab === "player" && (
          <div className="kl-fade">
            <Eyebrow>{curso.nome} · {curso.disciplina}</Eyebrow>
            {(() => {
              const atual = curso.aulas.find(a => !a.done) || curso.aulas[curso.aulas.length - 1];
              return (
                <>
                  <h1 className="kl-display" style={{ fontSize: 20, fontWeight: 800, color: T.ink, margin: "4px 0 0" }}>
                    {atual?.titulo}
                  </h1>
                  <div style={{ marginTop: 12, borderRadius: 18, background: T.ink, aspectRatio: "16/9", display: "flex", alignItems: "center", justifyContent: "center" }}>
                    <PlayCircle size={48} color="#fff" strokeWidth={1.4} />
                  </div>
                  {atual && !atual.done && (
                    <button onClick={() => concluir(curso.id, atual.id)}
                      style={{ width: "100%", marginTop: 12, padding: 13, borderRadius: 12, border: "none", background: T.forest, color: "#fff", fontWeight: 600, fontSize: 14 }}>
                      <CheckCircle2 size={15} style={{ verticalAlign: -2, marginRight: 6 }} />
                      Concluir aula
                    </button>
                  )}
                </>
              );
            })()}

            <div style={{ marginTop: 20 }}><Eyebrow>Aulas da disciplina</Eyebrow></div>
            <Card style={{ marginTop: 8, overflow: "hidden" }}>
              {curso.aulas.map((a, i) => (
                <button key={a.id} onClick={() => !a.done && concluir(curso.id, a.id)}
                  style={{ width: "100%", display: "flex", gap: 12, alignItems: "center", textAlign: "left", padding: "12px 14px", background: "transparent", border: "none", borderTop: i ? `1px solid ${T.line}` : "none" }}>
                  {a.done
                    ? <CheckCircle2 size={16} color={T.success} />
                    : <PlayCircle size={16} color={T.forest} />}
                  <div style={{ flex: 1 }}>
                    <div style={{ fontSize: 14, fontWeight: 600, color: T.ink }}>{a.titulo}</div>
                    <div style={{ fontSize: 11, color: T.muted }}>{a.dur}{a.done ? " · concluída" : " · toque para concluir"}</div>
                  </div>
                </button>
              ))}
            </Card>
          </div>
        )}
      </div>

      {/* Bottom nav */}
      {curso && (
        <div style={{ position: "fixed", bottom: 0, left: 0, right: 0, zIndex: 40, background: "#fff", borderTop: `1px solid ${T.line}`, display: "flex", justifyContent: "space-around", padding: "8px 8px calc(8px + env(safe-area-inset-bottom))" }}>
          {[
            { id: "home", label: "Início", icon: Home },
            { id: "player", label: "Aulas", icon: PlayCircle },
          ].map(({ id, label, icon: Icon }) => {
            const active = tab === id;
            return (
              <button key={id} onClick={() => setTab(id)}
                style={{ display: "flex", flexDirection: "column", alignItems: "center", gap: 2, padding: "4px 18px", borderRadius: 12, border: "none", background: active ? T.amberSoft : "transparent" }}>
                <Icon size={20} color={active ? T.forestDark : T.muted} />
                <span style={{ fontSize: 10, fontWeight: 600, color: active ? T.forestDark : T.muted }}>{label}</span>
              </button>
            );
          })}
        </div>
      )}
    </>
  );
}

/* ============================================================
   GESTOR
   ============================================================ */
function GestorApp({ perfil, onLogout, toast }) {
  const [kpis, setKpis] = useState(null);
  const [leads, setLeads] = useState(null);
  const [cursos, setCursos] = useState([]);

  const carregar = useCallback(async () => {
    try {
      const [k, l, c] = await Promise.all([kpisDoTenant(), listarLeads(), listarCursos()]);
      setKpis(k); setLeads(l); setCursos(c);
    } catch (e) {
      console.error(e);
      toast("Erro ao carregar dados do painel");
      setKpis({ alunosAtivos: 0, matriculasHoje: 0, leadsNovosNoMes: 0 });
      setLeads([]);
    }
  }, [toast]);

  useEffect(() => { carregar(); }, [carregar]);

  const converter = async (lead) => {
    if (!cursos.length) { toast("Cadastre um curso antes de converter"); return; }
    try {
      await converterLead(lead, perfil.tenant_id, cursos[0].id);
      toast(`${lead.nome.split(" ")[0]} matriculado(a) em ${cursos[0].nome} â`);
      carregar();
    } catch (e) {
      console.error(e);
      toast("Erro ao converter lead");
    }
  };

  return (
    <div style={{ minHeight: "100vh", background: T.paper }}>
      <div style={{ position: "sticky", top: 0, zIndex: 40, background: T.forestDark, padding: "12px 16px", display: "flex", justifyContent: "space-between", alignItems: "center" }}>
        <LogoKora light size={16} />
        <div style={{ display: "flex", gap: 8, alignItems: "center" }}>
          <span style={{ fontSize: 12, fontWeight: 600, color: "#fff", background: "#FFFFFF22", padding: "4px 10px", borderRadius: 999 }}>
            {perfil.nome.split(" ")[0]} · Gestor
          </span>
          <button onClick={onLogout} style={{ background: "#FFFFFF22", border: "none", borderRadius: 999, padding: 6 }}>
            <LogOut size={15} color="#fff" />
          </button>
        </div>
      </div>

      <div style={{ padding: "16px 16px 40px", maxWidth: 720, margin: "0 auto" }}>
        <Eyebrow>Visão geral · {new Date().toLocaleDateString("pt-BR", { month: "long", year: "numeric" })}</Eyebrow>

        {!kpis ? <Spinner label="Carregando indicadoresâ¦" /> : (
          <div style={{ display: "grid", gridTemplateColumns: "repeat(3, 1fr)", gap: 8, marginTop: 8 }}>
            {[
              { label: "Alunos ativos", val: kpis.alunosAtivos, icon: Users },
              { label: "Matrículas hoje", val: kpis.matriculasHoje, icon: GraduationCap },
              { label: "Leads no mês", val: kpis.leadsNovosNoMes, icon: TrendingUp },
            ].map(({ label, val, icon: Icon }) => (
              <Card key={label} style={{ padding: 14 }}>
                <div style={{ display: "flex", justifyContent: "space-between", alignItems: "center" }}>
                  <span style={{ fontSize: 11, fontWeight: 600, color: T.muted }}>{label}</span>
                  <Icon size={14} color={T.forest} />
                </div>
                <div className="kl-display" style={{ fontSize: 22, fontWeight: 800, color: T.ink, marginTop: 4 }}>{val}</div>
              </Card>
            ))}
          </div>
        )}

        <div style={{ marginTop: 24, display: "flex", justifyContent: "space-between", alignItems: "center" }}>
          <Eyebrow>Pré-matrículas (leads)</Eyebrow>
          <button onClick={carregar} style={{ background: "none", border: "none", color: T.forest, fontSize: 12, fontWeight: 700, display: "flex", alignItems: "center", gap: 4 }}>
            <RefreshCw size={12} /> Atualizar
          </button>
        </div>

        {!leads ? <Spinner label="Carregando leadsâ¦" /> : leads.length === 0 ? (
          <Card style={{ marginTop: 8, padding: 24, textAlign: "center" }}>
            <Inbox size={26} color={T.muted} />
            <div style={{ fontSize: 13, color: T.muted, marginTop: 6 }}>
              Nenhuma pré-matrícula ainda. Quando o formulário público estiver no ar, elas aparecem aqui.
            </div>
          </Card>
        ) : (
          <Card style={{ marginTop: 8, overflow: "hidden" }}>
            {leads.map((l, i) => (
              <div key={l.id} style={{ padding: "12px 14px", borderTop: i ? `1px solid ${T.line}` : "none", display: "flex", justifyContent: "space-between", alignItems: "center", gap: 8, flexWrap: "wrap" }}>
                <div>
                  <div style={{ fontSize: 14, fontWeight: 700, color: T.ink }}>{l.nome}</div>
                  <div style={{ fontSize: 12, color: T.muted }}>
                    {l.email}{l.curso?.nome ? ` · interesse: ${l.curso.nome}` : ""} · {l.origem}
                  </div>
                </div>
                {l.situacao === "convertido" ? (
                  <span style={{ fontSize: 11, fontWeight: 700, color: T.success, background: "#EAF6F0", padding: "4px 10px", borderRadius: 999 }}>
                    Convertido
                  </span>
                ) : (
                  <button onClick={() => converter(l)}
                    style={{ background: T.forest, color: "#fff", border: "none", borderRadius: 10, padding: "8px 12px", fontSize: 12, fontWeight: 700, display: "flex", alignItems: "center", gap: 5 }}>
                    <UserPlus size={13} /> Matricular
                  </button>
                )}
              </div>
            ))}
          </Card>
        )}
      </div>
    </div>
  );
}

/* ============================================================
   RAIZ â sessao e roteamento por perfil
   ============================================================ */
export default function App() {
  const [checking, setChecking] = useState(true);
  const [logged, setLogged] = useState(false);
  const [perfil, setPerfil] = useState(null);
  const [erroPerfil, setErroPerfil] = useState("");
  const [toastMsg, setToastMsg] = useState("");

  const toast = useCallback((msg) => {
    setToastMsg(msg);
    window.clearTimeout(window.__klToast);
    window.__klToast = window.setTimeout(() => setToastMsg(""), 2400);
  }, []);

  const carregarPerfil = useCallback(async () => {
    try {
      const p = await meuPerfil();
      if (!p) { setErroPerfil("Sua conta existe, mas não está vinculada a uma escola. Fale com o administrador."); return; }
      setPerfil(p);
    } catch (e) {
      console.error(e);
      setErroPerfil("Não foi possível carregar seu perfil.");
    }
  }, []);

  useEffect(() => {
    supabase.auth.getSession().then(({ data: { session } }) => {
      setLogged(!!session);
      setChecking(false);
      if (session) carregarPerfil();
    });
    const { data: sub } = supabase.auth.onAuthStateChange((_ev, session) => {
      setLogged(!!session);
      if (session) carregarPerfil();
      else { setPerfil(null); setErroPerfil(""); }
    });
    return () => sub.subscription.unsubscribe();
  }, [carregarPerfil]);

  const logout = async () => { await sair(); };

  return (
    <div className="kl-body" style={{ minHeight: "100vh", background: T.paper }}>
      <style>{fontStyles}</style>

      {checking && <Spinner label="Iniciandoâ¦" />}

      {!checking && !logged && <LoginScreen onLogged={() => {}} />}

      {!checking && logged && !perfil && !erroPerfil && <Spinner label="Carregando seu perfilâ¦" />}

      {!checking && logged && erroPerfil && (
        <div style={{ display: "flex", flexDirection: "column", alignItems: "center", padding: 48, gap: 12 }}>
          <AlertTriangle size={28} color={T.danger} />
          <div style={{ fontSize: 14, color: T.ink, textAlign: "center", maxWidth: 320 }}>{erroPerfil}</div>
          <button onClick={logout} style={{ padding: "10px 20px", borderRadius: 12, border: "none", background: T.forest, color: "#fff", fontWeight: 600 }}>
            Sair
          </button>
        </div>
      )}

      {!checking && logged && perfil && (
        ["super_admin", "gestor"].includes(perfil.perfil)
          ? <GestorApp perfil={perfil} onLogout={logout} toast={toast} />
          : <AlunoApp perfil={perfil} onLogout={logout} toast={toast} />
      )}

      <Toast msg={toastMsg} />
    </div>
  );
}
