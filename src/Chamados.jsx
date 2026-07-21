import React, { useCallback, useEffect, useState } from "react";
import { X, MessageSquare, Send, AlertTriangle, CheckCircle2, Loader2, RefreshCw, Inbox } from "lucide-react";
import { listarChamados, atualizarSituacaoChamado, mensagensDoChamado, enviarMensagemChamado } from "./lib/api";

const TIPO_LABELS = {
  documento: "Documento",
  material_pedagogico: "Material Pedagógico",
};
function labelTipo(tipo) {
  return TIPO_LABELS[tipo] || tipo;
}

const SITUACAO_LABELS = {
  aberto: "Aberto",
  em_andamento: "Em andamento",
  respondido: "Respondido",
  fechado: "Fechado",
};

function formatarPrazo(iso) {
  if (!iso) return "Sem prazo";
  const d = new Date(iso);
  const dd = String(d.getDate()).padStart(2, "0");
  const mm = String(d.getMonth() + 1).padStart(2, "0");
  const hh = String(d.getHours()).padStart(2, "0");
  const min = String(d.getMinutes()).padStart(2, "0");
  return `${dd}/${mm} ${hh}:${min}`;
}

// Verde: mais de 24h restantes · Âmbar: menos de 24h · Vermelho: prazo vencido e ainda não respondido/fechado.
function urgenciaChamado(chamado, T) {
  const finalizado = chamado.situacao === "respondido" || chamado.situacao === "fechado";
  if (finalizado) {
    return { label: SITUACAO_LABELS[chamado.situacao], bg: "#EAF6F0", fg: T.success };
  }
  if (!chamado.prazo_resposta) {
    return { label: "Sem prazo", bg: T.paper, fg: T.muted };
  }
  const horasRestantes = (new Date(chamado.prazo_resposta).getTime() - Date.now()) / 3600000;
  if (horasRestantes < 0) return { label: "Prazo vencido", bg: "#FCECEA", fg: T.danger };
  if (horasRestantes < 24) return { label: "Vence em breve", bg: "#FFF5E3", fg: T.amber };
  return { label: "No prazo", bg: "#EAF6F0", fg: T.success };
}

