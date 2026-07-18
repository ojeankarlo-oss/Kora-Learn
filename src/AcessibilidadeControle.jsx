import React, { useEffect, useState } from "react";
import { Accessibility, Contrast, X } from "lucide-react";
import { ESCALA_FONTE } from "./theme";

const ORDEM_FONTE = ["normal", "grande", "muito_grande"];

function diminuirFonte(prefAtual) {
  const i = ORDEM_FONTE.indexOf(prefAtual);
  return ORDEM_FONTE[Math.max(0, i - 1)];
}

// Controle flutuante de acessibilidade (escala de fonte + alto contraste).
// Controlado via props para funcionar tanto logado (persistindo no backend)
// quanto deslogado (preferência só em memória, gerenciada por quem o usa).
export default function ControleAcessibilidade({ prefFonte = "normal", altoContraste = false, onFonte, onContraste, T }) {
  const [aberto, setAberto] = useState(false);

  useEffect(() => {
    document.documentElement.style.setProperty("--kl-font-scale", String(ESCALA_FONTE[prefFonte] ?? 1));
  }, [prefFonte]);

  const corForest = T?.forest || "#17604A";
  const corInk = T?.ink || "#10201A";
  const corMuted = T?.muted || "#5C6E67";
  const corLine = T?.line || "#DDE5E1";
  const corCard = T?.card || "#FFFFFF";

  const botaoFonte = (label, desc, targetPref, tamanho) => (
    <button
      key={label}
      type="button"
      onClick={() => onFonte?.(targetPref)}
      aria-label={desc}
      aria-pressed={prefFonte === targetPref}
      style={{
        flex: 1,
        padding: "8px 4px",
        borderRadius: 8,
        border: `1.5px solid ${prefFonte === targetPref ? corForest : corLine}`,
        background: prefFonte === targetPref ? corForest : "none",
        color: prefFonte === targetPref ? "#fff" : corInk,
        fontWeight: 800,
        fontSize: tamanho,
        cursor: "pointer",
      }}
    >
      {label}
    </button>
  );

  return (
    <div style={{ position: "fixed", top: 12, right: 12, zIndex: 80 }}>
      {aberto && (
        <div
          role="dialog"
          aria-label="Controles de acessibilidade"
          style={{
            marginBottom: 8,
            background: corCard,
            border: `1.5px solid ${corLine}`,
            borderRadius: 14,
            padding: 14,
            width: 220,
            boxShadow: "0 8px 30px #00000022",
            position: "absolute",
            top: 44,
            right: 0,
          }}
        >
          <div style={{ fontSize: 12, fontWeight: 700, color: corMuted, marginBottom: 8 }}>Tamanho da fonte</div>
          <div style={{ display: "flex", gap: 6 }}>
            {botaoFonte("A−", "Diminuir fonte", diminuirFonte(prefFonte), 12)}
            {botaoFonte("A", "Fonte normal", "normal", 13)}
            {botaoFonte("A+", "Fonte grande", "grande", 15)}
            {botaoFonte("A++", "Fonte muito grande", "muito_grande", 17)}
          </div>

          <div style={{ fontSize: 12, fontWeight: 700, color: corMuted, marginTop: 14, marginBottom: 8 }}>Contraste</div>
          <button
            type="button"
            onClick={() => onContraste?.(!altoContraste)}
            aria-pressed={altoContraste}
            style={{
              width: "100%",
              display: "flex",
              alignItems: "center",
              justifyContent: "center",
              gap: 6,
              padding: "8px 10px",
              borderRadius: 8,
              border: `1.5px solid ${altoContraste ? corForest : corLine}`,
              background: altoContraste ? corForest : "none",
              color: altoContraste ? "#fff" : corInk,
              fontWeight: 700,
              fontSize: 12,
              cursor: "pointer",
            }}
          >
            <Contrast size={14} /> Alto contraste {altoContraste ? "(ativo)" : ""}
          </button>
        </div>
      )}

      <button
        type="button"
        onClick={() => setAberto((v) => !v)}
        aria-label="Abrir controles de acessibilidade"
        aria-expanded={aberto}
        style={{
          width: 42,
          height: 42,
          borderRadius: "50%",
          border: "none",
          background: corForest,
          color: "#fff",
          display: "flex",
          alignItems: "center",
          justifyContent: "center",
          boxShadow: "0 4px 14px #00000033",
          cursor: "pointer",
        }}
      >
        {aberto ? <X size={20} /> : <Accessibility size={20} />}
      </button>
    </div>
  );
}
