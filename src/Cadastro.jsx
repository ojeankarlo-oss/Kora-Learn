import React, { useState } from "react";
import { Eye, EyeOff } from "lucide-react";
import { cadastrarNovaConta } from "./lib/api";
import ControleAcessibilidade from "./AcessibilidadeControle";
import { aplicarAcessibilidade } from "./theme";

const T_BASE = {
  ink: "#10201A",
  forest: "#17604A",
  forestDark: "#0E4536",
  muted: "#6B8F7A",
  bg: "#F4F9F6",
  line: "#D0E6DA",
};

const FONT = "'Archivo', 'Inter', sans-serif";

function LogoKora({ size = 32, T }) {
  return (
    <svg width={size * 3.2} height={size} viewBox="0 0 128 40" fill="none">
      <rect width="40" height="40" rx="10" fill="#E8F8EF" />
      <text x="20" y="28" textAnchor="middle" fontFamily={FONT} fontSize="22" fontWeight="800" fill={T.forest}>K</text>
      <text x="55" y="28" fontFamily={FONT} fontSize="20" fontWeight="700" fill={T.forest}>KORA</text>
      <text x="55" y="38" fontFamily={FONT} fontSize="9" fontWeight="400" fill={T.muted} letterSpacing="2">LEARN</text>
    </svg>
  );
}

