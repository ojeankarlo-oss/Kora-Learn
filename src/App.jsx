// ============================================================
// KORA LEARN — App conectado ao Supabase
// Salvar em: src/App.jsx  (projeto Vite React)
// Depende de: src/lib/supabaseClient.js e src/lib/api.js
// ============================================================
import React, { useState, useEffect, useCallback, createContext, useContext } from "react";
import {
  Home, PlayCircle, BookOpen, Bell, ChevronRight, ChevronDown, CheckCircle2, Lock,
  Flame, Trophy, Star, Users, AlertTriangle, LogOut, GraduationCap,
  FileText, Clock, TrendingUp, Loader2, Inbox, UserPlus, RefreshCw,
  Eye, EyeOff, MapPin, Building2, Wallet, HeartHandshake
} from "lucide-react";
import { supabase } from "./lib/supabaseClient";
import { TEMA_PADRAO, montarTema, aplicarAcessibilidade } from "./theme";
import ControleAcessibilidade from "./AcessibilidadeControle";
import PreMatricula from "./PreMatricula";
import PrimeiroAcesso from "./PrimeiroAcesso";
import Cadastro from "./Cadastro";
import CriarEscola from "./CriarEscola";
import AceiteScreen, { LGPD_VERSAO } from "./AceiteScreen";
import MeusDocumentos from "./MeusDocumentos";
import Financeiro from "./Financeiro";
import FinanceiroGestor from "./FinanceiroGestor";
import RH from "./RH";
import VinculosProfessorTurma from "./VinculosProfessorTurma";
import Chamada from "./Chamada";
import FrequenciaAluno from "./FrequenciaAluno";
import DocumentosAlunoModal from "./GestorDocumentos";
import ContratoConfig from "./ContratoConfig";
import { CONTRATO_PADRAO_VERSAO } from "./contratoPadrao";
import {
  entrarComEmail, sair, meuPerfil, meusCursos, concluirAula, meuStatusOnboarding,
  kpisDoTenant, listarLeads, listarCursos, converterLead,
  listarMatriculas, atualizarSituacaoMatricula, meuTenant, salvarConfigTenant,
  listarUnidades, criarUnidade, alternarUnidade, listarUnidadesPublico,
  contratoAtivo, meusAceites, registrarAceite, salvarContrato,
  enviarDocumento, meusDocumentos, documentosDoTenant, avaliarDocumento, urlDocumento,
  salvarPreferenciasAcessibilidade,
} from "./lib/api";

/* ---------- Contexto de tema (white-label) ---------- */
const TemaContext = createContext(TEMA_PADRAO);

export function useTema() {
  return useContext(TemaContext);
}

/* ---------- Identidade visual (padrão) ---------- */
const T = TEMA_PADRAO;

/* ---------- Necessidades específicas declaradas na pré-matrícula ---------- */
const NECESSIDADE_LABELS = {
  baixa_visao: "Baixa visão",
  cegueira: "Cegueira",
  surdez: "Surdez ou baixa audição",
  fisica_motora: "Deficiência física/motora",
  tea: "TEA",
  tdah: "TDAH",
};
function formatarNecessidade(chave) {
  if (chave.startsWith("outra:")) return `Outra: ${chave.slice(6)}`;
  return NECESSIDADE_LABELS[chave] || chave;
}

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
  const T = useTema();
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
  const T = useTema();
  
  // Se houver logo customizado, exibir a imagem
  if (T.logo_url && !light) {
    return (
      <div style={{ display: "flex", alignItems: "center", gap: 8 }}>
        <img 
          src={T.logo_url} 
          alt={T.nomeMarca}
          style={{ height: size, borderRadius: 8, objectFit: "contain" }}
        />
        <span className="kl-display" style={{ fontWeight: 800, fontSize: size, color: T.ink }}>
          {T.nomeMarca.split(" ")[0]}<span style={{ color: T.forest }}> {T.nomeMarca.split(" ").slice(1).join(" ")}</span>
        </span>
      </div>
    );
  }
  
  // Caso contrário, usar o logo desenhado
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
        {T.nomeMarca.split(" ")[0]}<span style={{ color: light ? T.amber : T.forest }}> {T.nomeMarca.split(" ").slice(1).join(" ")}</span>
      </span>
    </div>
  );
}

function Card({ children, style = {} }) {
  const T = useTema();
  return (
    <div style={{ background: T.card, border: `1px solid ${T.line}`, borderRadius: 18, ...style }}>
      {children}
    </div>
  );
}

function Eyebrow({ children, color }) {
  const T = useTema();
  return <div className="kl-eyebrow" style={{ color: color ?? T.muted }}>{children}</div>;
}

function Toast({ msg }) {
  const T = useTema();
  if (!msg) return null;
  return (
    <div className="kl-fade" style={{ position: "fixed", bottom: 84, left: "50%", transform: "translateX(-50%)", zIndex: 50 }}>
      <div style={{ background: T.ink, color: "#fff", padding: "8px 16px", borderRadius: 999, fontSize: 14, fontWeight: 500 }}>
        {msg}
      </div>
    </div>
  );
}

function Spinner({ label = "Carregando…" }) {
  const T = useTema();
  return (
    <div style={{ display: "flex", flexDirection: "column", alignItems: "center", gap: 10, padding: 48, color: T.muted }}>
      <Loader2 size={28} className="kl-spin" color={T.forest} />
      <span style={{ fontSize: 13 }}>{label}</span>
    </div>
  );
}

function PasswordField({ label, value, onChange, placeholder, onKeyDown, autoComplete = "current-password", containerStyle = {} }) {
  const T = useTema();
  const [show, setShow] = useState(false);

  return (
    <div style={{ marginTop: 12, ...containerStyle }}>
      {label && (
        <label style={{ display: "block", fontSize: 12, fontWeight: 600, color: T.muted, marginBottom: 4 }}>{label}</label>
      )}
      <div style={{ position: "relative", marginTop: 4 }}>
        <input
          type={show ? "text" : "password"}
          value={value}
          onChange={onChange}
          placeholder={placeholder}
          onKeyDown={onKeyDown}
          autoComplete={autoComplete}
          style={{ width: "100%", boxSizing: "border-box", padding: "10px 42px 10px 12px", borderRadius: 12, border: `1.5px solid ${T.line}`, fontSize: 14, color: T.ink, outline: "none" }}
        />
        <button
          type="button"
          aria-label={show ? "Ocultar senha" : "Mostrar senha"}
          onClick={() => setShow((prev) => !prev)}
          style={{ position: "absolute", top: "50%", right: 8, transform: "translateY(-50%)", background: "transparent", border: "none", color: T.muted, display: "flex", alignItems: "center", justifyContent: "center", padding: 4 }}
        >
          {show ? <EyeOff size={18} /> : <Eye size={18} />}
        </button>
      </div>
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

  const irParaPrimeiroAcesso = () => {
    window.location.hash = "#/primeiro-acesso";
  };

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

        <PasswordField
          label="Senha"
          value={senha}
          onChange={(e) => setSenha(e.target.value)}
          placeholder="••••••••"
          onKeyDown={(e) => e.key === "Enter" && entrar()}
          autoComplete="current-password"
        />

        {erro && (
          <div style={{ marginTop: 12, padding: 10, borderRadius: 12, background: "#FBEFEC", color: T.danger, fontSize: 13, fontWeight: 500 }}>
            {erro}
          </div>
        )}

        <button onClick={entrar} disabled={loading || !email || !senha}
          style={{ width: "100%", marginTop: 18, padding: 13, borderRadius: 12, border: "none", background: loading ? "#9DB5AC" : T.forest, color: "#fff", fontWeight: 600, fontSize: 14 }}>
          {loading ? "Entrando…" : "Entrar"}
        </button>

        <button onClick={() => { window.location.hash = "#/recuperar-senha"; }} style={{ width: "100%", marginTop: 10, background: "transparent", border: "none", color: T.forest, fontSize: 13, fontWeight: 600 }}>
          Esqueci minha senha
        </button>

        <button onClick={irParaPrimeiroAcesso} style={{ width: "100%", marginTop: 10, background: "transparent", border: "none", color: T.forest, fontSize: 13, fontWeight: 600 }}>
          Primeiro acesso? Crie sua senha
        </button>

        <button onClick={() => { window.location.hash = "#/cadastro"; }} style={{ width: "100%", marginTop: 10, background: "transparent", border: "none", color: T.muted, fontSize: 12, fontWeight: 600 }}>
          Ainda não tem conta? Cadastre-se
        </button>
      </div>
      <div style={{ marginTop: 20, fontSize: 12, color: "#9DBBAF" }}>
        KORA Gestão Educacional · MVP
      </div>
    </div>
  );
}

