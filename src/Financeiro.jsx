import React, { useCallback, useEffect, useState } from "react";
import { Wallet, CheckCircle2, AlertTriangle, Clock, XCircle, RefreshCw, Loader2, QrCode, Copy, ExternalLink, X } from "lucide-react";
import QRCode from "qrcode";
import { meusTitulos, gerarPixTitulo } from "./lib/api";

const brl = new Intl.NumberFormat("pt-BR", { style: "currency", currency: "BRL" });

function formatarCentavos(centavos) {
  return brl.format((Number(centavos) || 0) / 100);
}

function formatarData(iso) {
  if (!iso) return "";
  const [ano, mes, dia] = String(iso).slice(0, 10).split("-");
  return `${dia}/${mes}/${ano}`;
}

function hojeISO() {
  return new Date().toISOString().slice(0, 10);
}

// Deriva a situacao de exibicao (Vencida nao existe no banco).
function situacaoExibicao(titulo) {
  if (titulo.situacao === "aberto" && titulo.data_vencimento < hojeISO()) return "vencida";
  return titulo.situacao;
}

function seloInfo(sit, T) {
  if (sit === "pago") {
    return { label: "Paga", bg: T?.success || "#2E8B63", fg: "#fff", Icon: CheckCircle2 };
  }
  if (sit === "vencida") {
    return { label: "Vencida", bg: T?.danger || "#C24A3F", fg: "#fff", Icon: AlertTriangle };
  }
  if (sit === "cancelado") {
    return { label: "Cancelada", bg: T?.line || "#DDE5E1", fg: T?.muted || "#5C6E67", Icon: XCircle };
  }
  return { label: "Em aberto", bg: T?.amberSoft || "#FBEFDA", fg: T?.ink || "#10201A", Icon: Clock };
}

