import React, { useEffect, useState } from "react";
import { FileText, Loader2 } from "lucide-react";
import { contratoAtivo, salvarContrato } from "./lib/api";
import { CONTRATO_PADRAO_MD, CONTRATO_PADRAO_VERSAO } from "./contratoPadrao";

const PLACEHOLDERS_DISPONIVEIS = [
  "instituicao_nome", "instituicao_cnpj", "instituicao_endereco",
  "aluno_nome", "aluno_cpf", "aluno_email",
  "curso_nome", "carga_horaria", "modalidade", "unidade_nome",
  "valor_total", "condicoes_pagamento", "data_aceite", "hash_documento",
];

export default function ContratoConfig({ T, toast }) {
  const [carregando, setCarregando] = useState(true);
  const [personalizado, setPersonalizado] = useState(false);
  const [versaoAtual, setVersaoAtual] = useState(CONTRATO_PADRAO_VERSAO);
  const [texto, setTexto] = useState(CONTRATO_PADRAO_MD);
  const [salvando, setSalvando] = useState(false);

  useEffect(() => {
    let ativo = true;
    (async () => {
      try {
        const contrato = await contratoAtivo();
        if (!ativo) return;
        if (contrato) {
          setPersonalizado(true);
          setVersaoAtual(contrato.versao);
          setTexto(contrato.corpo_md || "");
        } else {
          setPersonalizado(false);
          setVersaoAtual(CONTRATO_PADRAO_VERSAO);
          setTexto(CONTRATO_PADRAO_MD);
        }
      } catch (e) {
        console.error(e);
      } finally {
        if (ativo) setCarregando(false);
      }
    })();
    return () => { ativo = false; };
  }, []);

  const salvar = async () => {
    setSalvando(true);
    try {
      await salvarContrato(texto);
      toast && toast("Nova versão do contrato salva!");
      const contrato = await contratoAtivo();
      if (contrato) {
        setPersonalizado(true);
        setVersaoAtual(contrato.versao);
      }
    } catch (e) {
      console.error(e);
      toast && toast("Erro ao salvar o contrato.");
    } finally {
      setSalvando(false);
    }
  };

  const corLine = T?.line || "#DDE5E1";
  const corMuted = T?.muted || "#5C6E67";
  const corInk = T?.ink || "#10201A";
  const corForest = T?.forest || "#17604A";

  return (
    <div style={{ marginTop: 28, background: "#fff", border: `1px solid ${corLine}`, borderRadius: 14, padding: 16 }}>
      <div style={{ display: "flex", alignItems: "center", gap: 8, marginBottom: 4 }}>
        <FileText size={16} color={corForest} />
        <div style={{ fontSize: 14, fontWeight: 800, color: corInk }}>Contrato de matrícula</div>
      </div>

      {carregando ? (
        <div style={{ display: "flex", alignItems: "center", gap: 8, color: corMuted, fontSize: 13, padding: 12 }}>
          <Loader2 className="kl-spin" size={16} /> Carregando contrato...
        </div>
      ) : (
        <>
          <div style={{ fontSize: 12, color: corMuted, marginBottom: 10 }}>
            Em uso: {personalizado ? `contrato personalizado, versão ${versaoAtual}` : `modelo padrão KORA, versão ${CONTRATO_PADRAO_VERSAO}`}
          </div>

          <textarea
            value={texto}
            onChange={(e) => setTexto(e.target.value)}
            rows={14}
            style={{ width: "100%", padding: 12, borderRadius: 10, border: `1px solid ${corLine}`, fontSize: 12, fontFamily: "monospace", lineHeight: 1.5, boxSizing: "border-box", resize: "vertical" }}
          />

          <div style={{ fontSize: 11, color: corMuted, marginTop: 8, lineHeight: 1.6 }}>
            Placeholders disponíveis: {PLACEHOLDERS_DISPONIVEIS.map((p) => `{{${p}}}`).join(", ")}.
            Campos sem valor aparecem como “—” no contrato exibido ao aluno.
          </div>

          <button
            onClick={salvar}
            disabled={salvando || !texto.trim()}
            style={{ marginTop: 12, background: corForest, color: "#fff", border: "none", borderRadius: 10, padding: "10px 18px", fontSize: 13, fontWeight: 700, cursor: salvando ? "not-allowed" : "pointer" }}
          >
            {salvando ? "Salvando..." : "Salvar nova versão"}
          </button>
        </>
      )}
    </div>
  );
}
