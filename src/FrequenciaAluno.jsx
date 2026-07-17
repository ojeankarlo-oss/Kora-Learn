import React, { useCallback, useEffect, useState } from "react";
import { AlertTriangle, Loader2, RefreshCw } from "lucide-react";
import { minhaFrequencia } from "./lib/api";

const LIMITE_ATENCAO = 75;

export default function FrequenciaAluno({ T }) {
  const [frequencias, setFrequencias] = useState(null);
  const [erro, setErro] = useState("");

  const corLine = T?.line || "#DDE5E1";
  const corMuted = T?.muted || "#5C6E67";
  const corInk = T?.ink || "#10201A";
  const corForest = T?.forest || "#17604A";
  const corDanger = T?.danger || "#C24A3F";
  const corAmber = T?.amber || "#E9A13B";

  const carregar = useCallback(async () => {
    try {
      setErro("");
      const data = await minhaFrequencia();
      setFrequencias(data);
    } catch (e) {
      console.error(e);
      setErro("Não foi possível carregar sua frequência.");
      setFrequencias([]);
    }
  }, []);

  useEffect(() => { carregar(); }, [carregar]);

  if (erro) {
    return (
      <div style={{ marginTop: 20, padding: 16, border: `1px solid ${corLine}`, borderRadius: 14, textAlign: "center" }}>
        <AlertTriangle size={22} color={corDanger} />
        <div style={{ fontSize: 13, color: corMuted, marginTop: 6 }}>{erro}</div>
        <button onClick={carregar} style={{ marginTop: 10, display: "inline-flex", alignItems: "center", gap: 6, background: corForest, color: "#fff", border: "none", borderRadius: 999, padding: "8px 16px", fontSize: 13, fontWeight: 700, cursor: "pointer" }}>
          <RefreshCw size={13} /> Tentar de novo
        </button>
      </div>
    );
  }

  if (frequencias === null) {
    return (
      <div style={{ marginTop: 20, display: "flex", alignItems: "center", gap: 8, color: corMuted, fontSize: 13 }}>
        <Loader2 size={16} className="kl-spin" /> Carregando sua frequência...
      </div>
    );
  }

  if (frequencias.length === 0) {
    return null;
  }

  return (
    <div style={{ marginTop: 20 }}>
      <div style={{ fontSize: 13, fontWeight: 700, color: corMuted, textTransform: "uppercase", letterSpacing: "0.06em" }}>
        Minha frequência
      </div>
      <div style={{ display: "flex", flexDirection: "column", gap: 8, marginTop: 8 }}>
        {frequencias.map((f, i) => {
          const percentual = Math.round(Number(f.percentual_frequencia) || 0);
          const abaixoDoRecomendado = percentual < LIMITE_ATENCAO;
          const corBarra = abaixoDoRecomendado ? corAmber : corForest;
          return (
            <div key={`${f.turma_id}-${f.disciplina_id}-${i}`} style={{ border: `1px solid ${corLine}`, borderRadius: 14, padding: 14 }}>
              <div style={{ display: "flex", justifyContent: "space-between", alignItems: "center", gap: 8 }}>
                <div>
                  <div style={{ fontSize: 14, fontWeight: 700, color: corInk }}>{f.disciplina_nome || "Disciplina"}</div>
                  <div style={{ fontSize: 12, color: corMuted }}>{f.turma_nome || "Turma"}</div>
                </div>
                <div style={{ fontSize: 22, fontWeight: 800, color: corBarra }}>{percentual}%</div>
              </div>
              <div style={{ marginTop: 8, height: 6, borderRadius: 999, background: corLine, overflow: "hidden" }}>
                <div style={{ width: `${Math.min(100, Math.max(0, percentual))}%`, height: "100%", background: corBarra }} />
              </div>
              <div style={{ fontSize: 12, color: corMuted, marginTop: 8 }}>
                {f.total_aulas ?? 0} aulas · {f.total_presencas ?? 0} presenças · {f.total_ausencias ?? 0} faltas · {f.total_justificadas ?? 0} justificadas
              </div>
              {abaixoDoRecomendado && (
                <div style={{ fontSize: 12, color: corAmber, marginTop: 8, fontWeight: 600 }}>
                  Atenção: frequência abaixo do recomendado
                </div>
              )}
            </div>
          );
        })}
      </div>
    </div>
  );
}