export default function Financeiro({ T }) {
  const [titulos, setTitulos] = useState(null);
  const [erro, setErro] = useState("");
  const [pixCarregando, setPixCarregando] = useState(null);
  const [pixAberto, setPixAberto] = useState(null);
  const [pixQrDataUrl, setPixQrDataUrl] = useState("");
  const [pixCopiado, setPixCopiado] = useState(false);

  const carregar = useCallback(async () => {
    try {
      setErro("");
      const data = await meusTitulos();
      setTitulos(data);
    } catch (e) {
      console.error(e);
      setErro("Não foi possível carregar suas cobranças.");
      setTitulos([]);
    }
  }, []);

  useEffect(() => { carregar(); }, [carregar]);

  useEffect(() => {
    let ativo = true;
    setPixCopiado(false);
    if (!pixAberto?.pix_copia_e_cola) {
      setPixQrDataUrl("");
      return () => { ativo = false; };
    }
    QRCode.toDataURL(pixAberto.pix_copia_e_cola, { width: 240, margin: 2, errorCorrectionLevel: "M" })
      .then((url) => { if (ativo) setPixQrDataUrl(url); })
      .catch((e) => { console.error(e); if (ativo) setPixQrDataUrl(""); });
    return () => { ativo = false; };
  }, [pixAberto]);

  async function abrirPix(titulo) {
    setPixCarregando(titulo.id);
    try {
      const resposta = await gerarPixTitulo(titulo.id);
      if (!resposta?.cobranca) throw new Error("Cobrança Pix não retornada");
      setPixAberto({ ...resposta.cobranca, titulo });
    } catch (e) {
      console.error(e);
      setErro(e?.message || "Não foi possível gerar o Pix.");
    } finally {
      setPixCarregando(null);
    }
  }

  async function copiarPix() {
    if (!pixAberto?.pix_copia_e_cola) return;
    try {
      await navigator.clipboard.writeText(pixAberto.pix_copia_e_cola);
      setPixCopiado(true);
    } catch (e) {
      console.error(e);
      setErro("Não foi possível copiar automaticamente.");
    }
  }

  // Proximo vencimento: primeiro titulo aberto com vencimento hoje ou futuro.
  const proximo = (titulos || [])
    .filter((t) => t.situacao === "aberto" && t.data_vencimento >= hojeISO())
    .sort((a, b) => a.data_vencimento.localeCompare(b.data_vencimento))[0];

  const estilos = {
    wrap: { padding: "16px 18px 90px", maxWidth: 640, margin: "0 auto" },
    card: { background: T?.card || "#fff", borderRadius: 14, border: `1px solid ${T?.line || "#DDE5E1"}`, padding: 16, marginBottom: 12 },
    titulo: { fontSize: 18, fontWeight: 800, color: T?.ink || "#10201A", display: "flex", alignItems: "center", gap: 8, marginBottom: 12 },
    linhaTop: { fontSize: 13, color: T?.muted || "#5C6E67" },
    valor: { fontSize: 15, fontWeight: 800, color: T?.ink || "#10201A" },
    selo: { display: "inline-flex", alignItems: "center", gap: 4, borderRadius: 999, padding: "2px 10px", fontSize: 11, fontWeight: 700 },
    rodape: { textAlign: "center", fontSize: 12, color: T?.muted || "#5C6E67", marginTop: 18 },
  };

  return (
    <div style={estilos.wrap}>
      <div style={estilos.titulo}>
        <Wallet size={22} color={T?.forest || "#17604A"} />
        Financeiro
      </div>

      {/* Resumo */}
      <div style={{ ...estilos.card, background: T?.amberSoft || "#FBEFDA", border: "none" }}>
        {proximo ? (
          <div style={{ fontSize: 14, color: T?.ink || "#10201A", fontWeight: 600 }}>
            Próximo vencimento: {formatarData(proximo.data_vencimento)} — {formatarCentavos(proximo.valor_centavos)}
          </div>
        ) : (
          <div style={{ fontSize: 14, color: T?.forestDark || "#0E4536", fontWeight: 700 }}>
            Você está em dia! 🎉
          </div>
        )}
      </div>

      {/* Estados */}
      {erro && (
        <div style={estilos.card}>
          <div style={{ fontSize: 14, color: T?.danger || "#C24A3F", marginBottom: 10 }}>{erro}</div>
          <button
            onClick={carregar}
            style={{ display: "inline-flex", alignItems: "center", gap: 6, border: `1px solid ${T?.line || "#DDE5E1"}`, background: "none", borderRadius: 999, padding: "6px 14px", fontSize: 13, fontWeight: 700, color: T?.ink || "#10201A", cursor: "pointer" }}
          >
            <RefreshCw size={14} /> Tentar de novo
          </button>
        </div>
      )}

      {!erro && titulos === null && (
        <div style={{ ...estilos.card, display: "flex", alignItems: "center", gap: 8, color: T?.muted || "#5C6E67" }}>
          <Loader2 size={16} className="kl-spin" /> Carregando suas cobranças...
        </div>
      )}

      {!erro && titulos !== null && titulos.length === 0 && (
        <div style={{ ...estilos.card, textAlign: "center", color: T?.muted || "#5C6E67", fontSize: 14 }}>
          Você não possui cobranças no momento.
        </div>
      )}

      {!erro && titulos !== null && titulos.length > 0 && titulos.map((t) => {
        const sit = situacaoExibicao(t);
        const selo = seloInfo(sit, T);
        const SeloIcon = selo.Icon;
        return (
          <div key={t.id} style={estilos.card}>
            <div style={{ display: "flex", justifyContent: "space-between", alignItems: "flex-start", gap: 10 }}>
              <div style={{ flex: 1 }}>
                <div style={{ fontSize: 14, fontWeight: 700, color: T?.ink || "#10201A" }}>{t.descricao}</div>
                <div style={estilos.linhaTop}>
                  Vencimento: {formatarData(t.data_vencimento)}
                  {sit === "pago" && t.data_pagamento ? ` · Pago em ${formatarData(t.data_pagamento)}` : ""}
                </div>
              </div>
              <div style={{ textAlign: "right" }}>
                <div style={estilos.valor}>{formatarCentavos(t.valor_centavos)}</div>
                <span style={{ ...estilos.selo, background: selo.bg, color: selo.fg, marginTop: 6 }}>
                  <SeloIcon size={12} /> {selo.label}
                </span>
                {t.situacao === "aberto" && (
                  <button onClick={() => abrirPix(t)} disabled={pixCarregando === t.id} style={{ display: "inline-flex", alignItems: "center", gap: 4, marginTop: 8, background: T?.forest || "#17604A", color: "#fff", border: "none", borderRadius: 999, padding: "6px 10px", fontSize: 11, fontWeight: 700, cursor: "pointer" }}>
                    {pixCarregando === t.id ? <Loader2 size={12} className="kl-spin" /> : <QrCode size={12} />} Pagar com Pix
                  </button>
                )}
              </div>
            </div>
          </div>
        );
      })}

      <div style={estilos.rodape}>Em caso de dúvida, fale com a secretaria.</div>

      {pixAberto && (
        <div role="dialog" aria-modal="true" aria-label="Pagamento Pix" onClick={() => setPixAberto(null)} style={{ position: "fixed", inset: 0, zIndex: 100, background: "#10201A99", display: "flex", alignItems: "center", justifyContent: "center", padding: 16 }}>
          <div onClick={(e) => e.stopPropagation()} style={{ ...estilos.card, width: "min(100%, 420px)", maxHeight: "90vh", overflow: "auto", margin: 0, position: "relative" }}>
            <button onClick={() => setPixAberto(null)} aria-label="Fechar" style={{ position: "absolute", top: 12, right: 12, border: "none", background: "none", color: T?.muted, cursor: "pointer" }}><X size={18} /></button>
            <div style={{ fontSize: 16, fontWeight: 800, color: T?.ink, paddingRight: 28 }}>Pagar com Pix</div>
            <div style={{ fontSize: 12, color: T?.muted, marginTop: 4 }}>{pixAberto.titulo?.descricao} · {formatarCentavos(pixAberto.valor_centavos)}</div>
            {pixQrDataUrl ? <div style={{ display: "flex", justifyContent: "center", margin: "18px 0 12px" }}><img src={pixQrDataUrl} alt="QR Code Pix" width="240" height="240" style={{ borderRadius: 10, border: `1px solid ${T?.line}` }} /></div> : <div style={{ marginTop: 18, padding: 14, borderRadius: 10, background: T?.paper, color: T?.muted, fontSize: 12 }}>O QR Code não foi retornado pelo provedor. Use o payload abaixo.</div>}
            <textarea readOnly aria-label="Pix copia e cola" value={pixAberto.pix_copia_e_cola || ""} rows={4} style={{ width: "100%", padding: "8px 10px", borderRadius: 8, border: `1px solid ${T?.line}`, fontFamily: "monospace", fontSize: 11, boxSizing: "border-box", resize: "vertical" }} />
            <div style={{ display: "flex", gap: 8, marginTop: 10, flexWrap: "wrap" }}>
              <button onClick={copiarPix} disabled={!pixAberto.pix_copia_e_cola} style={{ display: "inline-flex", alignItems: "center", gap: 6, background: T?.forest, color: "#fff", border: "none", borderRadius: 999, padding: "8px 14px", fontSize: 12, fontWeight: 700, cursor: "pointer" }}><Copy size={13} /> {pixCopiado ? "Copiado" : "Copiar código"}</button>
              {pixAberto.location && <a href={pixAberto.location.startsWith("http") ? pixAberto.location : `https://${pixAberto.location}`} target="_blank" rel="noreferrer" style={{ display: "inline-flex", alignItems: "center", gap: 6, border: `1px solid ${T?.line}`, color: T?.ink, textDecoration: "none", borderRadius: 999, padding: "8px 14px", fontSize: 12, fontWeight: 700 }}><ExternalLink size={13} /> Abrir location</a>}
            </div>
          </div>
        </div>
      )}
    </div>
  );
}
