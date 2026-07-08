import React, { useMemo, useState } from "react";
import { Eye, EyeOff } from "lucide-react";
import { primeiroAcesso } from "./lib/api";

const T = {
  ink: "#10201A",
  forest: "#17604A",
  forestDark: "#0E4536",
  muted: "#6B8F7A",
  bg: "#F4F9F6",
  line: "#D0E6DA",
};

const FONT = "'Archivo', 'Inter', sans-serif";

function LogoKora({ light = false, size = 32 }) {
  const c = light ? "#FFFFFF" : T.forest;
  return (
    <svg width={size * 3.2} height={size} viewBox="0 0 128 40" fill="none">
      <rect width="40" height="40" rx="10" fill={light ? "#FFFFFF22" : "#E8F8EF"} />
      <text x="20" y="28" textAnchor="middle" fontFamily={FONT} fontSize="22" fontWeight="800" fill={c}>K</text>
      <text x="55" y="28" fontFamily={FONT} fontSize="20" fontWeight="700" fill={c}>KORA</text>
      <text x="55" y="38" fontFamily={FONT} fontSize="9" fontWeight="400" fill={light ? "#FFFFFF88" : T.muted} letterSpacing="2">LEARN</text>
    </svg>
  );
}

function PasswordField({ label, value, onChange, placeholder, autoComplete = "new-password" }) {
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

export default function PrimeiroAcesso({ onLogged }) {
  const [email, setEmail] = useState("");
  const [senha, setSenha] = useState("");
  const [confirmarSenha, setConfirmarSenha] = useState("");
  const [erro, setErro] = useState("");
  const [info, setInfo] = useState("");
  const [loading, setLoading] = useState(false);

  const senhaValida = useMemo(() => senha.length >= 8, [senha]);

  async function handleSubmit(e) {
    e.preventDefault();
    setErro("");
    setInfo("");

    if (!email.trim()) {
      setErro("Informe seu e-mail.");
      return;
    }
    if (!senhaValida) {
      setErro("A senha deve ter pelo menos 8 caracteres.");
      return;
    }
    if (senha !== confirmarSenha) {
      setErro("As senhas não conferem.");
      return;
    }

    setLoading(true);
    try {
      const { vinculado, needsConfirmation } = await primeiroAcesso(email.trim(), senha);
      if (vinculado === true) {
        setInfo("Conta criada! Entrando...");
        if (onLogged) onLogged();
        window.location.hash = "#/";
      } else if (needsConfirmation) {
        setInfo("Enviamos um link de confirmação para seu e-mail.");
      } else {
        setInfo("Criamos seu login, mas não encontramos uma matrícula com este e-mail. Fale com a secretaria.");
      }
    } catch (e) {
      const msg = e?.message || "";
      if (msg.includes("already registered") || msg.includes("already exists")) {
        setErro("Este e-mail já está cadastrado. Use o botão de entrar ou recupere sua senha.");
      } else if (msg.includes("password") && msg.includes("least")) {
        setErro("A senha deve ter pelo menos 8 caracteres.");
      } else {
        setErro("Não foi possível criar sua conta. Tente novamente.");
      }
    } finally {
      setLoading(false);
    }
  }

  return (
    <div style={{ minHeight: "100vh", background: T.forestDark, display: "flex", alignItems: "center", justifyContent: "center", padding: 24, fontFamily: FONT }}>
      <div style={{ width: "100%", maxWidth: 420, background: "#fff", borderRadius: 22, padding: 24, boxShadow: "0 8px 30px #00000022" }}>
        <div style={{ textAlign: "center", marginBottom: 18 }}>
          <LogoKora light={false} size={30} />
          <div style={{ fontSize: 13, color: T.muted, marginTop: 8, lineHeight: 1.5 }}>
            Se a escola já fez sua matrícula, use o mesmo e-mail informado na inscrição.
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
          />

          <PasswordField
            label="Confirmar senha"
            value={confirmarSenha}
            onChange={(e) => setConfirmarSenha(e.target.value)}
            placeholder="Repita a senha"
            autoComplete="new-password"
          />

          {erro && <div style={{ marginBottom: 10, padding: "8px 10px", borderRadius: 8, background: "#FCECEA", color: "#B93B2D", fontSize: 13 }}>{erro}</div>}
          {info && <div style={{ marginBottom: 10, padding: "8px 10px", borderRadius: 8, background: "#EAF6F0", color: T.forest, fontSize: 13 }}>{info}</div>}

          <button type="submit" disabled={loading} style={{ width: "100%", padding: "12px 14px", borderRadius: 12, border: "none", background: loading ? T.muted : T.forest, color: "#fff", fontWeight: 700, fontSize: 14 }}>
            {loading ? "Criando conta..." : "Criar senha"}
          </button>
        </form>
        <button onClick={() => { window.location.hash = "#/"; }} style={{ width: "100%", marginTop: 10, background: "transparent", border: "none", color: T.forest, fontWeight: 600, fontSize: 13 }}>
          Voltar ao login
        </button>
      </div>
    </div>
  );
}
