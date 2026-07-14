import React, { useEffect, useState } from "react";
import { Lock, FileText, AlertTriangle, Loader2 } from "lucide-react";
import { meuTenant, contratoAtivo, registrarAceite } from "./lib/api";
import {
  CONTRATO_PADRAO_MD,
  CONTRATO_PADRAO_VERSAO,
  preencherContrato,
  hashTexto,
} from "./contratoPadrao";

export const LGPD_VERSAO = "lgpd-1.0";

export const TEXTO_LGPD = `TERMO DE CONSENTIMENTO PARA TRATAMENTO DE DADOS PESSOAIS (LGPD)

Ao continuar, você autoriza a instituição a tratar seus dados pessoais (nome, e-mail, telefone, documentos enviados e dados acadêmicos) com a finalidade exclusiva de executar o contrato educacional, cumprir obrigações legais e regulatórias e manter contato sobre o curso, nos termos da Lei 13.709/2018 (Lei Geral de Proteção de Dados Pessoais).

Caso o(a) titular seja menor de 18 anos, este consentimento é prestado pelo responsável legal indicado no cadastro, que declara ter capacidade legal para tanto.

Você poderá, a qualquer momento, solicitar acesso, correção, eliminação ou portabilidade dos seus dados junto à secretaria da instituição.`;

function SpinnerLocal({ label }) {
  return (
    <div style={{ display: "flex", alignItems: "center", gap: 8, padding: 24, color: "#666" }}>
      <Loader2 className="kl-spin" size={18} />
      <span style={{ fontSize: 13 }}>{label}</span>
    </div>
  );
}

