import React, { useCallback, useEffect, useRef, useState } from "react";
import { FileText, Clock, CheckCircle2, AlertTriangle, RefreshCw, Upload, Eye, Loader2 } from "lucide-react";
import { meusDocumentos, enviarDocumento, urlDocumento } from "./lib/api";

const TIPOS_SUGERIDOS = ["RG/CNH", "CPF", "Comprovante de residência", "Histórico escolar", "Outro"];
const TAMANHO_MAXIMO = 10 * 1024 * 1024; // 10MB

function situacaoInfo(situacao, T) {
  if (situacao === "aprovado") {
    return { label: "Aprovado", bg: T?.forestDark || "#0E4536", fg: "#fff", Icon: CheckCircle2 };
  }
  if (situacao === "reprovado") {
    return { label: "Reprovado", bg: T?.danger || "#C24A3F", fg: "#fff", Icon: AlertTriangle };
  }
  return { label: "Pendente", bg: T?.amberSoft || "#FBEFDA", fg: T?.ink || "#10201A", Icon: Clock };
}

export default function MeusDocumentos({ perfil, toast, T }) {
  const [documentos, setDocumentos] = useState(null);
  const [erro, setErro] = useState("");
  const [tipo, setTipo] = useState(TIPOS_SUGERIDOS[0]);
  const [enviando, setEnviando] = useState(false);
  const [urlCarregando, setUrlCarregando] = useState(null);
  const inputRef = useRef(null);

  const carregar = useCallback(async () => {
    try {
      const data = await meusDocumentos(perfil.id);
      setDocumentos(data);
      setErro("");
    } catch (e) {
      console.error(e);
      setErro("Não foi possível carregar seus documentos.");
      setDocumentos([]);
    }
  }, [perfil.id]);

  useEffect(() => { carregar(); }, [carregar]);

  const escolherArquivo = (tipoParaEnviar) => {
    setTipo(tipoParaEnviar || tipo);
    inputRef.current?.click();
  };

  const onArquivoSelecionado = async (e) => {
    const file = e.target.files?.[0];
    e.target.value = "";
    if (!file) return;

    const tipoOk = file.type === "application/pdf" || file.type.startsWith("image/");
    if (!tipoOk) {
      toast && toast("Envie um arquivo PDF ou imagem.");
      return;
    }
    if (file.size > TAMANHO_MAXIMO) {
      toast && toast("Arquivo muito grande. O limite é 10MB.");
      return;
    }

    setEnviando(true);
    try {
      await enviarDocumento({
        usuarioId: perfil.id,
        tenantId: perfil.tenant_id,
        tipo,
        file,
      });
      toast && toast("Documento enviado! Aguarde a análise.");
      await carregar();
    } catch (err) {
      console.error(err);
      toast && toast("Erro ao enviar documento. Tente novamente.");
    } finally {
      setEnviando(false);
    }
  };

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

  const corLine = T?.line || "#DDE5E1";
  const corMuted = T?.muted || "#5C6E67";
  const corInk = T?.ink || "#10201A";
  const corForest = T?.forest || "#17604A";

  return (
    <div className="kl-fade" style={{ paddingBottom: 80 }}>
      <h1 style={{ fontSize: 22, fontWeight: 800, color: corInk, margin: "4px 0 4px" }}>Meus documentos</h1>
      <p style={{ fontSize: 13, color: corMuted, marginBottom: 16 }}>
        Envie os documentos solicitados pela secretaria. Aceitamos PDF ou imagem, até 10MB.
      </p>

      <input
        ref={inputRef}
        type="file"
        accept="application/pdf,image/*"
        style={{ display: "none" }}
        onChange={onArquivoSelecionado}
      />

      <div style={{ background: "#fff", border: `1px solid ${corLine}`, borderRadius: 14, padding: 14, marginBottom: 20 }}>
        <div style={{ fontSize: 12, fontWeight: 700, color: corMuted, textTransform: "uppercase", marginBottom: 8 }}>
          Enviar documento
        </div>
        <div style={{ display: "flex", gap: 8, flexWrap: "wrap" }}>
          <select
            value={tipo}
            onChange={(e) => setTipo(e.target.value)}
            style={{ flex: 1, minWidth: 160, padding: "10px 12px", borderRadius: 10, border: `1px solid ${corLine}`, fontSize: 13 }}
          >
            {TIPOS_SUGERIDOS.map((t) => (
              <option key={t} value={t}>{t}</option>
            ))}
          </select>
          <button
            onClick={() => escolherArquivo()}
            disabled={enviando}
            style={{ display: "flex", alignItems: "center", gap: 6, background: corForest, color: "#fff", border: "none", borderRadius: 10, padding: "10px 16px", fontSize: 13, fontWeight: 700, cursor: enviando ? "not-allowed" : "pointer" }}
          >
            {enviando ? <Loader2 className="kl-spin" size={16} /> : <Upload size={16} />}
            {enviando ? "Enviando..." : "Enviar documento"}
          </button>
        </div>
      </div>

      {documentos === null && (
        <div style={{ display: "flex", alignItems: "center", gap: 8, color: corMuted, fontSize: 13, padding: 12 }}>
          <Loader2 className="kl-spin" size={16} /> Carregando documentos...
        </div>
      )}

      {documentos !== null && erro && (
        <div style={{ fontSize: 13, color: T?.danger || "#C24A3F", padding: 12 }}>{erro}</div>
      )}

      {documentos !== null && !erro && documentos.length === 0 && (
        <div style={{ display: "flex", flexDirection: "column", alignItems: "center", gap: 8, padding: "32px 12px", color: corMuted }}>
          <FileText size={28} />
          <div style={{ fontSize: 13 }}>Você ainda não enviou nenhum documento.</div>
        </div>
      )}

      {documentos !== null && documentos.length > 0 && (
        <div style={{ background: "#fff", border: `1px solid ${corLine}`, borderRadius: 14, overflow: "hidden" }}>
          {documentos.map((doc, i) => {
            const info = situacaoInfo(doc.situacao, T);
            const Icon = info.Icon;
            return (
              <div key={doc.id} style={{ padding: "12px 14px", borderTop: i ? `1px solid ${corLine}` : "none" }}>
                <div style={{ display: "flex", justifyContent: "space-between", alignItems: "center", gap: 8, flexWrap: "wrap" }}>
                  <div>
                    <div style={{ fontSize: 13, fontWeight: 700, color: corInk }}>{doc.tipo}</div>
                    <div style={{ fontSize: 11, color: corMuted }}>{doc.nome_arquivo}</div>
                  </div>
                  <div style={{ display: "flex", alignItems: "center", gap: 8, flexWrap: "wrap" }}>
                    <span style={{ display: "flex", alignItems: "center", gap: 4, fontSize: 11, fontWeight: 700, padding: "4px 10px", borderRadius: 999, background: info.bg, color: info.fg }}>
                      <Icon size={12} /> {info.label}
                    </span>
                    <button
                      onClick={() => visualizar(doc)}
                      disabled={urlCarregando === doc.id}
                      style={{ display: "flex", alignItems: "center", gap: 4, background: "none", border: `1px solid ${corLine}`, borderRadius: 10, padding: "6px 10px", fontSize: 12, fontWeight: 700, color: corInk, cursor: "pointer" }}
                    >
                      <Eye size={13} /> Ver
                    </button>
                    {doc.situacao === "reprovado" && (
                      <button
                        onClick={() => escolherArquivo(doc.tipo)}
                        style={{ display: "flex", alignItems: "center", gap: 4, background: "none", border: `1px solid ${corLine}`, borderRadius: 10, padding: "6px 10px", fontSize: 12, fontWeight: 700, color: corInk, cursor: "pointer" }}
                      >
                        <RefreshCw size={13} /> Reenviar
                      </button>
                    )}
                  </div>
                </div>
                {doc.situacao === "reprovado" && doc.motivo && (
                  <div style={{ marginTop: 6, fontSize: 12, color: T?.danger || "#C24A3F" }}>
                    Motivo: {doc.motivo}
                  </div>
                )}
              </div>
            );
          })}
        </div>
      )}
    </div>
  );
}