function PasswordField({ label, value, onChange, placeholder, autoComplete = "new-password", T }) {
  const [show, setShow] = useState(false);

  return (
    <div style={{ marginBottom: 12 }}>
      <label style={{ display: "block", fontSize: 12, fontWeight: 600, color: T.muted, marginBottom: 4 }}>{label}</label>
      <div style={{ position: "relative" }}>
        <input
          type={show ? "text" : "password"}
          value={value}
          onChange={onChange}
          placeholder={placeholder}
          autoComplete={autoComplete}
          style={{ width: "100%", boxSizing: "border-box", padding: "10px 42px 10px 12px", borderRadius: 10, border: `1.5px solid ${T.line}`, fontSize: 14 }}
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

export default function Cadastro({ onLogged }) {
  const [email, setEmail] = useState("");
  const [senha, setSenha] = useState("");
  const [confirmarSenha, setConfirmarSenha] = useState("");
  const [erro, setErro] = useState("");
  const [info, setInfo] = useState("");
  const [loading, setLoading] = useState(false);
  const [aguardandoConfirmacao, setAguardandoConfirmacao] = useState(false);
  const [prefFonte, setPrefFonte] = useState("normal");
  const [altoContraste, setAltoContraste] = useState(false);
  const T = aplicarAcessibilidade(T_BASE, { prefFonte, altoContraste });

  const reqTamanho = senha.length >= 8;
  const reqIguais = confirmarSenha.length > 0 && senha === confirmarSenha;
  const senhasDivergem = confirmarSenha.length > 0 && senha !== confirmarSenha;
  const requisitosOk = reqTamanho && reqIguais;

  async function handleSubmit(e) {
    e.preventDefault();
    setErro("");
    setInfo("");

    if (!email.trim()) {
      setErro("Informe seu e-mail.");
      return;
    }
    if (!reqTamanho) {
      setErro("A senha deve ter pelo menos 8 caracteres.");
      return;
    }
    if (senha !== confirmarSenha) {
      setErro("As senhas não conferem.");
      return;
    }

    setLoading(true);
    try {
      const data = await cadastrarNovaConta(email.trim(), senha);
      if (data.session) {
        setInfo("Conta criada! Entrando...");
        if (onLogged) onLogged();
        window.location.hash = "#/";
      } else if (data.user) {
        setAguardandoConfirmacao(true);
      } else {
        setErro("Não foi possível criar sua conta. Tente novamente.");
      }
    } catch (e) {
      const msg = e?.message || "";
      if (msg.includes("already registered") || msg.includes("already exists") || msg.includes("User already")) {
        setErro("Este e-mail já está cadastrado. Use o botão de entrar ou recupere sua senha.");
      } else if (msg.toLowerCase().includes("password") && msg.toLowerCase().includes("least")) {
        setErro("A senha deve ter pelo menos 8 caracteres.");
      } else if (msg.toLowerCase().includes("invalid") && msg.toLowerCase().includes("email")) {
        setErro("Informe um e-mail válido.");
      } else {
        setErro("Não foi possível criar sua conta. Tente novamente.");
      }
    } finally {
      setLoading(false);
    }
  }

  if (aguardandoConfirmacao) {
    return (
      <div style={{ minHeight: "100vh", background: T.forestDark, display: "flex", alignItems: "center", justifyContent: "center", padding: 24, fontFamily: FONT, zoom: "var(--kl-font-scale)" }}>
        <ControleAcessibilidade prefFonte={prefFonte} altoContraste={altoContraste} onFonte={setPrefFonte} onContraste={setAltoContraste} T={T} />
        <div style={{ width: "100%", maxWidth: 420, background: "#fff", borderRadius: 22, padding: 24, boxShadow: "0 8px 30px #00000022", textAlign: "center" }}>
          <LogoKora size={30} T={T} />
          <div style={{ fontSize: 15, fontWeight: 700, color: T.ink, marginTop: 16 }}>
            Enviamos um link de confirmação para seu e-mail.
          </div>
          <div style={{ fontSize: 13, color: T.muted, marginTop: 8, lineHeight: 1.5 }}>
            Clique nele para continuar.
          </div>
          <button onClick={() => { window.location.hash = "#/"; }} style={{ width: "100%", marginTop: 20, padding: "12px 14px", borderRadius: 12, border: "none", background: T.forest, color: "#fff", fontWeight: 700, fontSize: 14, cursor: "pointer" }}>
            Voltar ao login
          </button>
        </div>
      </div>
    );
  }

  return (
    <div style={{ minHeight: "100vh", background: T.forestDark, display: "flex", alignItems: "center", justifyContent: "center", padding: 24, fontFamily: FONT, zoom: "var(--kl-font-scale)" }}>
      <ControleAcessibilidade prefFonte={prefFonte} altoContraste={altoContraste} onFonte={setPrefFonte} onContraste={setAltoContraste} T={T} />
      <div style={{ width: "100%", maxWidth: 420, background: "#fff", borderRadius: 22, padding: 24, boxShadow: "0 8px 30px #00000022" }}>
        <div style={{ textAlign: "center", marginBottom: 18 }}>
          <LogoKora size={30} T={T} />
          <div style={{ fontSize: 18, fontWeight: 700, color: T.ink, marginTop: 12 }}>Criar minha conta</div>
          <div style={{ fontSize: 13, color: T.muted, marginTop: 8, lineHeight: 1.5 }}>
            Cadastre-se para criar sua escola no KORA Learn.
          </div>
        </div>
        <form onSubmit={handleSubmit}>
          <label style={{ display: "block", fontSize: 12, fontWeight: 600, color: T.muted, marginBottom: 4 }}>E-mail</label>
          <input type="email" value={email} onChange={(e) => setEmail(e.target.value)} placeholder="seu@email.com" style={{ width: "100%", boxSizing: "border-box", padding: "10px 12px", borderRadius: 10, border: `1.5px solid ${T.line}`, fontSize: 14, marginBottom: 12 }} />

          <PasswordField
            label="Senha"
            value={senha}
            onChange={(e) => setSenha(e.target.value)}
            placeholder="Mínimo 8 caracteres"
            autoComplete="new-password"
            T={T}
          />

          <PasswordField
            label="Confirmar senha"
            value={confirmarSenha}
            onChange={(e) => setConfirmarSenha(e.target.value)}
            placeholder="Repita a senha"
            autoComplete="new-password"
            T={T}
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
              <div style={{ fontSize: 13, color: "#B93B2D", fontWeight: 500 }}>
                As senhas não coincidem
              </div>
            )}
          </div>

          {erro && <div style={{ marginBottom: 10, padding: "8px 10px", borderRadius: 8, background: "#FCECEA", color: "#B93B2D", fontSize: 13 }}>{erro}</div>}
          {info && <div style={{ marginBottom: 10, padding: "8px 10px", borderRadius: 8, background: "#EAF6F0", color: T.forest, fontSize: 13 }}>{info}</div>}

          <button type="submit" disabled={loading || !requisitosOk} style={{ width: "100%", padding: "12px 14px", borderRadius: 12, border: "none", background: loading || !requisitosOk ? T.muted : T.forest, color: "#fff", fontWeight: 700, fontSize: 14, cursor: loading || !requisitosOk ? "not-allowed" : "pointer" }}>
            {loading ? "Criando conta..." : "Criar conta"}
          </button>
        </form>
        <button onClick={() => { window.location.hash = "#/"; }} style={{ width: "100%", marginTop: 10, background: "transparent", border: "none", color: T.forest, fontWeight: 600, fontSize: 13 }}>
          Já tem conta? Entrar
        </button>
      </div>
    </div>
  );
}