function ChamadoDetalhe({ chamado, T, toast, onClose, onAtualizado }) {
  const [mensagens, setMensagens] = useState(null);
  const [erroMensagens, setErroMensagens] = useState("");
  const [novaMensagem, setNovaMensagem] = useState("");
  const [enviando, setEnviando] = useState(false);
  const [mudandoSituacao, setMudandoSituacao] = useState(false);

  const carregarMensagens = useCallback(async () => {
    try {
      const data = await mensagensDoChamado(chamado.id);
      setMensagens(data);
      setErroMensagens("");
    } catch (e) {
      console.error(e);
      setErroMensagens("Não foi possível carregar as mensagens.");
      setMensagens([]);
    }
  }, [chamado.id]);

  useEffect(() => { carregarMensagens(); }, [carregarMensagens]);

  const enviar = async () => {
    if (!novaMensagem.trim()) return;
    setEnviando(true);
    try {
      await enviarMensagemChamado(chamado.id, novaMensagem.trim());
      setNovaMensagem("");
      await carregarMensagens();
    } catch (e) {
      console.error(e);
      toast && toast("Erro ao enviar mensagem");
    } finally {
      setEnviando(false);
    }
  };

  const mudarSituacao = async (novaSituacao) => {
    setMudandoSituacao(true);
    try {
      await atualizarSituacaoChamado(chamado.id, novaSituacao);
      toast && toast("Situação atualizada");
      onAtualizado(novaSituacao);
    } catch (e) {
      console.error(e);
      toast && toast("Erro ao atualizar a situação do chamado");
    } finally {
      setMudandoSituacao(false);
    }
  };

  const urgencia = urgenciaChamado(chamado, T);

  return (
    <div
      onClick={onClose}
      style={{ position: "fixed", inset: 0, background: "rgba(16,32,26,0.45)", display: "flex", alignItems: "center", justifyContent: "center", zIndex: 60, padding: 16 }}
    >
      <div
        onClick={(e) => e.stopPropagation()}
        style={{ width: "100%", maxWidth: 560, maxHeight: "85vh", overflowY: "auto", background: "#fff", borderRadius: 16, padding: 20 }}
      >
        <div style={{ display: "flex", justifyContent: "space-between", alignItems: "flex-start", gap: 8 }}>
          <div>
            <div style={{ fontSize: 11, fontWeight: 700, color: T.muted, textTransform: "uppercase" }}>{labelTipo(chamado.tipo)}</div>
            <h2 style={{ fontSize: 16, fontWeight: 800, color: T.ink, margin: "2px 0 0" }}>{chamado.assunto}</h2>
          </div>
          <button onClick={onClose} style={{ background: "none", border: "none", cursor: "pointer", padding: 4 }}>
            <X size={18} color={T.muted} />
          </button>
        </div>

        <div style={{ display: "flex", alignItems: "center", gap: 8, flexWrap: "wrap", marginTop: 10 }}>
          <span style={{ fontSize: 11, fontWeight: 700, padding: "4px 10px", borderRadius: 999, background: urgencia.bg, color: urgencia.fg }}>
            {urgencia.label}
          </span>
          <span style={{ fontSize: 12, color: T.muted }}>
            {chamado.solicitante?.nome} · {chamado.solicitante?.email}
          </span>
        </div>
        <div style={{ fontSize: 12, color: T.muted, marginTop: 4 }}>
          Prazo: {formatarPrazo(chamado.prazo_resposta)}
        </div>

        {chamado.detalhes && (
          <div style={{ marginTop: 12, padding: 12, background: T.paper, borderRadius: 10, fontSize: 13, color: T.ink }}>
            {chamado.detalhes}
          </div>
        )}

        <div style={{ display: "flex", gap: 8, flexWrap: "wrap", marginTop: 14 }}>
          {chamado.situacao === "aberto" && (
            <button onClick={() => mudarSituacao("em_andamento")} disabled={mudandoSituacao}
              style={{ background: "none", border: `1px solid ${T.line}`, color: T.ink, borderRadius: 10, padding: "8px 12px", fontSize: 12, fontWeight: 700 }}>
              Iniciar atendimento
            </button>
          )}
          {(chamado.situacao === "aberto" || chamado.situacao === "em_andamento") && (
            <button onClick={() => mudarSituacao("respondido")} disabled={mudandoSituacao}
              style={{ background: T.forest, color: "#fff", border: "none", borderRadius: 10, padding: "8px 12px", fontSize: 12, fontWeight: 700 }}>
              Marcar como respondido
            </button>
          )}
          {chamado.situacao === "respondido" && (
            <button onClick={() => mudarSituacao("fechado")} disabled={mudandoSituacao}
              style={{ background: T.forest, color: "#fff", border: "none", borderRadius: 10, padding: "8px 12px", fontSize: 12, fontWeight: 700 }}>
              Fechar chamado
            </button>
          )}
          {(chamado.situacao === "respondido" || chamado.situacao === "fechado") && (
            <button onClick={() => mudarSituacao("em_andamento")} disabled={mudandoSituacao}
              style={{ background: "none", border: `1px solid ${T.line}`, color: T.ink, borderRadius: 10, padding: "8px 12px", fontSize: 12, fontWeight: 700 }}>
              Reabrir
            </button>
          )}
        </div>

        <div style={{ marginTop: 18, paddingTop: 14, borderTop: `1px solid ${T.line}` }}>
          <div style={{ fontSize: 12, fontWeight: 700, color: T.muted, textTransform: "uppercase", marginBottom: 8, display: "flex", alignItems: "center", gap: 6 }}>
            <MessageSquare size={13} /> Conversa
          </div>

          {mensagens === null && (
            <div style={{ display: "flex", alignItems: "center", gap: 8, color: T.muted, fontSize: 13, padding: 12 }}>
              <Loader2 className="kl-spin" size={16} /> Carregando mensagens...
            </div>
          )}

          {mensagens !== null && erroMensagens && (
            <div style={{ fontSize: 13, color: T.danger, padding: 8 }}>{erroMensagens}</div>
          )}

          {mensagens !== null && !erroMensagens && mensagens.length === 0 && (
            <div style={{ fontSize: 13, color: T.muted, padding: 8 }}>Nenhuma mensagem ainda.</div>
          )}

          {mensagens !== null && mensagens.length > 0 && (
            <div style={{ display: "flex", flexDirection: "column", gap: 8 }}>
              {mensagens.map((m) => (
                <div key={m.id} style={{ background: T.paper, borderRadius: 10, padding: "8px 10px" }}>
                  <div style={{ fontSize: 11, fontWeight: 700, color: T.ink }}>{m.autor?.nome ?? "Usuário"}</div>
                  <div style={{ fontSize: 13, color: T.ink, marginTop: 2 }}>{m.mensagem}</div>
                  <div style={{ fontSize: 10, color: T.muted, marginTop: 2 }}>{formatarPrazo(m.created_at)}</div>
                </div>
              ))}
            </div>
          )}

          <div style={{ display: "flex", gap: 8, marginTop: 10 }}>
            <input
              value={novaMensagem}
              onChange={(e) => setNovaMensagem(e.target.value)}
              onKeyDown={(e) => { if (e.key === "Enter") enviar(); }}
              placeholder="Responder..."
              style={{ flex: 1, padding: "10px 12px", borderRadius: 10, border: `1px solid ${T.line}`, fontSize: 13, boxSizing: "border-box" }}
            />
            <button onClick={enviar} disabled={enviando || !novaMensagem.trim()}
              style={{ display: "flex", alignItems: "center", gap: 6, background: T.forest, color: "#fff", border: "none", borderRadius: 10, padding: "10px 14px", fontSize: 12, fontWeight: 700, opacity: enviando || !novaMensagem.trim() ? 0.6 : 1 }}>
              {enviando ? <Loader2 className="kl-spin" size={14} /> : <Send size={14} />}
            </button>
          </div>
        </div>
      </div>
    </div>
  );
}

