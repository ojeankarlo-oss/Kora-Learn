import React, { useCallback, useEffect, useState } from "react";
import { Award, CheckCircle2, Clock, FileQuestion, Loader2, RefreshCw, Send } from "lucide-react";
import {
  avaliacoesDisponiveisAluno,
  iniciarTentativaAvaliacao,
  enviarTentativaAvaliacao,
} from "./lib/api";

function situacaoInfo(avaliacao, T) {
  if (avaliacao.disponivel) return { label: "Disponível", bg: T?.success || "#2E8B63", color: "#fff", Icon: CheckCircle2 };
  if (avaliacao.motivo === "Tentativas esgotadas") return { label: "Concluída", bg: T?.line || "#DDE5E1", color: T?.muted || "#5C6E67", Icon: Award };
  return { label: avaliacao.motivo || "Aguardando", bg: T?.amberSoft || "#FBEFDA", color: T?.ink || "#10201A", Icon: Clock };
}

export default function AvaliacoesAluno({ T, toast }) {
  const [avaliacoes, setAvaliacoes] = useState(null);
  const [erro, setErro] = useState("");
  const [tentativa, setTentativa] = useState(null);
  const [respostas, setRespostas] = useState({});
  const [enviando, setEnviando] = useState(false);
  const [iniciandoId, setIniciandoId] = useState(null);
  const [resultado, setResultado] = useState(null);

  const carregar = useCallback(async () => {
    try {
      setErro("");
      setAvaliacoes(await avaliacoesDisponiveisAluno());
    } catch (e) {
      console.error(e);
      setErro("Não foi possível carregar suas avaliações.");
      setAvaliacoes([]);
    }
  }, []);

  useEffect(() => { carregar(); }, [carregar]);

  async function iniciar(avaliacao) {
    setIniciandoId(avaliacao.avaliacao_id);
    try {
      const data = await iniciarTentativaAvaliacao(avaliacao.avaliacao_id, avaliacao.matricula_id);
      setTentativa(data);
      setRespostas({});
      setResultado(null);
      toast?.("Tentativa iniciada. Boa prova!");
    } catch (e) {
      console.error(e);
      toast?.(e?.message || "Não foi possível iniciar a avaliação.");
    } finally {
      setIniciandoId(null);
    }
  }

  function alterarResposta(questaoId, valor) {
    setRespostas((atual) => ({ ...atual, [questaoId]: valor }));
  }

  async function enviar(e) {
    e.preventDefault();
    const questoes = tentativa?.questoes || [];
    const faltantes = questoes.filter((q) => {
      const resposta = respostas[q.questao_id];
      return !resposta || (q.tipo === "dissertativa" && !String(resposta.resposta_texto || "").trim());
    });
    if (faltantes.length > 0 && !window.confirm(`Ainda faltam ${faltantes.length} questão(ões). Enviar mesmo assim?`)) return;
    setEnviando(true);
    try {
      const payload = questoes.map((q) => ({ questao_id: q.questao_id, ...(respostas[q.questao_id] || {}) }));
      const data = await enviarTentativaAvaliacao(tentativa.id, payload);
      setResultado(data);
      setTentativa(null);
      setAvaliacoes(null);
      toast?.(data.pendentes_correcao ? "Prova enviada para correção do professor." : "Prova corrigida automaticamente.");
      await carregar();
    } catch (error) {
      console.error(error);
      toast?.(error?.message || "Não foi possível enviar a prova.");
    } finally {
      setEnviando(false);
    }
  }

  const box = { background: T?.card || "#fff", borderRadius: 14, border: `1px solid ${T?.line || "#DDE5E1"}`, padding: 16, marginBottom: 12 };
  const muted = T?.muted || "#5C6E67";
  const ink = T?.ink || "#10201A";
  const forest = T?.forest || "#17604A";
  const field = { width: "100%", padding: "9px 10px", borderRadius: 9, border: `1px solid ${T?.line || "#DDE5E1"}`, fontSize: 13, boxSizing: "border-box", fontFamily: "inherit" };

  if (tentativa) {
    return (
      <div style={{ padding: "16px 18px 90px", maxWidth: 640, margin: "0 auto" }}>
        <div style={{ display: "flex", justifyContent: "space-between", alignItems: "center", gap: 8, marginBottom: 14 }}>
          <div>
            <div style={{ fontSize: 11, color: muted, textTransform: "uppercase", fontWeight: 700, letterSpacing: "0.06em" }}>Tentativa {tentativa.numero_tentativa}</div>
            <h2 className="kl-display" style={{ margin: "3px 0 0", color: ink, fontSize: 21, fontWeight: 800 }}>Avaliação</h2>
          </div>
          <span style={{ fontSize: 12, color: muted }}>{tentativa.questoes?.length || 0} questões</span>
        </div>
        <form onSubmit={enviar}>
          {(tentativa.questoes || []).map((questao, index) => {
            const valor = respostas[questao.questao_id] || {};
            return (
              <div key={questao.questao_id} style={box}>
                <div style={{ display: "flex", justifyContent: "space-between", gap: 8, marginBottom: 8 }}>
                  <div style={{ fontSize: 13, fontWeight: 800, color: ink }}>Questão {index + 1}</div>
                  <span style={{ fontSize: 11, color: muted }}>{questao.pontos} {Number(questao.pontos) === 1 ? "ponto" : "pontos"}</span>
                </div>
                <div style={{ fontSize: 14, lineHeight: 1.5, color: ink, whiteSpace: "pre-wrap" }}>{questao.enunciado}</div>
                {questao.tipo === "objetiva" ? (
                  <div style={{ display: "flex", flexDirection: "column", gap: 8, marginTop: 12 }}>
                    {(questao.alternativas || []).map((alternativa) => (
                      <label key={alternativa.id} style={{ display: "flex", alignItems: "flex-start", gap: 8, padding: "9px 10px", border: `1px solid ${valor.alternativa_id === alternativa.id ? forest : T?.line || "#DDE5E1"}`, borderRadius: 9, cursor: "pointer", background: valor.alternativa_id === alternativa.id ? (T?.amberSoft || "#FBEFDA") : "transparent" }}>
                        <input type="radio" name={`questao-${questao.questao_id}`} checked={valor.alternativa_id === alternativa.id} onChange={() => alterarResposta(questao.questao_id, { alternativa_id: alternativa.id })} />
                        <span style={{ fontSize: 13, color: ink }}>{alternativa.texto}</span>
                      </label>
                    ))}
                  </div>
                ) : (
                  <textarea value={valor.resposta_texto || ""} onChange={(e) => alterarResposta(questao.questao_id, { resposta_texto: e.target.value })} rows={5} placeholder="Escreva sua resposta..." style={{ ...field, marginTop: 12, resize: "vertical" }} />
                )}
              </div>
            );
          })}
          <div style={{ ...box, display: "flex", justifyContent: "space-between", alignItems: "center", gap: 12, flexWrap: "wrap" }}>
            <div style={{ fontSize: 12, color: muted }}>Depois do envio, questões dissertativas ficam pendentes para o professor.</div>
            <button type="submit" disabled={enviando} style={{ display: "inline-flex", alignItems: "center", gap: 6, background: forest, color: "#fff", border: "none", borderRadius: 999, padding: "10px 16px", fontSize: 13, fontWeight: 700, cursor: enviando ? "not-allowed" : "pointer" }}>
              {enviando ? <Loader2 size={14} className="kl-spin" /> : <Send size={14} />} {enviando ? "Enviando..." : "Enviar prova"}
            </button>
          </div>
        </form>
      </div>
    );
  }

  return (
    <div style={{ padding: "16px 18px 90px", maxWidth: 640, margin: "0 auto" }}>
      <div style={{ display: "flex", alignItems: "center", gap: 8, marginBottom: 14 }}>
        <Award size={22} color={forest} />
        <h2 className="kl-display" style={{ margin: 0, color: ink, fontSize: 21, fontWeight: 800 }}>Avaliações e provas</h2>
      </div>
      {resultado && (
        <div style={{ ...box, background: resultado.pendentes_correcao ? (T?.amberSoft || "#FBEFDA") : (T?.success || "#2E8B63"), color: resultado.pendentes_correcao ? ink : "#fff" }}>
          <div style={{ fontSize: 14, fontWeight: 800 }}>{resultado.pendentes_correcao ? "Enviada para correção" : "Resultado disponível"}</div>
          <div style={{ fontSize: 13, marginTop: 4 }}>Percentual: {Number(resultado.percentual || 0).toLocaleString("pt-BR")}%</div>
        </div>
      )}
      {erro ? (
        <div style={box}>
          <div style={{ color: T?.danger || "#C24A3F", fontSize: 13, marginBottom: 10 }}>{erro}</div>
          <button onClick={carregar} style={{ display: "inline-flex", alignItems: "center", gap: 6, border: `1px solid ${T?.line}`, background: "none", borderRadius: 999, padding: "7px 14px", color: ink, fontWeight: 700 }}><RefreshCw size={13} /> Tentar novamente</button>
        </div>
      ) : avaliacoes === null ? (
        <div style={{ ...box, display: "flex", alignItems: "center", gap: 8, color: muted }}><Loader2 size={16} className="kl-spin" /> Carregando avaliações...</div>
      ) : avaliacoes.length === 0 ? (
        <div style={{ ...box, textAlign: "center", color: muted }}><FileQuestion size={26} /><div style={{ marginTop: 8, fontSize: 13 }}>Nenhuma avaliação cadastrada para suas matrículas.</div></div>
      ) : (
        <div>
          {avaliacoes.map((avaliacao) => {
            const info = situacaoInfo(avaliacao, T);
            const Icon = info.Icon;
            return (
              <div key={`${avaliacao.avaliacao_id}-${avaliacao.matricula_id}`} style={box}>
                <div style={{ display: "flex", justifyContent: "space-between", alignItems: "flex-start", gap: 10 }}>
                  <div style={{ flex: 1 }}>
                    <div style={{ fontSize: 15, fontWeight: 800, color: ink }}>{avaliacao.titulo}</div>
                    <div style={{ fontSize: 12, color: muted, marginTop: 3 }}>{avaliacao.disciplina_nome} · {avaliacao.modo_aplicacao === "ead" ? "EAD" : "Presencial"}</div>
                    {avaliacao.descricao && <div style={{ fontSize: 13, color: muted, marginTop: 8 }}>{avaliacao.descricao}</div>}
                  </div>
                  <span style={{ display: "inline-flex", alignItems: "center", gap: 4, background: info.bg, color: info.color, borderRadius: 999, padding: "4px 9px", fontSize: 11, fontWeight: 700, whiteSpace: "nowrap" }}><Icon size={12} /> {info.label}</span>
                </div>
                <div style={{ display: "flex", justifyContent: "space-between", alignItems: "center", gap: 8, marginTop: 12, fontSize: 12, color: muted }}>
                  <span>{avaliacao.tentativas_usadas}/{avaliacao.tentativas_permitidas} tentativa(s) · nota mínima {avaliacao.nota_minima}%</span>
                  {avaliacao.disponivel && <button onClick={() => iniciar(avaliacao)} disabled={iniciandoId === avaliacao.avaliacao_id} style={{ display: "inline-flex", alignItems: "center", gap: 6, background: forest, color: "#fff", border: "none", borderRadius: 999, padding: "8px 13px", fontSize: 12, fontWeight: 700 }}>{iniciandoId === avaliacao.avaliacao_id ? <Loader2 size={13} className="kl-spin" /> : <FileQuestion size={13} />} Iniciar</button>}
                </div>
              </div>
            );
          })}
        </div>
      )}
    </div>
  );
}
