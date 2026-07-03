import React, { useState } from "react";
import { criarPreMatricula } from "./lib/api";

// ---------- Identidade visual (espelhada do App.jsx) ----------
const T = {
  ink: "#10201A",
  forest: "#17604A",
  forestDark: "#0E4536",
  forestDeep: "#0A3025",
  mint: "#C8F0DC",
  mintLight: "#E8F8EF",
  amber: "#F5A623",
  muted: "#6B8F7A",
  bg: "#F4F9F6",
};

const FONT = "'Archivo', 'Inter', sans-serif";

function LogoKora({ light = false, size = 32 }) {
  const c = light ? "#FFFFFF" : T.forest;
  return (
    <svg width={size * 3.2} height={size} viewBox="0 0 128 40" fill="none">
      <rect width="40" height="40" rx="10" fill={light ? "#FFFFFF22" : T.mintLight} />
      <text x="20" y="28" textAnchor="middle" fontFamily={FONT}
        fontSize="22" fontWeight="800" fill={c}>K</text>
      <text x="55" y="28" fontFamily={FONT} fontSize="20" fontWeight="700" fill={c}>KORA</text>
      <text x="55" y="38" fontFamily={FONT} fontSize="9" fontWeight="400"
        fill={light ? "#FFFFFF88" : T.muted} letterSpacing="2">LEARN</text>
    </svg>
  );
}

function Campo({ label, type = "text", value, onChange, placeholder, required }) {
  return (
    <div style={{ marginTop: 16 }}>
      <label style={{ display: "block", fontSize: 12, fontWeight: 600,
        color: T.muted, marginBottom: 4 }}>
        {label}{required && <span style={{ color: T.amber }}> *</span>}
      </label>
      <input
        type={type}
        value={value}
        onChange={e => onChange(e.target.value)}
        placeholder={placeholder}
        required={required}
        style={{
          width: "100%", padding: "10px 14px", borderRadius: 10,
          border: "1.5px solid #D0E6DA", fontSize: 14, fontFamily: FONT,
          outline: "none", boxSizing: "border-box", color: T.ink,
          background: "#fff",
        }}
      />
    </div>
  );
}

export default function PreMatricula() {
  const [nome, setNome] = useState("");
  const [email, setEmail] = useState("");
  const [telefone, setTelefone] = useState("");
  const [loading, setLoading] = useState(false);
  const [sucesso, setSucesso] = useState(false);
  const [erro, setErro] = useState("");

  async function handleSubmit(e) {
    e.preventDefault();
    setErro("");
    const emailRegex = /^[^s@]+@[^s@]+.[^s@]+$/;
    if (!emailRegex.test(email)) {
      setErro("Por favor, informe um e-mail válido.");
      return;
    }
    setLoading(true);
    try {
      await criarPreMatricula({
        tenantId: import.meta.env.VITE_TENANT_ID,
        cursoId: null,
        origem: "site",
        nome,
        email,
        telefone,
      });
      setSucesso(true);
    } catch (err) {
      setErro("Ocorreu um erro ao enviar. Tente novamente.");
    } finally {
      setLoading(false);
    }
  }

  return (
    <div style={{
      minHeight: "100vh",
      background: T.forestDark,
      display: "flex",
      flexDirection: "column",
      alignItems: "center",
      justifyContent: "center",
      padding: "24px 16px",
      fontFamily: FONT,
    }}>
      <div style={{ marginBottom: 28, textAlign: "center" }}>
        <LogoKora light size={34} />
        <p style={{ color: "#CFE0D8", fontSize: 14, marginTop: 12,
          maxWidth: 300, lineHeight: 1.5 }}>
          Cada aula aprendida, uma vida se transforma.
        </p>
      </div>
      <div style={{
        background: "#fff", borderRadius: 20, padding: "28px 24px",
        width: "100%", maxWidth: 400, boxShadow: "0 8px 40px #00000033",
      }}>
        {sucesso ? (
          <div style={{ textAlign: "center", padding: "8px 0" }}>
            <div style={{ fontSize: 48, marginBottom: 12 }}>&#x1F389;</div>
            <div style={{ fontSize: 18, fontWeight: 700, color: T.forest, marginBottom: 8 }}>
              Inscrição recebida!
            </div>
            <p style={{ fontSize: 14, color: T.muted, lineHeight: 1.6 }}>
              Em breve nossa equipe entra em contato.
            </p>
            <p style={{ fontSize: 13, color: T.muted, marginTop: 16, fontStyle: "italic" }}>
              Cada aula aprendida, uma vida se transforma.
            </p>
          </div>
        ) : (
          <form onSubmit={handleSubmit}>
            <div style={{ fontSize: 18, fontWeight: 700, color: T.ink, marginBottom: 4 }}>
              Pré-matrícula
            </div>
            <div style={{ fontSize: 13, color: T.muted, marginBottom: 8 }}>
              Preencha os dados abaixo para garantir sua vaga.
            </div>
            <Campo label="Nome completo" value={nome} onChange={setNome}
              placeholder="Seu nome" required />
            <Campo label="E-mail" type="email" value={email} onChange={setEmail}
              placeholder="seu@email.com" required />
            <Campo label="Telefone / WhatsApp" value={telefone}
              onChange={setTelefone} placeholder="(00) 00000-0000" />
            {erro && (
              <div style={{ marginTop: 12, fontSize: 13, color: "#c0392b",
                background: "#fdf0ef", borderRadius: 8, padding: "8px 12px" }}>
                {erro}
              </div>
            )}
            <button
              type="submit"
              disabled={loading}
              style={{
                marginTop: 20, width: "100%", padding: "13px",
                background: loading ? T.muted : T.forest,
                color: "#fff", border: "none", borderRadius: 12,
                fontSize: 15, fontWeight: 700, fontFamily: FONT,
                cursor: loading ? "not-allowed" : "pointer",
                transition: "background 0.2s",
              }}
            >
              {loading ? "Enviando..." : "Quero me inscrever"}
            </button>
          </form>
        )}
      </div>
    </div>
  );
}