export default function Chamados({ T, toast }) {
  const [chamados, setChamados] = useState(null);
  const [erro, setErro] = useState("");
  const [filtroTipo, setFiltroTipo] = useState("");
  const [filtroSituacao, setFiltroSituacao] = useState("");
  const [selecionado, setSelecionado] = useState(null);

  const carregar = useCallback(async () => {
    try {
      const data = await listarChamados({ tipo: filtroTipo || undefined, situacao: filtroSituacao || undefined });
      setChamados(data);
      setErro("");
    } catch (e) {
      console.error(e);
      setErro("Não foi possível carregar os chamados.");
      setChamados([]);
    }
  }, [filtroTipo, filtroSituacao]);

  useEffect(() => { carregar(); }, [carregar]);

  const fecharDetalhe = () => setSelecionado(null);

  const aoAtualizarSituacao = (novaSituacao) => {
    setSelecionado((prev) => prev && { ...prev, situacao: novaSituacao });
    carregar();
  };

  return (
    <>
      <div style={{ marginTop: 24, display: "flex", justifyContent: "space-between", alignItems: "center", flexWrap: "wrap", gap: 8 }}>
        <div style={{ fontSize: 11, fontWeight: 700, color: T.muted, textTransform: "uppercase", letterSpacing: "0.08em" }}>Central de Chamados</div>
        <button onClick={carregar} style={{ background: "none", border: "none", color: T.forest, fontSize: 12, fontWeight: 700, display: "flex", alignItems: "center", gap: 4 }}>
          <RefreshCw size={12} /> Atualizar
        </button>
      </div>

      <div style={{ display: "flex", gap: 8, flexWrap: "wrap", marginTop: 10 }}>
        <select value={filtroTipo} onChange={(e) => setFiltroTipo(e.target.value)}
          style={{ padding: "8px 12px", borderRadius: 10, border: `1px solid ${T.line}`, fontSize: 13 }}>
          <option value="">Todos os tipos</option>
          <option value="documento">Documento</option>
          <option value="material_pedagogico">Material Pedagógico</option>
        </select>
        <select value={filtroSituacao} onChange={(e) => setFiltroSituacao(e.target.value)}
          style={{ padding: "8px 12px", borderRadius: 10, border: `1px solid ${T.line}`, fontSize: 13 }}>
          <option value="">Todas as situações</option>
          <option value="aberto">Aberto</option>
          <option value="em_andamento">Em andamento</option>
          <option value="respondido">Respondido</option>
          <option value="fechado">Fechado</option>
        </select>
      </div>

      {chamados === null && (
        <div style={{ display: "flex", alignItems: "center", gap: 8, color: T.muted, fontSize: 13, padding: 20 }}>
          <Loader2 className="kl-spin" size={16} /> Carregando chamados...
        </div>
      )}

      {chamados !== null && erro && (
        <div style={{ marginTop: 8, padding: 24, textAlign: "center", background: "#fff", border: `1px solid ${T.line}`, borderRadius: 14 }}>
          <AlertTriangle size={26} color={T.danger} />
          <div style={{ fontSize: 13, color: T.muted, marginTop: 6 }}>{erro}</div>
          <button onClick={carregar} style={{ marginTop: 10, padding: "8px 16px", borderRadius: 10, border: "none", background: T.forest, color: "#fff", fontWeight: 600, fontSize: 13 }}>
            <RefreshCw size={13} style={{ verticalAlign: -2, marginRight: 6 }} />Tentar de novo
          </button>
        </div>
      )}

      {chamados !== null && !erro && chamados.length === 0 && (
        <div style={{ marginTop: 8, padding: 24, textAlign: "center", background: "#fff", border: `1px solid ${T.line}`, borderRadius: 14 }}>
          <Inbox size={26} color={T.muted} />
          <div style={{ fontSize: 13, color: T.muted, marginTop: 6 }}>Nenhum chamado encontrado com esses filtros.</div>
        </div>
      )}

      {chamados !== null && !erro && chamados.length > 0 && (
        <div style={{ marginTop: 8, background: "#fff", border: `1px solid ${T.line}`, borderRadius: 14, overflow: "hidden" }}>
          {chamados.map((c, i) => {
            const urgencia = urgenciaChamado(c, T);
            return (
              <div key={c.id} onClick={() => setSelecionado(c)}
                style={{ padding: "12px 14px", borderTop: i ? `1px solid ${T.line}` : "none", display: "flex", justifyContent: "space-between", alignItems: "center", gap: 8, flexWrap: "wrap", cursor: "pointer" }}>
                <div>
                  <div style={{ fontSize: 14, fontWeight: 700, color: T.ink }}>{c.assunto}</div>
                  <div style={{ fontSize: 12, color: T.muted }}>
                    {c.solicitante?.nome ?? "Solicitante"} · {labelTipo(c.tipo)} · Prazo {formatarPrazo(c.prazo_resposta)}
                  </div>
                </div>
                <span style={{ fontSize: 11, fontWeight: 700, padding: "4px 10px", borderRadius: 999, background: urgencia.bg, color: urgencia.fg }}>
                  {urgencia.label}
                </span>
              </div>
            );
          })}
        </div>
      )}

      {selecionado && (
        <ChamadoDetalhe
          chamado={selecionado}
          T={T}
          toast={toast}
          onClose={fecharDetalhe}
          onAtualizado={aoAtualizarSituacao}
        />
      )}
    </>
  );
}