function RecuperarSenhaScreen() {
  const [email, setEmail] = useState("");
  const [erro, setErro] = useState("");
  const [sucesso, setSucesso] = useState("");
  const [loading, setLoading] = useState(false);
  const [prefFonte, setPrefFonte] = useState("normal");
  const [altoContraste, setAltoContraste] = useState(false);
  const T = aplicarAcessibilidade(TEMA_PADRAO, { prefFonte, altoContraste });

  const voltarAoLogin = () => {
    window.location.hash = "#/";
  };

  const enviar = async (event) => {
    event.preventDefault();
    setErro("");
    setSucesso("");

    const emailFormatado = email.trim().toLowerCase();
    if (!emailFormatado) {
      setErro("Informe seu e-mail para continuar.");
      return;
    }

    setLoading(true);
    try {
            await supabase.auth.resetPasswordForEmail(emailFormatado, {
        redirectTo: `${window.location.origin}/Kora-Learn/`,
      });
      setSucesso("Se este e-mail estiver cadastrado, enviamos um link de recuperação. Verifique também o spam.");
      setEmail("");
    } catch (error) {
      setSucesso("Se este e-mail estiver cadastrado, enviamos um link de recuperação. Verifique também o spam.");
    } finally {
      setLoading(false);
    }
  };

  return (
    <div className="kl-body" style={{ minHeight: "100vh", background: T.forestDark, display: "flex", alignItems: "center", justifyContent: "center", padding: 24, zoom: "var(--kl-font-scale)" }}>
      <ControleAcessibilidade prefFonte={prefFonte} altoContraste={altoContraste} onFonte={setPrefFonte} onContraste={setAltoContraste} T={T} />
      <div style={{ width: "100%", maxWidth: 400, background: "#fff", borderRadius: 24, padding: 24 }}>
        <div style={{ textAlign: "center", marginBottom: 18 }}>
          <LogoKora light={false} size={24} />
          <div className="kl-display" style={{ fontSize: 18, fontWeight: 700, color: T.ink, marginTop: 12 }}>Recuperar senha</div>
          <div style={{ fontSize: 13, color: T.muted, marginTop: 8, lineHeight: 1.5 }}>
            Informe seu e-mail para receber um link de redefinição.
          </div>
        </div>

        <form onSubmit={enviar}>
          <label style={{ display: "block", fontSize: 12, fontWeight: 600, color: T.muted, marginBottom: 4 }}>E-mail</label>
          <input
            type="email"
            value={email}
            onChange={(event) => setEmail(event.target.value)}
            placeholder="voce@exemplo.com"
            onKeyDown={(event) => event.key === "Enter" && enviar(event)}
            style={{ width: "100%", boxSizing: "border-box", padding: "10px 12px", borderRadius: 12, border: `1.5px solid ${T.line}`, fontSize: 14, color: T.ink, outline: "none" }}
          />

          {erro && (
            <div style={{ marginTop: 12, padding: 10, borderRadius: 12, background: "#FBEFEC", color: T.danger, fontSize: 13, fontWeight: 500 }}>
              {erro}
            </div>
          )}

          {sucesso && (
            <div style={{ marginTop: 12, padding: 10, borderRadius: 12, background: "#EAF6F0", color: T.forest, fontSize: 13, fontWeight: 500 }}>
              {sucesso}
            </div>
          )}

          <button type="submit" disabled={loading} style={{ width: "100%", marginTop: 16, padding: 13, borderRadius: 12, border: "none", background: loading ? "#9DB5AC" : T.forest, color: "#fff", fontWeight: 600, fontSize: 14 }}>
            {loading ? "Enviando…" : "Enviar link"}
          </button>
        </form>

        <button onClick={voltarAoLogin} style={{ width: "100%", marginTop: 10, background: "transparent", border: "none", color: T.forest, fontSize: 13, fontWeight: 600 }}>
          Voltar ao login
        </button>
      </div>
    </div>
  );
}

function RedefinirSenhaScreen({ onLogged }) {
  const [senha, setSenha] = useState("");
  const [confirmarSenha, setConfirmarSenha] = useState("");
  const [erro, setErro] = useState("");
  const [info, setInfo] = useState("");
  const [loading, setLoading] = useState(false);
  const [recoveryReady, setRecoveryReady] = useState(false);
  const [linkErro, setLinkErro] = useState(false);
  const [prefFonte, setPrefFonte] = useState("normal");
  const [altoContraste, setAltoContraste] = useState(false);
  const T = aplicarAcessibilidade(TEMA_PADRAO, { prefFonte, altoContraste });

  const reqTamanho = senha.length >= 8;
  const reqIguais = confirmarSenha.length > 0 && senha === confirmarSenha;
  const senhasDivergem = confirmarSenha.length > 0 && senha !== confirmarSenha;
  const requisitosOk = reqTamanho && reqIguais;

  useEffect(() => {
    let ativo = true;
    let jaValidado = false;

    const marcarValidado = () => {
      if (!ativo || jaValidado) return;
      jaValidado = true;
      setRecoveryReady(true);
      setLinkErro(false);
    };

    const validarSessao = async () => {
      const { data: { session } } = await supabase.auth.getSession();
      if (ativo && session) {
        marcarValidado();
      }
    };

    validarSessao();

    const { data: sub } = supabase.auth.onAuthStateChange((event, session) => {
      if (!ativo) return;
      if (event === "PASSWORD_RECOVERY" || session) {
        marcarValidado();
      }
    });

    const timeoutId = setTimeout(() => {
      if (ativo && !jaValidado) {
        setLinkErro(true);
      }
    }, 5000);

    return () => {
      ativo = false;
      clearTimeout(timeoutId);
      sub.subscription.unsubscribe();
    };
  }, []);

  const redefinir = async (event) => {
    event.preventDefault();
    setErro("");
    setInfo("");
    setLinkErro(false);

    if (senha.length < 8) {
      setErro("A senha deve ter pelo menos 8 caracteres.");
      return;
    }

    if (senha !== confirmarSenha) {
      setErro("As senhas não conferem.");
      return;
    }

    setLoading(true);
    try {
      const { error } = await supabase.auth.updateUser({ password: senha });
      if (error) {
        const msg = error.message?.toLowerCase() || "";
        const isExpired = msg.includes("expired") || msg.includes("invalid") || msg.includes("token");
        if (isExpired) {
          setErro("O link de recuperação expirou ou é inválido. Solicite um novo link e tente novamente.");
          setLinkErro(true);
        } else {
          setErro("Não foi possível redefinir a senha. Solicite um novo link e tente novamente.");
        }
        return;
      }

      setInfo("Senha redefinida! Entrando...");
      window.setTimeout(() => {
        if (onLogged) {
          onLogged();
        } else {
          window.location.hash = "#/";
        }
      }, 900);
    } catch (error) {
      setErro("Não foi possível redefinir a senha. Solicite um novo link e tente novamente.");
    } finally {
      setLoading(false);
    }
  };

  return (
    <div className="kl-body" style={{ minHeight: "100vh", background: T.forestDark, display: "flex", alignItems: "center", justifyContent: "center", padding: 24, zoom: "var(--kl-font-scale)" }}>
      <ControleAcessibilidade prefFonte={prefFonte} altoContraste={altoContraste} onFonte={setPrefFonte} onContraste={setAltoContraste} T={T} />
      <div style={{ width: "100%", maxWidth: 400, background: "#fff", borderRadius: 24, padding: 24 }}>
        <div style={{ textAlign: "center", marginBottom: 18 }}>
          <LogoKora light={false} size={24} />
          <div className="kl-display" style={{ fontSize: 18, fontWeight: 700, color: T.ink, marginTop: 12 }}>Redefinir senha</div>
          <div style={{ fontSize: 13, color: T.muted, marginTop: 8, lineHeight: 1.5 }}>
            Crie uma nova senha para acessar a plataforma.
          </div>
        </div>

        {!recoveryReady && !linkErro && (
          <div style={{ marginBottom: 12, padding: 10, borderRadius: 12, background: "#F2F6F4", color: T.muted, fontSize: 13 }}>
            Validando o link de recuperação...
          </div>
        )}

        {linkErro && !recoveryReady && (
          <div style={{ marginBottom: 12, padding: 14, borderRadius: 12, background: "#FBEFEC", color: T.danger, fontSize: 13, fontWeight: 500 }}>
            Link inválido ou expirado.
            <button
              onClick={() => { window.location.hash = "#/recuperar-senha"; }}
              style={{ display: "block", width: "100%", marginTop: 12, padding: 12, border: "none", borderRadius: 12, background: T.forest, color: "#fff", fontWeight: 600, fontSize: 13, cursor: "pointer" }}
            >
              Pedir novo link
            </button>
          </div>
        )}

        <form onSubmit={redefinir}>
          <PasswordField
            label="Nova senha"
            value={senha}
            onChange={(event) => setSenha(event.target.value)}
            placeholder="Mínimo 8 caracteres"
            autoComplete="new-password"
          />

          <PasswordField
            label="Confirmar senha"
            value={confirmarSenha}
            onChange={(event) => setConfirmarSenha(event.target.value)}
            placeholder="Repita a senha"
            autoComplete="new-password"
          />

          <div style={{ margin: "4px 0 12px", display: "flex", flexDirection: "column", gap: 6 }}>
            <div style={{ display: "flex", alignItems: "center", gap: 8, fontSize: 13, color: reqTamanho ? "#2E7D32" : T.muted }}>
              <span style={{ display: "inline-flex", alignItems: "center", justifyContent: "center", width: 18, height: 18, borderRadius: "50%", border: reqTamanho ? "none" : "1.5px solid #C9CFCC", background: reqTamanho ? "#2E7D32" : "transparent", color: "#fff", fontSize: 11, fontWeight: 700 }}>{reqTamanho ? "✓" : ""}</span>
              Pelo menos 8 caracteres
            </div>
            <div style={{ display: "flex", alignItems: "center", gap: 8, fontSize: 13, color: reqIguais ? "#2E7D32" : T.muted }}>
              <span style={{ display: "inline-flex", alignItems: "center", justifyContent: "center", width: 18, height: 18, borderRadius: "50%", border: reqIguais ? "none" : "1.5px solid #C9CFCC", background: reqIguais ? "#2E7D32" : "transparent", color: "#fff", fontSize: 11, fontWeight: 700 }}>{reqIguais ? "✓" : ""}</span>
              As senhas são idênticas
            </div>
            {senhasDivergem && (
              <div style={{ fontSize: 13, color: T.danger, fontWeight: 500 }}>
                As senhas não coincidem
              </div>
            )}
          </div>

          {erro && (
            <div style={{ marginTop: 12, padding: 10, borderRadius: 12, background: "#FBEFEC", color: T.danger, fontSize: 13, fontWeight: 500 }}>
              {erro}
            </div>
          )}

          {linkErro && (
            <button onClick={() => { window.location.hash = "#/recuperar-senha"; }}
              style={{ width: "100%", marginTop: 10, padding: 12, borderRadius: 12, border: "none", background: T.forest, color: "#fff", fontWeight: 600, fontSize: 13 }}>
              Pedir novo link
            </button>
          )}

          {info && (
            <div style={{ marginTop: 12, padding: 10, borderRadius: 12, background: "#EAF6F0", color: T.forest, fontSize: 13, fontWeight: 500 }}>
              {info}
            </div>
          )}

          <button type="submit" disabled={loading || !recoveryReady || !requisitosOk} style={{ width: "100%", marginTop: 16, padding: 13, borderRadius: 12, border: "none", background: loading || !recoveryReady || !requisitosOk ? "#9DB5AC" : T.forest, color: "#fff", fontWeight: 600, fontSize: 14, cursor: loading || !recoveryReady || !requisitosOk ? "not-allowed" : "pointer" }}>
            {loading ? "Salvando…" : "Redefinir senha"}
          </button>
        </form>

        <button onClick={() => { window.location.hash = "#/"; }} style={{ width: "100%", marginTop: 10, background: "transparent", border: "none", color: T.forest, fontSize: 13, fontWeight: 600 }}>
          Voltar ao login
        </button>
      </div>
    </div>
  );
}