export default function AceiteScreen({ perfil, curso, toast, T, onAceito }) {
  const [carregando, setCarregando] = useState(true);
  const [erroCarga, setErroCarga] = useState("");
  const [contratoTexto, setContratoTexto] = useState("");
  const [contratoInfo, setContratoInfo] = useState({ id: null, versao: CONTRATO_PADRAO_VERSAO });
  const [lgpdChecked, setLgpdChecked] = useState(false);
  const [contratoChecked, setContratoChecked] = useState(false);
  const [enviando, setEnviando] = useState(false);
  const [erroEnvio, setErroEnvio] = useState("");
  const [tentativa, setTentativa] = useState(0);

  useEffect(() => {
    let ativo = true;
    (async () => {
      setCarregando(true);
      setErroCarga("");
      try {
        const [tenant, contrato] = await Promise.all([meuTenant(), contratoAtivo()]);
        if (!ativo) return;
        const md = contrato?.corpo_md || CONTRATO_PADRAO_MD;
        const versao = contrato?.versao || CONTRATO_PADRAO_VERSAO;
        const dados = {
          instituicao_nome: tenant?.nome,
          instituicao_cnpj: tenant?.config?.cnpj,
          instituicao_endereco: tenant?.config?.endereco,
          aluno_nome: perfil?.nome,
          aluno_cpf: perfil?.cpf,
          aluno_email: perfil?.email,
          curso_nome: curso?.nome,
          carga_horaria: curso?.carga_horaria,
          modalidade: curso?.modalidade,
          unidade_nome: curso?.unidade?.nome,
          valor_total: curso?.valor_total,
          condicoes_pagamento: curso?.condicoes_pagamento,
          data_aceite: new Date().toLocaleString("pt-BR"),
          hash_documento: undefined,
        };
        const texto = preencherContrato(md, dados);
        setContratoTexto(texto);
        setContratoInfo({ id: contrato?.id ?? null, versao });
      } catch (e) {
        console.error(e);
        if (ativo) setErroCarga("Não foi possível carregar o contrato. Verifique sua conexão e tente novamente.");
      } finally {
        if (ativo) setCarregando(false);
      }
    })();
    return () => { ativo = false; };
  }, [perfil?.id, tentativa]);

  const podeAceitar = lgpdChecked && contratoChecked && !enviando && !carregando && !erroCarga;

  const aceitar = async () => {
    if (!podeAceitar) return;
    setEnviando(true);
    setErroEnvio("");
    try {
      const hashLgpd = await hashTexto(TEXTO_LGPD);
      const hashContrato = await hashTexto(contratoTexto);
      await registrarAceite({ tipo: "lgpd", versao: LGPD_VERSAO, hash: hashLgpd });
      await registrarAceite({
        tipo: "contrato",
        contratoId: contratoInfo.id,
        versao: contratoInfo.versao,
        hash: hashContrato,
      });
      toast && toast("Aceite registrado! Bem-vindo(a).");
      onAceito && onAceito();
    } catch (e) {
      console.error(e);
      setErroEnvio("Não foi possível registrar seu aceite. Verifique sua conexão e tente novamente.");
      setEnviando(false);
    }
  };

  const corBorda = T?.line || "#DDE5E1";
  const corMuted = T?.muted || "#5C6E67";
  const corInk = T?.ink || "#10201A";
  const corForest = T?.forest || "#17604A";
  const corDanger = T?.danger || "#C24A3F";
  const corPaper = T?.paper || "#F1F4F2";

  return (
    <div style={{ minHeight: "100vh", background: corPaper, display: "flex", justifyContent: "center", padding: "24px 16px" }}>
      <div style={{ width: "100%", maxWidth: 640, background: "#fff", borderRadius: 16, padding: 24, boxShadow: "0 2px 16px rgba(0,0,0,0.06)" }}>
        <div style={{ display: "flex", alignItems: "center", gap: 8, marginBottom: 4 }}>
          <Lock size={20} color={corForest} />
          <h1 style={{ fontSize: 20, fontWeight: 800, color: corInk, margin: 0 }}>Antes de começar</h1>
        </div>
        <p style={{ fontSize: 13, color: corMuted, marginTop: 4 }}>
          Para liberar seu acesso, leia e aceite os termos abaixo.
        </p>

        {carregando && <SpinnerLocal label="Carregando termos..." />}

        {!carregando && erroCarga && (
          <div style={{ display: "flex", flexDirection: "column", alignItems: "center", gap: 10, padding: 24 }}>
            <AlertTriangle size={24} color={corDanger} />
            <div style={{ fontSize: 13, color: corInk, textAlign: "center" }}>{erroCarga}</div>
            <button onClick={() => setTentativa((t) => t + 1)} style={{ background: corForest, color: "#fff", border: "none", borderRadius: 10, padding: "10px 18px", fontSize: 13, fontWeight: 700 }}>
              Tentar novamente
            </button>
          </div>
        )}

        {!carregando && !erroCarga && (
          <>
            <div style={{ marginTop: 16 }}>
              <div style={{ fontSize: 12, fontWeight: 700, color: corMuted, textTransform: "uppercase", marginBottom: 6 }}>
                Termo de privacidade (LGPD)
              </div>
              <div style={{ border: `1px solid ${corBorda}`, borderRadius: 10, padding: 12, height: 140, overflowY: "auto", fontSize: 12, color: corInk, whiteSpace: "pre-wrap", lineHeight: 1.5 }}>
                {TEXTO_LGPD}
              </div>
              <label style={{ display: "flex", alignItems: "flex-start", gap: 8, marginTop: 8, fontSize: 13, color: corInk, cursor: "pointer" }}>
                <input type="checkbox" checked={lgpdChecked} onChange={(e) => setLgpdChecked(e.target.checked)} style={{ marginTop: 3 }} />
                Li e aceito o Termo de Privacidade
              </label>
            </div>

            <div style={{ marginTop: 20 }}>
              <div style={{ display: "flex", alignItems: "center", gap: 6, fontSize: 12, fontWeight: 700, color: corMuted, textTransform: "uppercase", marginBottom: 6 }}>
                <FileText size={14} /> Contrato de prestação de serviços
              </div>
              <div style={{ border: `1px solid ${corBorda}`, borderRadius: 10, padding: 12, height: 220, overflowY: "auto", fontSize: 12, color: corInk, whiteSpace: "pre-wrap", lineHeight: 1.5 }}>
                {contratoTexto}
              </div>
              <label style={{ display: "flex", alignItems: "flex-start", gap: 8, marginTop: 8, fontSize: 13, color: corInk, cursor: "pointer" }}>
                <input type="checkbox" checked={contratoChecked} onChange={(e) => setContratoChecked(e.target.checked)} style={{ marginTop: 3 }} />
                Li e aceito o Contrato de Prestação de Serviços
              </label>
            </div>

            {erroEnvio && (
              <div style={{ marginTop: 14, fontSize: 12, color: corDanger, textAlign: "center" }}>{erroEnvio}</div>
            )}

            <button
              onClick={aceitar}
              disabled={!podeAceitar}
              style={{
                width: "100%",
                marginTop: 16,
                padding: 14,
                borderRadius: 12,
                border: "none",
                background: podeAceitar ? corForest : corBorda,
                color: podeAceitar ? "#fff" : corMuted,
                fontSize: 14,
                fontWeight: 700,
                cursor: podeAceitar ? "pointer" : "not-allowed",
              }}
            >
              {enviando ? "Registrando aceite..." : "Aceitar e continuar"}
            </button>
          </>
        )}
      </div>
    </div>
  );
}
