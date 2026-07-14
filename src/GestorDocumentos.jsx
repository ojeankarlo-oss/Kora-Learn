import React, { useCallback, useEffect, useState } from "react";
import { X, FileText, Clock, CheckCircle2, AlertTriangle, Eye, Loader2 } from "lucide-react";
import { meusDocumentos, avaliarDocumento, urlDocumento } from "./lib/api";

function situacaoInfo(situacao, T) {
  if (situacao === "aprovado") {
    return { label: "Aprovado", bg: T?.forestDark || "#0E4536", fg: "#fff", Icon: CheckCircle2 };
  }
  if (situacao === "reprovado") {
    return { label: "Reprovado", bg: T?.danger || "#C24A3F", fg: "#fff", Icon: AlertTriangle };
  }
  return { label: "Pendente", bg: T?.amberSoft || "#FBEFDA", fg: T?.ink || "#10201A", Icon: Clock };
}

export default function DocumentosAlunoModal({ aluno, toast, T, onClose, onChange }) {
  const [documentos, setDocumentos] = useState(null);
  const [erro, setErro] = useState("");
  const [processando, setProcessando] = useState(null);
  const [urlCarregando, setUrlCarregando] = useState(null);

  const carregar = useCallback(async () => {
    if (!aluno?.id) return;
    try {
      const data = await meusDocumentos(aluno.id);
      setDocumentos(data);
      setErro("");
    } catch (e) {
      console.error(e);
      setErro("Não foi possível carregar os documentos deste aluno.");
      setDocumentos([]);
    }
  }, [aluno?.id]);

  useEffect(() => { carregar(); }, [carregar]);

  const visualizar = async (doc) => {
    setUrlCarregando(doc.id);
    try {
      const url = await urlDocumento(doc.storage_path);
      window.open(url, "_blank", "noopener,noreferrer");
    } catch (e) {
      console.error(e);
      toast && toast("Não foi possível abrir o documento.");
    } finally {
      setUrlCarregando(null);
    }
  };

  const aprovar = async (doc) => {
    setProcessando(doc.id);
    try {
      await avaliarDocumento(doc.id, "aprovado", null);
      toast && toast("Documento aprovado.");
      await carregar();
      onChange && onChange();
    } catch (e) {
      console.error(e);
      toast && toast("Erro ao aprovar documento.");
    } finally {
      setProcessando(null);
    }
  };

  const solicitarReenvio = async (doc) => {
    const motivo = window.prompt("Motivo da recusa (visível para o aluno):", "");
    if (motivo === null) return;
    if (!motivo.trim()) {
      toast && toast("Informe um motivo para solicitar o reenvio.");
      return;
    }
    setProcessando(doc.id);
    try {
      await avaliarDocumento(doc.id, "reprovado", motivo.trim());
      toast && toast("Reenvio solicitado ao aluno.");
      await carregar();
      onChange && onChange();
    } catch (e) {
      console.error(e);
      toast && toast("Erro ao solicitar reenvio.");
    } finally {
      setProcessando(null);
    }
  };

  const corLine = T?.line || "#DDE5E1";
  const corMuted = T?.muted || "#5C6E67";
  const corInk = T?.ink || "#10201A";
  const corForest = T?.forest || "#17604A";
  const corDanger = T?.danger || "#C24A3F";

  return (
    <div
      onClick={onClose}
      style={{ position: "fixed", inset: 0, background: "rgba(16,32,26,0.45)", display: "flex", alignItems: "center", justifyContent: "center", zIndex: 60, padding: 16 }}
    >
      <div
        onClick={(e) => e.stopPropagation()}
        style={{ width: "100%", maxWidth: 560, maxHeight: "85vh", overflowY: "auto", background: "#fff", borderRadius: 16, padding: 20 }}
      >
        <div style={{ display: "flex", justifyContent: "space-between", alignItems: "center", marginBottom: 4 }}>
          <div style={{ display: "flex", alignItems: "center", gap: 8 }}>
            <FileText size={18} color={corForest} />
            <h2 style={{ fontSize: 16, fontWeight: 800, color: corInk, margin: 0 }}>
              Documentos de {aluno?.nome || "aluno"}
            </h2>
          </div>
          <button onClick={onClose} style={{ background: "none", border: "none", cursor: "pointer", padding: 4 }}>
            <X size={18} color={corMuted} />
          </button>
        </div>

        {documentos === null && (
          <div style={{ display: "flex", alignItems: "center", gap: 8, color: corMuted, fontSize: 13, padding: 20 }}>
            <Loader2 className="kl-spin" size={16} /> Carregando...
          </div>
        )}

        {documentos !== null && erro && (
          <div style={{ fontSize: 13, color: corDanger, padding: 12 }}>{erro}</div>
        )}

        {documentos !== null && !erro && documentos.length === 0 && (
          <div style={{ fontSize: 13, color: corMuted, padding: 20, textAlign: "center" }}>
            Este aluno ainda não enviou documentos.
          </div>
        )}

        {documentos !== null && documentos.length > 0 && (
          <div style={{ marginTop: 12, border: `1px solid ${corLine}`, borderRadius: 12, overflow: "hidden" }}>
            {documentos.map((doc, i) => {
              const info = situacaoInfo(doc.situacao, T);
              const Icon = info.Icon;
              const ocupado = processando === doc.id;
              return (
                <div key={doc.id} style={{ padding: "12px 14px", borderTop: i ? `1px solid ${corLine}` : "none" }}>
                  <div style={{ display: "flex", justifyContent: "space-between", alignItems: "center", gap: 8, flexWrap: "wrap" }}>
                    <div>
                      <div style={{ fontSize: 13, fontWeight: 700, color: corInk }}>{doc.tipo}</div>
                      <div style={{ fontSize: 11, color: corMuted }}>{doc.nome_arquivo}</div>
                    </div>
                    <span style={{ display: "flex", alignItems: "center", gap: 4, fontSize: 11, fontWeight: 700, padding: "4px 10px", borderRadius: 999, background: info.bg, color: info.fg }}>
                      <Icon size={12} /> {info.label}
                    </span>
                  </div>
                  {doc.situacao === "reprovado" && doc.motivo && (
                    <div style={{ marginTop: 6, fontSize: 12, color: corDanger }}>Motivo: {doc.motivo}</div>
                  )}
                  <div style={{ display: "flex", gap: 8, marginTop: 8, flexWrap: "wrap" }}>
                    <button
                      onClick={() => visualizar(doc)}
                      disabled={urlCarregando === doc.id}
                      style={{ display: "flex", alignItems: "center", gap: 4, background: "none", border: `1px solid ${corLine}`, borderRadius: 10, padding: "6px 10px", fontSize: 12, fontWeight: 700, color: corInk, cursor: "pointer" }}
                    >
                      <Eye size={13} /> Ver
                    </button>
                    {doc.situacao !== "aprovado" && (
                      <button
                        onClick={() => aprovar(doc)}
                        disabled={ocupado}
                        style={{ background: corForest, color: "#fff", border: "none", borderRadius: 10, padding: "6px 12px", fontSize: 12, fontWeight: 700, cursor: ocupado ? "not-allowed" : "pointer" }}
                      >
                        Aprovar
                      </button>
                    )}
                    {doc.situacao !== "reprovado" && (
                      <button
                        onClick={() => solicitarReenvio(doc)}
                        disabled={ocupado}
                        style={{ background: "none", color: corDanger, border: `1px solid ${corDanger}`, borderRadius: 10, padding: "6px 12px", fontSize: 12, fontWeight: 700, cursor: ocupado ? "not-allowed" : "pointer" }}
                      >
                        Solicitar reenvio
                      </button>
                    )}
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
