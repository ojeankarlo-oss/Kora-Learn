import React, { useState } from "react";
import { criarMinhaEscola, sair } from "./lib/api";

const T = {
  ink: "#10201A",
  forest: "#17604A",
  forestDark: "#0E4536",
  muted: "#6B8F7A",
  bg: "#F4F9F6",
  line: "#D0E6DA",
};

const FONT = "'Archivo', 'Inter', sans-serif";

function LogoKora({ size = 32 }) {
  return (
    <svg width={size * 3.2} height={size} viewBox="0 0 128 40" fill="none">
      <rect width="40" height="40" rx="10" fill="#E8F8EF" />
      <text x="20" y="28" textAnchor="middle" fontFamily={FONT} fontSize="22" fontWeight="800" fill={T.forest}>K</text>
      <text x="55" y="28" fontFamily={FONT} fontSize="20" fontWeight="700" fill={T.forest}>KORA</text>
      <text x="55" y="38" fontFamily={FONT} fontSize="9" fontWeight="400" fill={T.muted} letterSpacing="2">LEARN</text>
    </svg>
  );
}

function slugificar(texto) {
  return (texto || "")
    .normalize("NFD")
    .replace(/[\u0300-\u036f]/g, "")
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, "-")
    .replace(/^-+|-+$/g, "");
}

function sugerirNomeDoEmail(email) {
  const parteLocal = (email || "").split("@")[0] || "";
  return parteLocal
    .replace(/[._-]+/g, " ")
    .split(" ")
    .filter(Boolean)
    .map((palavra) => palavra.charAt(0).toUpperCase() + palavra.slice(1))
    .join(" ");
}

export default function CriarEscola({ emailSugestao, onCriada }) {
  const [nomeEscola, setNomeEscola] = useState("");
  const [slug, setSlug] = useState("");
  const [slugEditadoManualmente, setSlugEditadoManualmente] = useState(false);
  const [nomeGestor, setNomeGestor] = useState(() => sugerirNomeDoEmail(emailSugestao));
  const [erro, setErro] = useState("");
  const [sucesso, setSucesso] = useState("");
  const [loading, setLoading] = useState(false);
  const [saindo, setSaindo] = useState(false);

  const voltarAoLogin = async () => {
    setSaindo(true);
    try {
      await sair();
    } finally {
      window.location.hash = "#/";
    }
  };

  const handleNomeEscolaChange = (valor) => {
    setNomeEscola(valor);
    if (!slugEditadoManualmente) {
      setSlug(slugificar(valor));
    }
  };

  const handleSlugChange = (valor) => {
    setSlugEditadoManualmente(true);
    setSlug(slugificar(valor));
  };

  const handleSubmit = async (e) => {
    e.preventDefault();
    setErro("");
    setSucesso("");

    if (!nomeEscola.trim()) {
      setErro("Informe o nome da instituição.");
      return;
    }
    if (!slug.trim()) {
      setErro("Informe o identificador da escola.");
      return;
    }
    if (!nomeGestor.trim()) {
      setErro("Informe seu nome.");
      return;
    }

    setLoading(true);
    try {
      await criarMinhaEscola({
        nomeEscola: nomeEscola.trim(),
        slug: slug.trim(),
        nomeGestor: nomeGestor.trim(),
      });
      setSucesso("Escola criada! Redirecionando ao painel...");
      window.setTimeout(() => {
        if (onCriada) onCriada();
      }, 900);
    } catch (e) {
      setErro(e?.message || "Não foi possível criar sua escola. Tente novamente.");
      setLoading(false);
    }
  };

  return (
    <div style={{ minHeight: "100vh", background: T.forestDark, display: "flex", alignItems: "center", justifyContent: "center", padding: 24, fontFamily: FONT }}>
      <div style={{ width: "100%", maxWidth: 440, background: "#fff", borderRadius: 22, padding: 24, boxShadow: "0 8px 30px #00000022" }}>
        <div style={{ textAlign: "center", marginBottom: 18 }}>
          <LogoKora size={30} />
          <div style={{ fontSize: 18, fontWeight: 700, color: T.ink, marginTop: 12 }}>
            Vamos criar sua escola no KORA Learn!
          </div>
          <div style={{ fontSize: 13, color: T.muted, marginTop: 8, lineHeight: 1.5 }}>
            Leva menos de um minuto. Você poderá ajustar tudo depois.
          </div>
        </div>

        <form onSubmit={handleSubmit}>
          <label style={{ display: "block", fontSize: 12, fontWeight: 600, color: T.muted, marginBottom: 4 }}>Nome da instituição</label>
          <input
            type="text"
            value={nomeEscola}
            onChange={(e) => handleNomeEscolaChange(e.target.value)}
            placeholder="Ex.: Escola Nova Geração"
            style={{ width: "100%", boxSizing: "border-box", padding: "10px 12px", borderRadius: 10, border: `1.5px solid ${T.line}`, fontSize: 14, marginBottom: 12 }}
          />

          <label style={{ display: "block", fontSize: 12, fontWeight: 600, color: T.muted, marginBottom: 4 }}>Identificador da escola</label>
          <input
            type="text"
            value={slug}
            onChange={(e) => handleSlugChange(e.target.value)}
            placeholder="minha-escola"
            style={{ width: "100%", boxSizing: "border-box", padding: "10px 12px", borderRadius: 10, border: `1.5px solid ${T.line}`, fontSize: 14 }}
          />
          <div style={{ fontSize: 12, color: T.muted, marginTop: 4, marginBottom: 12, lineHeight: 1.4 }}>
            Será usado no link público, ex.: minha-escola. Só letras, números e hífen.
          </div>

          <label style={{ display: "block", fontSize: 12, fontWeight: 600, color: T.muted, marginBottom: 4 }}>Seu nome</label>
          <input
            type="text"
            value={nomeGestor}
            onChange={(e) => setNomeGestor(e.target.value)}
            placeholder="Seu nome completo"
            style={{ width: "100%", boxSizing: "border-box", padding: "10px 12px", borderRadius: 10, border: `1.5px solid ${T.line}`, fontSize: 14, marginBottom: 12 }}
          />

          {erro && <div style={{ marginBottom: 10, padding: "8px 10px", borderRadius: 8, background: "#FCECEA", color: "#B93B2D", fontSize: 13 }}>{erro}</div>}
          {sucesso && <div style={{ marginBottom: 10, padding: "8px 10px", borderRadius: 8, background: "#EAF6F0", color: T.forest, fontSize: 13, fontWeight: 600 }}>{sucesso}</div>}

          <button
            type="submit"
            disabled={loading || !!sucesso}
            style={{ width: "100%", padding: "12px 14px", borderRadius: 12, border: "none", background: loading || sucesso ? T.muted : T.forest, color: "#fff", fontWeight: 700, fontSize: 14, cursor: loading || sucesso ? "not-allowed" : "pointer" }}
          >
            {loading ? "Criando..." : "Criar minha escola"}
          </button>
        </form>
        <button onClick={voltarAoLogin} disabled={saindo} style={{ width: "100%", marginTop: 10, background: "transparent", border: "none", color: T.forest, fontWeight: 600, fontSize: 13, cursor: saindo ? "not-allowed" : "pointer" }}>
          Voltar ao login
        </button>
      </div>
    </div>
  );
}