/* ============================================================
   ALUNO
   ============================================================ */
function AlunoApp({ perfil, onLogout, toast }) {
  const T = useTema();
  const [tab, setTab] = useState("home");
  const [cursos, setCursos] = useState(null); // null = carregando
  const [erro, setErro] = useState("");
  const [aceiteStatus, setAceiteStatus] = useState("verificando"); // verificando | pendente | ok | erro
  const [aceiteTentativa, setAceiteTentativa] = useState(0);

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

  useEffect(() => {
    let ativo = true;
    (async () => {
      setAceiteStatus("verificando");
      try {
        const [aceites, contrato] = await Promise.all([meusAceites(), contratoAtivo()]);
        if (!ativo) return;
        const versaoContratoVigente = String(contrato?.versao || CONTRATO_PADRAO_VERSAO);
        const temLgpd = aceites.some((a) => a.tipo === "lgpd" && a.versao === LGPD_VERSAO);
        const temContrato = aceites.some((a) => a.tipo === "contrato" && a.versao === versaoContratoVigente);
        setAceiteStatus(temLgpd && temContrato ? "ok" : "pendente");
      } catch (e) {
        console.error(e);
        if (ativo) setAceiteStatus("erro");
      }
    })();
    return () => { ativo = false; };
  }, [perfil.id, aceiteTentativa]);

  const concluir = async (cursoId, aulaId) => {
    try {
      await concluirAula(perfil.id, perfil.tenant_id, aulaId);
      setCursos((prev) => prev.map((c) =>
        c.id !== cursoId ? c : { ...c, aulas: c.aulas.map((a) => a.id === aulaId ? { ...a, done: true } : a) }
      ));
      toast("+1 Aula concluída ✓ progresso salvo");
    } catch (e) {
      console.error(e);
      toast("Erro ao salvar progresso");
    }
  };

  const curso = cursos?.[0];

  if (aceiteStatus === "verificando" || cursos === null) {
    return (
      <div style={{ minHeight: "100vh", display: "flex", alignItems: "center", justifyContent: "center" }}>
        <div style={{ display: "flex", alignItems: "center", gap: 8, color: T.muted, fontSize: 13 }}>
          <RefreshCw className="kl-spin" size={16} /> Carregando seu portal...
        </div>
      </div>
    );
  }

  if (aceiteStatus === "erro") {
    return (
      <div style={{ minHeight: "100vh", display: "flex", flexDirection: "column", alignItems: "center", justifyContent: "center", gap: 12, padding: 24, textAlign: "center" }}>
        <AlertTriangle size={28} color={T.danger} />
        <div style={{ fontSize: 14, color: T.ink, maxWidth: 320 }}>
          Não foi possível verificar seus termos de aceite. Verifique sua conexão e tente novamente.
        </div>
        <button onClick={() => setAceiteTentativa((t) => t + 1)} style={{ background: T.forest, color: "#fff", border: "none", borderRadius: 10, padding: "10px 18px", fontSize: 13, fontWeight: 700 }}>
          Tentar novamente
        </button>
      </div>
    );
  }

  if (aceiteStatus === "pendente") {
    return (
      <AceiteScreen
        perfil={perfil}
        curso={curso}
        toast={toast}
        T={T}
        onAceito={() => setAceiteStatus("ok")}
      />
    );
  }

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
        {cursos === null && <Spinner label="Carregando seus cursos…" />}

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
              Olá, {perfil.nome.split(" ")[0]}! 👋
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
                {curso.aulas.filter(a => a.done).length} de {curso.aulas.length} aulas concluídas
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

            <FrequenciaAluno T={T} />
          </div>
        )}

        {!curso && cursos !== null && !erro && tab === "home" && <FrequenciaAluno T={T} />}

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

      {tab === "documentos" && (
          <MeusDocumentos perfil={perfil} toast={toast} T={T} />
        )}

        {tab === "financeiro" && (
          <Financeiro perfil={perfil} T={T} />
        )}

        {/* Bottom nav */}
      {curso && (
        <div style={{ position: "fixed", bottom: 0, left: 0, right: 0, zIndex: 40, background: "#fff", borderTop: `1px solid ${T.line}`, display: "flex", justifyContent: "space-around", padding: "8px 8px calc(8px + env(safe-area-inset-bottom))" }}>
          {[
            { id: "home", label: "Início", icon: Home },
            { id: "player", label: "Aulas", icon: PlayCircle },
        ...(T.modulos?.documentos ? [{ id: "documentos", label: "Documentos", icon: FileText }] : []),
              ...(T.modulos?.financeiro ? [{ id: "financeiro", label: "Financeiro", icon: Wallet }] : []),
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
function GestorApp({ perfil, onLogout, toast, setTema }) {
  const T = useTema();
  const [activeTab, setActiveTab] = useState("leads");
  const [docAluno, setDocAluno] = useState(null);
  const [docsPendentes, setDocsPendentes] = useState(0);
  const [kpis, setKpis] = useState(null);
  const [leads, setLeads] = useState(null);
  const [cursos, setCursos] = useState([]);
  const [matriculas, setMatriculas] = useState([]);
  const [matriculasLoading, setMatriculasLoading] = useState(false);
  const [matriculasError, setMatriculasError] = useState("");
  const [buscaAluno, setBuscaAluno] = useState("");
  const [unidades, setUnidades] = useState([]);
  const [unidadesLoading, setUnidadesLoading] = useState(false);
  const [unidadesError, setUnidadesError] = useState("");
  const [unidadeFiltro, setUnidadeFiltro] = useState("");
  const [novaUnidadeNome, setNovaUnidadeNome] = useState("");
  const [novaUnidadeCidade, setNovaUnidadeCidade] = useState("");
  const [novaUnidadeEstado, setNovaUnidadeEstado] = useState("");
  const [novaUnidadePais, setNovaUnidadePais] = useState("BR");
  const [criandoUnidade, setCriandoUnidade] = useState(false);
  
  // Configurações
  const [configNome, setConfigNome] = useState("");
  const [configLogoUrl, setConfigLogoUrl] = useState("");
  const [configCorPrimaria, setConfigCorPrimaria] = useState(T.forest);
  const [configCorDestaque, setConfigCorDestaque] = useState(T.amber);
  const [configSlogan, setConfigSlogan] = useState(T.slogan);
  const [configModulos, setConfigModulos] = useState(T.modulos || {});
  const [savingConfig, setSavingConfig] = useState(false);
  const [leadExpandidoId, setLeadExpandidoId] = useState(null);
  const [alunoExpandidoId, setAlunoExpandidoId] = useState(null);

  const carregar = useCallback(async () => {
    try {
      const [k, l, c] = await Promise.all([kpisDoTenant(), listarLeads(unidadeFiltro || undefined) /* TODO (fase futura): filtrar KPIs por unidade tambem */, listarCursos()]);
      setKpis(k); setLeads(l); setCursos(c);
    } catch (e) {
      console.error(e);
      toast("Erro ao carregar dados do painel");
      setKpis({ alunosAtivos: 0, matriculasHoje: 0, leadsNovosNoMes: 0 });
      setLeads([]);
    }
  }, [toast, unidadeFiltro]);

  useEffect(() => { carregar(); }, [carregar]);

  const atualizarDocsPendentes = useCallback(async () => {
    try {
      const lista = await documentosDoTenant();
      setDocsPendentes(lista.filter((d) => d.situacao === "pendente").length);
    } catch (e) {
      console.error(e);
    }
  }, []);

  useEffect(() => {
    if (T.modulos?.documentos) atualizarDocsPendentes();
  }, [T.modulos?.documentos, atualizarDocsPendentes]);

  const carregarMatriculas = useCallback(async () => {
    setMatriculasLoading(true);
    setMatriculasError("");
    try {
      const data = await listarMatriculas(unidadeFiltro || undefined);
      setMatriculas(data);
    } catch (e) {
      console.error(e);
      setMatriculasError("Não foi possível carregar os alunos matriculados.");
      setMatriculas([]);
    } finally {
      setMatriculasLoading(false);
    }
  }, [unidadeFiltro]);

  useEffect(() => { carregarMatriculas(); }, [carregarMatriculas]);

  // Recarrega leads/kpis e matrículas juntos: usada após qualquer ação de
  // escrita que possa afetar as duas listas (ex.: matricular move um lead
  // para matrículas; cancelar/reativar matrícula muda o KPI de alunos ativos).
  const carregarPainel = useCallback(async () => {
    await Promise.all([carregar(), carregarMatriculas()]);
  }, [carregar, carregarMatriculas]);

  const carregarUnidades = useCallback(async () => {
    setUnidadesLoading(true);
    setUnidadesError("");
    try {
      const data = await listarUnidades();
      setUnidades(data);
    } catch (e) {
      console.error(e);
      setUnidadesError("Não foi possível carregar as unidades.");
      setUnidades([]);
    } finally {
      setUnidadesLoading(false);
    }
  }, []);
  useEffect(() => { carregarUnidades(); }, [carregarUnidades]);

  // Carregar dados atuais de configuração quando a aba é ativada
  useEffect(() => {
    if (activeTab === "configuracoes") {
      setConfigNome(T.nomeMarca);
      setConfigLogoUrl(T.logo_url || "");
      setConfigCorPrimaria(T.forest);
      setConfigCorDestaque(T.amber);
      setConfigSlogan(T.slogan);
      setConfigModulos(T.modulos || {});
    }
  }, [activeTab, T]);

  const converter = async (lead) => {
    if (!cursos.length) { toast("Cadastre um curso antes de converter"); return; }
    try {
      await converterLead(lead, perfil.tenant_id, cursos[0].id);
      toast(`${lead.nome.split(" ")[0]} matriculado(a) em ${cursos[0].nome} ✓`);
      await carregarPainel();
    } catch (e) {
      console.error(e);
      toast("Erro ao converter lead");
    }
  };

  const handleSituacaoMatricula = async (matricula, novaSituacao) => {
    const confirmar = window.confirm(
      novaSituacao === "cancelada"
        ? `Cancelar a matrícula de ${matricula.aluno?.nome ?? "este aluno"}?`
        : `Reativar a matrícula de ${matricula.aluno?.nome ?? "este aluno"}?`
    );
    if (!confirmar) return;
    try {
      await atualizarSituacaoMatricula(matricula.id, novaSituacao);
      toast("Situação atualizada");
      await carregarPainel();
    } catch (e) {
      console.error(e);
      toast("Erro ao atualizar a matrícula");
    }
  };
  const handleCriarUnidade = async (e) => {
    e.preventDefault();
    if (!novaUnidadeNome.trim()) { toast("Informe o nome da unidade"); return; }
    setCriandoUnidade(true);
    try {
      await criarUnidade({
        nome: novaUnidadeNome.trim(),
        cidade: novaUnidadeCidade.trim(),
        estado: novaUnidadeEstado.trim(),
        pais: novaUnidadePais.trim() || "BR",
      });
      toast("Unidade criada ✓");
      setNovaUnidadeNome(""); setNovaUnidadeCidade(""); setNovaUnidadeEstado(""); setNovaUnidadePais("BR");
      carregarUnidades();
    } catch (e) {
      console.error(e);
      toast("Erro ao criar unidade");
    } finally {
      setCriandoUnidade(false);
    }
  };
  const handleAlternarUnidade = async (unidade) => {
    const novoAtivo = !unidade.ativo;
    const confirmar = window.confirm(
      `${novoAtivo ? "Reativar" : "Desativar"} a unidade "${unidade.nome}"?`
    );
    if (!confirmar) return;
    try {
      await alternarUnidade(unidade.id, novoAtivo);
      toast(`Unidade ${novoAtivo ? "reativada" : "desativada"} ✓`);
      carregarUnidades();
    } catch (e) {
      console.error(e);
      toast("Erro ao atualizar unidade");
    }
  };

  const salvarConfiguracao = async () => {
    setSavingConfig(true);
    try {
      await salvarConfigTenant({
        nome: configNome,
        logo_url: configLogoUrl,
        config: {
          marca: {
            cor_primaria: configCorPrimaria,
            cor_destaque: configCorDestaque,
            slogan: configSlogan,
          },
          modulos: configModulos,
        },
      });
      toast("Configurações salvas! 🎉");
      
      // Atualizar o tema na hora
      const novoTema = montarTema({
        id: "",
        nome: configNome,
        slug: "",
        logo_url: configLogoUrl,
        marca: {
          cor_primaria: configCorPrimaria,
          cor_destaque: configCorDestaque,
          slogan: configSlogan,
        },
        modulos: configModulos,
      });
      setTema(novoTema);
    } catch (e) {
      console.error(e);
      toast("Erro ao salvar as configurações");
    } finally {
      setSavingConfig(false);
    }
  };

  const matriculasFiltradas = matriculas.filter((m) => {
    const termo = buscaAluno.trim().toLowerCase();
    if (!termo) return true;
    const nome = (m.aluno?.nome ?? "").toLowerCase();
    const email = (m.aluno?.email ?? "").toLowerCase();
    return nome.includes(termo) || email.includes(termo);
  });

  const totaisPorSituacao = matriculas.reduce((acc, m) => {
    acc[m.situacao] = (acc[m.situacao] ?? 0) + 1;
    return acc;
  }, {});

  const badgeStyle = (situacao) => {
    switch (situacao) {
      case "ativa":
        return { background: "#EAF6F0", color: T.success };
      case "concluida":
        return { background: "#EAF2FB", color: "#2F5E9E" };
      case "cancelada":
        return { background: "#FCECEA", color: T.danger };
      case "trancada":
        return { background: "#FFF5E3", color: T.amber };
      default:
        return { background: T.paper, color: T.muted };
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

        {!kpis ? <Spinner label="Carregando indicadores…" /> : (
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

    <div style={{ marginTop: 20, display: "flex", alignItems: "center", gap: 8, flexWrap: "wrap" }}>
            <label style={{ fontSize: 12, fontWeight: 600, color: T.muted }}>Unidade</label>
            <select
              value={unidadeFiltro}
              onChange={(e) => setUnidadeFiltro(e.target.value)}
              style={{ padding: "8px 12px", borderRadius: 10, border: "1px solid " + T.line, fontSize: 13 }}
            >
              <option value="">Todas as unidades</option>
              {unidades.map((u) => (
                <option key={u.id} value={u.id}>{u.nome}</option>
              ))}
            </select>
          </div>
          <div style={{ marginTop: 24, display: "flex", gap: 8 }}>
      <button onClick={() => setActiveTab("leads")} style={{ background: activeTab === "leads" ? T.forest : "none", color: activeTab === "leads" ? "#fff" : T.muted, border: activeTab === "leads" ? "none" : "1px solid " + T.line, borderRadius: 999, padding: "6px 14px", fontSize: 12, fontWeight: 700 }}>
        Leads
      </button>
      {T.modulos?.alunos !== false && (
        <button onClick={() => setActiveTab("alunos")} style={{ background: activeTab === "alunos" ? T.forest : "none", color: activeTab === "alunos" ? "#fff" : T.muted, border: activeTab === "alunos" ? "none" : "1px solid " + T.line, borderRadius: 999, padding: "6px 14px", fontSize: 12, fontWeight: 700 }}>
          Alunos
        
              {T.modulos?.documentos && docsPendentes > 0 && (
                <span style={{ marginLeft: 6, background: T.danger, color: "#fff", borderRadius: 999, padding: "2px 7px", fontSize: 10, fontWeight: 700 }}>
                  {docsPendentes} pendente{docsPendentes > 1 ? "s" : ""}
                </span>
              )}
            </button>
      )}
      <button onClick={() => setActiveTab("unidades")} style={{ background: activeTab === "unidades" ? T.forest : "none", color: activeTab === "unidades" ? " #fff" : T.muted, border: activeTab === "unidades" ? "none" : "1px solid " + T.line, borderRadius: 999, padding: "6px 14px", fontSize: 12, fontWeight: 700 }}>
            Unidades
          </button>
          <button onClick={() => setActiveTab("chamada")} style={{ background: activeTab === "chamada" ? T.forest : "none", color: activeTab === "chamada" ? "#fff" : T.muted, border: activeTab === "chamada" ? "none" : "1px solid " + T.line, borderRadius: 999, padding: "6px 14px", fontSize: 12, fontWeight: 700 }}>
            Chamada
          </button>
          <button onClick={() => setActiveTab("configuracoes")} style={{ background: activeTab === "configuracoes" ? T.forest : "none", color: activeTab === "configuracoes" ? "#fff" : T.muted, border: activeTab === "configuracoes" ? "none" : "1px solid " + T.line, borderRadius: 999, padding: "6px 14px", fontSize: 12, fontWeight: 700 }}>
        Configurações
      </button>
      {T.modulos?.financeiro && (
        <button onClick={() => setActiveTab("financeiro")} style={{ background: activeTab === "financeiro" ? T.forest : "none", color: activeTab === "financeiro" ? "#fff" : T.muted, border: activeTab === "financeiro" ? "none" : "1px solid " + T.line, borderRadius: 999, padding: "6px 14px", fontSize: 12, fontWeight: 700 }}>
          Financeiro
        </button>
      )}
      {T.modulos?.rh && (
        <button onClick={() => setActiveTab("rh")} style={{ background: activeTab === "rh" ? T.forest : "none", color: activeTab === "rh" ? "#fff" : T.muted, border: activeTab === "rh" ? "none" : "1px solid " + T.line, borderRadius: 999, padding: "6px 14px", fontSize: 12, fontWeight: 700 }}>
          RH
        </button>
      )}
    </div>
    {activeTab === "leads" && (
      <>
        <div style={{ marginTop: 24, display: "flex", justifyContent: "space-between", alignItems: "center" }}>
          <Eyebrow>Pré-matrículas (leads)</Eyebrow>
          <button onClick={carregar} style={{ background: "none", border: "none", color: T.forest, fontSize: 12, fontWeight: 700, display: "flex", alignItems: "center", gap: 4 }}>
            <RefreshCw size={12} /> Atualizar
          </button>
        </div>

        {!leads ? <Spinner label="Carregando leads…" /> : leads.length === 0 ? (
          <Card style={{ marginTop: 8, padding: 24, textAlign: "center" }}>
            <Inbox size={26} color={T.muted} />
            <div style={{ fontSize: 13, color: T.muted, marginTop: 6 }}>
              Nenhuma pré-matrícula ainda. Quando o formulário público estiver no ar, elas aparecem aqui.
            </div>
          </Card>
        ) : (
          <Card style={{ marginTop: 8, overflow: "hidden" }}>
            {leads.map((l, i) => {
              const expandido = leadExpandidoId === l.id;
              return (
              <div key={l.id} style={{ borderTop: i ? `1px solid ${T.line}` : "none" }}>
                <div
                  onClick={() => l.tem_necessidade_especifica && setLeadExpandidoId(expandido ? null : l.id)}
                  style={{ padding: "12px 14px", display: "flex", justifyContent: "space-between", alignItems: "center", gap: 8, flexWrap: "wrap", cursor: l.tem_necessidade_especifica ? "pointer" : "default" }}>
                  <div>
                    <div style={{ fontSize: 14, fontWeight: 700, color: T.ink, display: "flex", alignItems: "center", gap: 6 }}>
                      {l.nome}
                      {l.tem_necessidade_especifica && (
                        <span title="Necessidade específica declarada" style={{ display: "inline-flex", alignItems: "center", gap: 3, fontSize: 10, fontWeight: 700, color: T.forest, background: "#EAF6F0", padding: "2px 7px", borderRadius: 999 }}>
                          <HeartHandshake size={11} /> Necessidade específica
                          {expandido ? <ChevronDown size={11} /> : <ChevronRight size={11} />}
                        </span>
                      )}
                    </div>
                    <div style={{ fontSize: 12, color: T.muted }}>
                      {l.email}{l.curso?.nome ? ` · interesse: ${l.curso.nome}` : ""} · {l.origem}{l.unidade?.nome ? ` · ${l.unidade.nome}` : ""}
                    </div>
                  </div>
                  {l.situacao === "convertido" ? (
                    <span style={{ fontSize: 11, fontWeight: 700, color: T.success, background: "#EAF6F0", padding: "4px 10px", borderRadius: 999 }}>
                      Convertido
                    </span>
                  ) : (
                    <button onClick={(e) => { e.stopPropagation(); converter(l); }}
                      style={{ background: T.forest, color: "#fff", border: "none", borderRadius: 10, padding: "8px 12px", fontSize: 12, fontWeight: 700, display: "flex", alignItems: "center", gap: 5 }}>
                      <UserPlus size={13} /> Matricular
                    </button>
                  )}
                </div>
                {expandido && l.tem_necessidade_especifica && (
                  <div style={{ padding: "0 14px 12px 14px", fontSize: 12, color: T.ink }}>
                    <div style={{ fontWeight: 700, marginBottom: 4 }}>Necessidades declaradas (visível somente à coordenação):</div>
                    <ul style={{ margin: 0, paddingLeft: 18 }}>
                      {(l.necessidades_especificas || []).map((chave) => (
                        <li key={chave}>{formatarNecessidade(chave)}</li>
                      ))}
                      {(!l.necessidades_especificas || l.necessidades_especificas.length === 0) && (
                        <li style={{ color: T.muted }}>Nenhum detalhe informado.</li>
                      )}
                    </ul>
                  </div>
                )}
              </div>
              );
            })}
          </Card>
        )}
      </>
    )}
    {activeTab === "alunos" && (
      <>
        <div style={{ marginTop: 24, display: "flex", justifyContent: "space-between", alignItems: "center" }}>
          <Eyebrow>Alunos matriculados</Eyebrow>
          <button onClick={carregarMatriculas} style={{ background: "none", border: "none", color: T.forest, fontSize: 12, fontWeight: 700, display: "flex", alignItems: "center", gap: 4 }}>
            <RefreshCw size={12} /> Atualizar
          </button>
        </div>
        <input
          value={buscaAluno}
          onChange={(e) => setBuscaAluno(e.target.value)}
          placeholder="Buscar aluno por nome ou e-mail"
          style={{ marginTop: 8, width: "100%", padding: "10px 12px", borderRadius: 10, border: "1px solid " + T.line, fontSize: 13, boxSizing: "border-box" }}
        />
        {matriculasLoading ? <Spinner label="Carregando alunos…" /> : matriculasError ? (
          <Card style={{ marginTop: 8, padding: 24, textAlign: "center" }}>
            <AlertTriangle size={26} color={T.danger} />
            <div style={{ fontSize: 13, color: T.muted, marginTop: 6 }}>{matriculasError}</div>
          </Card>
        ) : matriculasFiltradas.length === 0 ? (
          <Card style={{ marginTop: 8, padding: 24, textAlign: "center" }}>
            <Users size={26} color={T.muted} />
            <div style={{ fontSize: 13, color: T.muted, marginTop: 6 }}>
              Nenhum aluno matriculado encontrado.
            </div>
          </Card>
        ) : (
          <Card style={{ marginTop: 8, overflow: "hidden" }}>
            {matriculasFiltradas.map((m, i) => {
              const alunoExpandido = alunoExpandidoId === m.id;
              return (
              <div key={m.id} style={{ borderTop: i ? "1px solid " + T.line : "none" }}>
              <div
                onClick={() => m.aluno?.tem_necessidade_especifica && setAlunoExpandidoId(alunoExpandido ? null : m.id)}
                style={{ padding: "12px 14px", display: "flex", justifyContent: "space-between", alignItems: "center", gap: 8, flexWrap: "wrap", cursor: m.aluno?.tem_necessidade_especifica ? "pointer" : "default" }}>
                <div>
                  <div style={{ fontSize: 14, fontWeight: 700, color: T.ink, display: "flex", alignItems: "center", gap: 6 }}>
                    {m.aluno?.nome ?? "Aluno"}
                    {m.aluno?.tem_necessidade_especifica && (
                      <span title="Necessidade específica declarada" style={{ display: "inline-flex", alignItems: "center", gap: 3, fontSize: 10, fontWeight: 700, color: T.forest, background: "#EAF6F0", padding: "2px 7px", borderRadius: 999 }}>
                        <HeartHandshake size={11} /> Necessidade específica
                        {alunoExpandido ? <ChevronDown size={11} /> : <ChevronRight size={11} />}
                      </span>
                    )}
                  </div>
                  <div style={{ fontSize: 12, color: T.muted }}>
                    {m.aluno?.email}{m.curso?.nome ? " · " + m.curso.nome : ""}{m.unidade?.nome ? " · " + m.unidade.nome : ""}
                  </div>
                </div>
                <div style={{ display: "flex", alignItems: "center", gap: 8, flexWrap: "wrap" }} onClick={(e) => e.stopPropagation()}>
                  <span style={{ fontSize: 11, fontWeight: 700, padding: "4px 10px", borderRadius: 999, ...badgeStyle(m.situacao) }}>
                    {m.situacao === "ativa" ? "Ativa" : m.situacao === "cancelada" ? "Cancelada" : m.situacao === "concluida" ? "Concluída" : m.situacao === "trancada" ? "Trancada" : m.situacao}
                  </span>
              {T.modulos?.documentos && (
                <button onClick={() => setDocAluno({ id: m.aluno?.id, nome: m.aluno?.nome })} style={{ display: "flex", alignItems: "center", gap: 4, background: "none", border: "1px solid " + T.line, color: T.ink, borderRadius: 10, padding: "6px 10px", fontSize: 12, fontWeight: 700 }}>
                  <FileText size={13} /> Documentos
                </button>
              )}
                  {m.situacao === "ativa" && (
                    <button onClick={() => handleSituacaoMatricula(m, "cancelada")} style={{ background: T.danger, color: "#fff", border: "none", borderRadius: 10, padding: "8px 12px", fontSize: 12, fontWeight: 700 }}>
                      Cancelar matrícula
                    </button>
                  )}
                  {m.situacao === "cancelada" && (
                    <button onClick={() => handleSituacaoMatricula(m, "ativa")} style={{ background: T.forest, color: "#fff", border: "none", borderRadius: 10, padding: "8px 12px", fontSize: 12, fontWeight: 700 }}>
                      Reativar matrícula
                    </button>
                  )}
                </div>
              </div>
              {alunoExpandido && m.aluno?.tem_necessidade_especifica && (
                <div style={{ padding: "0 14px 12px 14px", fontSize: 12, color: T.ink }}>
                  <div style={{ fontWeight: 700, marginBottom: 4 }}>Necessidades declaradas (visível somente à coordenação):</div>
                  <ul style={{ margin: 0, paddingLeft: 18 }}>
                    {(m.aluno.necessidades_especificas || []).map((chave) => (
                      <li key={chave}>{formatarNecessidade(chave)}</li>
                    ))}
                    {(!m.aluno.necessidades_especificas || m.aluno.necessidades_especificas.length === 0) && (
                      <li style={{ color: T.muted }}>Nenhum detalhe informado.</li>
                    )}
                  </ul>
                </div>
              )}
              </div>
              );
            })}
          </Card>
        )}
      </>
    )}
    {activeTab === "unidades" && (
            <>
              <div style={{ marginTop: 24, display: "flex", justifyContent: "space-between", alignItems: "center" }}>
                <Eyebrow>Unidades / Polos</Eyebrow>
                <button onClick={carregarUnidades} style={{ background: "none", border: "none", color: T.forest, fontSize: 12, fontWeight: 700, display: "flex", alignItems: "center", gap: 4 }}>
                  <RefreshCw size={12} /> Atualizar
                </button>
              </div>
              {unidadesLoading ? <Spinner label="Carregando unidades…" /> : unidadesError ? (
                <Card style={{ marginTop: 8, padding: 24, textAlign: "center" }}>
                  <AlertTriangle size={26} color={T.danger} />
                  <div style={{ fontSize: 13, color: T.muted, marginTop: 6 }}>{unidadesError}</div>
                </Card>
              ) : unidades.length === 0 ? (
                <Card style={{ marginTop: 8, padding: 24, textAlign: "center" }}>
                  <MapPin size={26} color={T.muted} />
                  <div style={{ fontSize: 13, color: T.muted, marginTop: 6 }}>
                    Nenhuma unidade cadastrada ainda.
                  </div>
                </Card>
              ) : (
                <Card style={{ marginTop: 8, overflow: "hidden" }}>
                  {unidades.map((u, i) => (
                    <div key={u.id} style={{ padding: "12px 14px", borderTop: i ? "1px solid " + T.line : "none", display: "flex", justifyContent: "space-between", alignItems: "center", gap: 8, flexWrap: "wrap" }}>
                      <div>
                        <div style={{ fontSize: 14, fontWeight: 700, color: T.ink }}>{u.nome}</div>
                        <div style={{ fontSize: 12, color: T.muted }}>
                          {[u.cidade, u.estado].filter(Boolean).join("/")}{u.pais ? ` · ${u.pais}` : ""}
                        </div>
                      </div>
                      <div style={{ display: "flex", alignItems: "center", gap: 8, flexWrap: "wrap" }}>
                        <span style={{ fontSize: 11, fontWeight: 700, padding: "4px 10px", borderRadius: 999, background: u.ativo ? " #EAF6F0" : " #FBEAEA", color: u.ativo ? T.success : T.danger }}>
                          {u.ativo ? "Ativa" : "Inativa"}
                        </span>
                        <button onClick={() => handleAlternarUnidade(u)} style={{ background: u.ativo ? T.danger : T.forest, color: " #fff", border: "none", borderRadius: 10, padding: "8px 12px", fontSize: 12, fontWeight: 700 }}>
                          {u.ativo ? "Desativar" : "Reativar"}
                        </button>
                      </div>
                    </div>
                  ))}
                </Card>
              )}
              <Eyebrow style={{ marginTop: 24 }}>Adicionar unidade</Eyebrow>
              <Card style={{ marginTop: 8, padding: 20 }}>
                <form onSubmit={handleCriarUnidade}>
                  <label style={{ display: "block", fontSize: 12, fontWeight: 600, color: T.muted, marginBottom: 4 }}>Nome *</label>
                  <input value={novaUnidadeNome} onChange={(e) => setNovaUnidadeNome(e.target.value)} placeholder="Ex.: Unidade Centro" style={{ width: "100%", padding: "10px 12px", borderRadius: 10, border: "1px solid " + T.line, fontSize: 13, boxSizing: "border-box", marginBottom: 12 }} />
                  <div style={{ display: "grid", gridTemplateColumns: "2fr 1fr 1fr", gap: 8 }}>
                    <div>
                      <label style={{ display: "block", fontSize: 12, fontWeight: 600, color: T.muted, marginBottom: 4 }}>Cidade</label>
                      <input value={novaUnidadeCidade} onChange={(e) => setNovaUnidadeCidade(e.target.value)} placeholder="Cidade" style={{ width: "100%", padding: "10px 12px", borderRadius: 10, border: "1px solid " + T.line, fontSize: 13, boxSizing: "border-box" }} />
                    </div>
                    <div>
                      <label style={{ display: "block", fontSize: 12, fontWeight: 600, color: T.muted, marginBottom: 4 }}>Estado (UF)</label>
                      <input value={novaUnidadeEstado} onChange={(e) => setNovaUnidadeEstado(e.target.value)} placeholder="UF" maxLength={2} style={{ width: "100%", padding: "10px 12px", borderRadius: 10, border: "1px solid " + T.line, fontSize: 13, boxSizing: "border-box", textTransform: "uppercase" }} />
                    </div>
                    <div>
                      <label style={{ display: "block", fontSize: 12, fontWeight: 600, color: T.muted, marginBottom: 4 }}>País</label>
                      <input value={novaUnidadePais} onChange={(e) => setNovaUnidadePais(e.target.value)} placeholder="BR" style={{ width: "100%", padding: "10px 12px", borderRadius: 10, border: "1px solid " + T.line, fontSize: 13, boxSizing: "border-box" }} />
                    </div>
                  </div>
                  <button type="submit" disabled={criandoUnidade} style={{ marginTop: 14, background: T.forest, color: " #fff", border: "none", borderRadius: 10, padding: "10px 16px", fontSize: 13, fontWeight: 700, opacity: criandoUnidade ? 0.7 : 1 }}>
                    {criandoUnidade ? "Adicionando…" : "Adicionar unidade"}
                  </button>
                </form>
              </Card>
            </>
          )}
          {activeTab === "configuracoes" && (
      <>
        <ContratoConfig T={T} toast={toast} />
        <VinculosProfessorTurma T={T} toast={toast} />
        <Eyebrow style={{ marginTop: 24 }}>Configurações da instituição</Eyebrow>
        <div style={{ display: "grid", gridTemplateColumns: "1fr 1fr", gap: 16, marginTop: 12 }}>
          {/* Esquerda: Formulário */}
          <div>
            <Card style={{ padding: 20 }}>
              {/* Nome */}
              <label style={{ display: "block", fontSize: 12, fontWeight: 600, color: T.muted, marginBottom: 4 }}>
                Nome da instituição
              </label>
              <input
                type="text"
                value={configNome}
                onChange={(e) => setConfigNome(e.target.value)}
                placeholder={T.nomeMarca}
                style={{ width: "100%", padding: "10px 12px", borderRadius: 10, border: `1px solid ${T.line}`, fontSize: 14, color: T.ink, boxSizing: "border-box", outline: "none" }}
              />

              {/* Logo URL */}
              <label style={{ display: "block", fontSize: 12, fontWeight: 600, color: T.muted, marginBottom: 4, marginTop: 12 }}>
                URL do logo
              </label>
              <input
                type="text"
                value={configLogoUrl}
                onChange={(e) => setConfigLogoUrl(e.target.value)}
                placeholder="https://..."
                style={{ width: "100%", padding: "10px 12px", borderRadius: 10, border: `1px solid ${T.line}`, fontSize: 14, color: T.ink, boxSizing: "border-box", outline: "none" }}
              />

              {/* Cor Primária */}
              <label style={{ display: "block", fontSize: 12, fontWeight: 600, color: T.muted, marginBottom: 8, marginTop: 12 }}>
                Cor primária
              </label>
              <div style={{ display: "flex", gap: 8 }}>
                <input
                  type="color"
                  value={configCorPrimaria}
                  onChange={(e) => setConfigCorPrimaria(e.target.value)}
                  style={{ width: 50, height: 40, border: `1px solid ${T.line}`, borderRadius: 10, cursor: "pointer" }}
                />
                <input
                  type="text"
                  value={configCorPrimaria}
                  onChange={(e) => /^#[0-9A-F]{6}$/.test(e.target.value) && setConfigCorPrimaria(e.target.value)}
                  placeholder="#000000"
                  style={{ flex: 1, padding: "8px 12px", borderRadius: 10, border: `1px solid ${T.line}`, fontSize: 12, color: T.ink, boxSizing: "border-box", outline: "none" }}
                />
              </div>

              {/* Cor de Destaque */}
              <label style={{ display: "block", fontSize: 12, fontWeight: 600, color: T.muted, marginBottom: 8, marginTop: 12 }}>
                Cor de destaque
              </label>
              <div style={{ display: "flex", gap: 8 }}>
                <input
                  type="color"
                  value={configCorDestaque}
                  onChange={(e) => setConfigCorDestaque(e.target.value)}
                  style={{ width: 50, height: 40, border: `1px solid ${T.line}`, borderRadius: 10, cursor: "pointer" }}
                />
                <input
                  type="text"
                  value={configCorDestaque}
                  onChange={(e) => /^#[0-9A-F]{6}$/.test(e.target.value) && setConfigCorDestaque(e.target.value)}
                  placeholder="#000000"
                  style={{ flex: 1, padding: "8px 12px", borderRadius: 10, border: `1px solid ${T.line}`, fontSize: 12, color: T.ink, boxSizing: "border-box", outline: "none" }}
                />
              </div>

              {/* Slogan */}
              <label style={{ display: "block", fontSize: 12, fontWeight: 600, color: T.muted, marginBottom: 4, marginTop: 12 }}>
                Slogan
              </label>
              <textarea
                value={configSlogan}
                onChange={(e) => setConfigSlogan(e.target.value)}
                placeholder={T.slogan}
                style={{ width: "100%", padding: "10px 12px", borderRadius: 10, border: `1px solid ${T.line}`, fontSize: 14, color: T.ink, boxSizing: "border-box", outline: "none", fontFamily: "inherit", minHeight: 60 }}
              />

              {/* Módulos */}
              <div style={{ marginTop: 16, paddingTop: 16, borderTop: `1px solid ${T.line}` }}>
                <div style={{ fontSize: 12, fontWeight: 700, color: T.ink, marginBottom: 12 }}>Módulos</div>
                {["inscricao_publica", "alunos", "documentos"].map((modulo) => (
                  <label key={modulo} style={{ display: "flex", alignItems: "center", gap: 8, marginBottom: 8, cursor: "pointer" }}>
                    <input
                      type="checkbox"
                      checked={configModulos[modulo] !== false}
                      onChange={(e) => setConfigModulos({ ...configModulos, [modulo]: e.target.checked })}
                      style={{ cursor: "pointer" }}
                    />
                    <span style={{ fontSize: 13, color: T.ink }}>
                      {modulo === "inscricao_publica" ? "Inscrição pública" : modulo === "alunos" ? "Alunos" : modulo === "documentos" ? "Documentos" : modulo}
                    </span>
                  </label>
                ))}
                {["financeiro"].map((modulo) => (
                  <label key={modulo} style={{ display: "flex", alignItems: "center", gap: 8, marginBottom: 8, cursor: "pointer", opacity: 0.6 }}>
                    <input
                      type="checkbox"
                      disabled
                      checked={false}
                      style={{ cursor: "not-allowed" }}
                    />
                    <span style={{ fontSize: 13, color: T.muted }}>
                      "Financeiro (em breve)"
                    </span>
                  </label>
                ))}
              </div>

              {/* Botão Salvar */}
              <button
                onClick={salvarConfiguracao}
                disabled={savingConfig}
                style={{
                  width: "100%",
                  marginTop: 16,
                  padding: "12px",
                  borderRadius: 12,
                  border: "none",
                  background: savingConfig ? T.muted : T.forest,
                  color: "#fff",
                  fontWeight: 700,
                  fontSize: 14,
                  cursor: savingConfig ? "not-allowed" : "pointer",
                }}
              >
                {savingConfig ? "Salvando..." : "Salvar configurações"}
              </button>
            </Card>
          </div>

          {/* Direita: Pré-visualização */}
          <div>
            <Card style={{ padding: 20, background: configCorPrimaria }}>
              <div style={{ textAlign: "center", color: "#fff" }}>
                <div style={{ fontSize: 12, opacity: 0.7, marginBottom: 8 }}>PRÉ-VISUALIZAÇÃO</div>
                {configLogoUrl && (
                  <img
                    src={configLogoUrl}
                    alt="Logo"
                    style={{ height: 40, borderRadius: 8, marginBottom: 12, objectFit: "contain" }}
                  />
                )}
                <div style={{ fontSize: 18, fontWeight: 800, marginBottom: 4 }}>{configNome || T.nomeMarca}</div>
                <div style={{ fontSize: 12, opacity: 0.8, lineHeight: 1.4 }}>{configSlogan}</div>
              </div>
              
              <div style={{ marginTop: 16, paddingTop: 16, borderTop: "1px solid rgba(255,255,255,0.2)" }}>
                <div style={{ fontSize: 11, fontWeight: 700, color: "#fff", marginBottom: 8 }}>Cores</div>
                <div style={{ display: "flex", gap: 8 }}>
                  <div style={{ flex: 1, padding: 8, background: configCorDestaque, borderRadius: 8, fontSize: 11, fontWeight: 600, color: "#000", textAlign: "center" }}>
                    Destaque
                  </div>
                  <div style={{ flex: 1, padding: 8, background: configCorPrimaria, borderRadius: 8, fontSize: 11, fontWeight: 600, color: "#fff", textAlign: "center", border: "2px solid #fff" }}>
                    Primária
                  </div>
                </div>
              </div>
            </Card>
          </div>
        </div>
      </>
    )}
      </div>
    {activeTab === "financeiro" && T.modulos?.financeiro && (
      <FinanceiroGestor perfil={perfil} toast={toast} T={T} />
    )}
    {activeTab === "rh" && T.modulos?.rh && (
      <RH perfil={perfil} toast={toast} T={T} />
    )}
    {activeTab === "chamada" && (
      <Chamada perfil={perfil} toast={toast} T={T} />
    )}
    {docAluno && (
    <DocumentosAlunoModal aluno={docAluno} toast={toast} T={T} onClose={() => setDocAluno(null)} onChange={atualizarDocsPendentes} />
  )}
  </div>
  );
}

/* ============================================================
   RAIZ — sessão e roteamento por perfil
   ============================================================ */
export default function App() {
  // --- Roteamento por hash (sem biblioteca) ---
  const getRouteFromHash = (hash = window.location.hash) => {
    if (hash.includes("type=recovery")) return "#/redefinir-senha";
    return hash || "#/";
  };

  const [rota, setRota] = React.useState(getRouteFromHash());
  React.useEffect(() => {
    const handler = () => setRota(getRouteFromHash(window.location.hash));
    window.addEventListener('hashchange', handler);
        return () => window.removeEventListener('hashchange', handler);
  }, []);
  const [checking, setChecking] = useState(true);
  const [logged, setLogged] = useState(false);
  const [perfil, setPerfil] = useState(null);
  const [erroPerfil, setErroPerfil] = useState("");
  const [precisaCriarEscola, setPrecisaCriarEscola] = useState(false);
  const [emailOnboarding, setEmailOnboarding] = useState("");
  const [toastMsg, setToastMsg] = useState("");
  // temaBase: identidade visual do tenant (marca). tema: temaBase + preferências de acessibilidade aplicadas.
  const [temaBase, setTemaBase] = useState(TEMA_PADRAO);
  const [prefFonte, setPrefFonte] = useState("normal");
  const [altoContraste, setAltoContraste] = useState(false);
  const tema = aplicarAcessibilidade(temaBase, { prefFonte, altoContraste });

  const toast = useCallback((msg) => {
    setToastMsg(msg);
    window.clearTimeout(window.__klToast);
    window.__klToast = window.setTimeout(() => setToastMsg(""), 2400);
  }, []);

  const alterarFonte = useCallback((novaPref) => {
    setPrefFonte(novaPref);
    if (perfil) salvarPreferenciasAcessibilidade({ prefFonte: novaPref }).catch((e) => console.error(e));
  }, [perfil]);

  const alterarContraste = useCallback((novoValor) => {
    setAltoContraste(novoValor);
    if (perfil) salvarPreferenciasAcessibilidade({ prefAltoContraste: novoValor }).catch((e) => console.error(e));
  }, [perfil]);

  const carregarPerfil = useCallback(async () => {
    setErroPerfil("");
    try {
      const status = await meuStatusOnboarding();
      if (status && status.tem_tenant === false) {
        setEmailOnboarding(status.email || "");
        setPrecisaCriarEscola(true);
        return;
      }
    } catch (e) {
      console.error(e);
      setErroPerfil("Não foi possível carregar seu perfil.");
      return;
    }
    setPrecisaCriarEscola(false);
    try {
      const p = await meuPerfil();
      if (!p) { setErroPerfil("Sua conta existe, mas não está vinculada a uma escola. Fale com o administrador."); return; }
      setPerfil(p);
      // Aplica automaticamente a preferência de acessibilidade salva na conta.
      if (p.pref_fonte) setPrefFonte(p.pref_fonte);
      if (typeof p.pref_alto_contraste === "boolean") setAltoContraste(p.pref_alto_contraste);

      // Carregar tenant e aplicar tema
      try {
        const t = await meuTenant();
        if (t) {
          const temaMontado = montarTema({
            id: t.id,
            nome: t.nome,
            slug: t.slug,
            logo_url: t.logo_url,
            marca: t.config?.marca || {},
            modulos: t.config?.modulos || {},
          });
          setTemaBase(temaMontado);
        }
      } catch (e) {
        console.warn("Não foi possível carregar o tenant, usando tema padrão", e);
      }
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
    const { data: sub } = supabase.auth.onAuthStateChange((event, session) => {
      if (event === "PASSWORD_RECOVERY") {
        setRota("#/redefinir-senha");
      }
      setLogged(!!session);
      if (session) carregarPerfil();
      else { setPerfil(null); setErroPerfil(""); setPrecisaCriarEscola(false); setEmailOnboarding(""); }
    });
    return () => sub.subscription.unsubscribe();
  }, [carregarPerfil]);

  const logout = async () => { await sair(); };

  const aoEscolaCriada = useCallback(() => {
    setPrecisaCriarEscola(false);
    setPerfil(null);
    carregarPerfil();
  }, [carregarPerfil]);

// Roteamento por caminho, ignorando query string (ex.: "#/inscricao?t=slug")
    const [caminhoRota] = (rota || "#/").split("?");
  if (caminhoRota === '#/inscricao') return <PreMatricula />;
  if (caminhoRota === '#/cadastro') return <Cadastro onLogged={() => { window.location.hash = "#/"; }} />;
  if (caminhoRota === '#/primeiro-acesso') return <PrimeiroAcesso onLogged={() => { window.location.hash = "#/"; }} />;
  if (caminhoRota === '#/recuperar-senha') return <RecuperarSenhaScreen />;
  if (caminhoRota === '#/redefinir-senha') return <RedefinirSenhaScreen onLogged={() => { window.location.hash = "#/"; }} />;
  
  return (
    <TemaContext.Provider value={tema}>
      <div className="kl-body" style={{ minHeight: "100vh", background: tema.paper, zoom: "var(--kl-font-scale)" }}>
        <style>{fontStyles}</style>

        <ControleAcessibilidade
          prefFonte={prefFonte}
          altoContraste={altoContraste}
          onFonte={alterarFonte}
          onContraste={alterarContraste}
          T={tema}
        />

        {checking && <Spinner label="Iniciando…" />}

        {!checking && !logged && <LoginScreen onLogged={() => {}} />}

        {!checking && logged && !perfil && !erroPerfil && !precisaCriarEscola && <Spinner label="Carregando seu perfil…" />}

        {!checking && logged && precisaCriarEscola && (
          <CriarEscola emailSugestao={emailOnboarding} onCriada={aoEscolaCriada} />
        )}

        {!checking && logged && !precisaCriarEscola && erroPerfil && (
          <div style={{ display: "flex", flexDirection: "column", alignItems: "center", padding: 48, gap: 12 }}>
            <AlertTriangle size={28} color={tema.danger} />
            <div style={{ fontSize: 14, color: tema.ink, textAlign: "center", maxWidth: 320 }}>{erroPerfil}</div>
            <button onClick={logout} style={{ padding: "10px 20px", borderRadius: 12, border: "none", background: tema.forest, color: "#fff", fontWeight: 600 }}>
              Sair
            </button>
          </div>
        )}

        {!checking && logged && perfil && (
          ["super_admin", "gestor"].includes(perfil.perfil)
            ? <GestorApp perfil={perfil} onLogout={logout} toast={toast} setTema={setTemaBase} />
            : <AlunoApp perfil={perfil} onLogout={logout} toast={toast} />
        )}

        <Toast msg={toastMsg} />
      </div>
    </TemaContext.Provider>
  );
}
