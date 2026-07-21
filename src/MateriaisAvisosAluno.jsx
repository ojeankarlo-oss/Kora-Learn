import React, { useCallback, useEffect, useState } from "react";
import { AlertTriangle, Loader2, RefreshCw, FileText, Link2, Video, Book } from "lucide-react";
import { materiaisEAvisosDoAluno } from "./lib/api";

const ICONE_TIPO_MATERIAL = { artigo: FileText, pdf: FileText, link: Link2, video: Video, livro_indicado: Book };

const ROTULOS_TIPO_AVISO = {
  prova: "Prova",
  trabalho: "Trabalho",
  evento: "Evento",
  aviso_geral: "Aviso geral",
};

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

export default function MateriaisAvisosAluno({ T }) {
  const [dados, setDados] = useState(null);
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
      const data = await materiaisEAvisosDoAluno();
      setDados(data);
    } catch (e) {
      console.error(e);
      setErro("Não foi possível carregar materiais e avisos.");
      setDados({ materiais: [], avisos: [] });
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

  if (dados === null) {
    return (
      <div style={{ marginTop: 20, display: "flex", alignItems: "center", gap: 8, color: corMuted, fontSize: 13 }}>
        <Loader2 size={16} className="kl-spin" /> Carregando materiais e avisos...
      </div>
    );
  }

  const { materiais, avisos } = dados;
  if (materiais.length === 0 && avisos.length === 0) return null;

  return (
    <div style={{ marginTop: 20 }}>
      {avisos.length > 0 && (
        <>
          <div style={{ fontSize: 13, fontWeight: 700, color: corMuted, textTransform: "uppercase", letterSpacing: "0.06em" }}>
            Agenda e avisos
          </div>
          <div style={{ display: "flex", flexDirection: "column", gap: 8, marginTop: 8 }}>
            {avisos.map((a) => {
              const urgente = avisoEhUrgente(a);
              return (
                <div key={a.id} style={{ border: `1px solid ${urgente ? corAmber : corLine}`, background: urgente ? "#FFF5E3" : "transparent", borderRadius: 14, padding: 14 }}>
                  <div style={{ display: "flex", alignItems: "center", gap: 6 }}>
                    <span style={{ fontSize: 11, fontWeight: 700, padding: "2px 8px", borderRadius: 999, background: urgente ? corAmber : corLine, color: urgente ? "#fff" : corMuted }}>
                      {ROTULOS_TIPO_AVISO[a.tipo] || "Aviso"}
                    </span>
                    {a.data_evento && <span style={{ fontSize: 12, color: corMuted, fontWeight: 600 }}>{formatarData(a.data_evento)}</span>}
                    <span style={{ fontSize: 11, color: corMuted, marginLeft: "auto" }}>{a.turma?.nome || ""}</span>
                  </div>
                  <div style={{ fontSize: 14, fontWeight: 700, color: corInk, marginTop: 6 }}>{a.titulo}</div>
                  {a.descricao && <div style={{ fontSize: 12, color: corMuted, marginTop: 2 }}>{a.descricao}</div>}
                </div>
              );
            })}
          </div>
        </>
      )}

      {materiais.length > 0 && (
        <>
          <div style={{ fontSize: 13, fontWeight: 700, color: corMuted, textTransform: "uppercase", letterSpacing: "0.06em", marginTop: avisos.length > 0 ? 20 : 0 }}>
            Materiais
          </div>
          <div style={{ display: "flex", flexDirection: "column", gap: 8, marginTop: 8 }}>
            {materiais.map((m) => {
              const Icone = ICONE_TIPO_MATERIAL[m.tipo] || FileText;
              return (
                <div key={m.id} style={{ border: `1px solid ${corLine}`, borderRadius: 14, padding: 14, display: "flex", gap: 10, alignItems: "flex-start" }}>
                  <Icone size={16} color={corForest} style={{ marginTop: 2, flexShrink: 0 }} />
                  <div style={{ flex: 1 }}>
                    <div style={{ fontSize: 14, fontWeight: 700, color: corInk }}>{m.titulo}</div>
                    <div style={{ fontSize: 11, color: corMuted, marginTop: 2 }}>{m.turma?.nome || ""}</div>
                    {m.descricao && <div style={{ fontSize: 12, color: corMuted, marginTop: 4 }}>{m.descricao}</div>}
                    {m.url && (
                      <a href={m.url} target="_blank" rel="noreferrer" style={{ fontSize: 12, color: corForest, fontWeight: 600, display: "inline-block", marginTop: 4 }}>
                        Abrir material
                      </a>
                    )}
                  </div>
                </div>
              );
            })}
          </div>
        </>
      )}
    </div>
  );
}
