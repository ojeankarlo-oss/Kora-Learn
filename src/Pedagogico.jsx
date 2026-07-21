import React, { useCallback, useEffect, useState } from "react";
import { BookOpen, Send, Loader2, Inbox, AlertTriangle, RefreshCw } from "lucide-react";
import { criarChamado, meusChamados } from "./lib/api";

const SITUACAO_INFO = {
  aberto: { label: "Aberto", bg: "#FFF5E3" },
  em_andamento: { label: "Em andamento", bg: "#FFF5E3" },
  respondido: { label: "Respondido", bg: "#EAF6F0" },
  fechado: { label: "Fechado", bg: "#EAF6F0" },
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

// Fallback acessível ao gestor enquanto não existe login de professor: o gestor
// solicita material pedagógico à coordenação usando o mesmo motor de chamados.
export default function Pedagogico({ T, toast }) {
  const [assunto, setAssunto] = useState("");
  const [detalhes, setDetalhes] = useState("");
  const [enviando, setEnviando] = useState(false);
  const [solicitacoes, setSolicitacoes] = useState(null);
  const [erro, setErro] = useState("");

  const carregar = useCallback(async () => {
    try {
      const data = await meusChamados();
      setSolicitacoes(data.filter((c) => c.tipo === "material_pedagogico"));
      setErro("");
    } catch (e) {
      console.error(e);
      setErro("Não foi possível carregar suas solicitações.");
      setSolicitacoes([]);
    }
  }, []);

  useEffect(() => { carregar(); }, [carregar]);

  const enviar = async (e) => {
    e.preventDefault();
    if (!assunto.trim()) { toast && toast("Informe o assunto da solicitação"); return; }
    setEnviando(true);
    try {
      await criarChamado({ tipo: "material_pedagogico", assunto: assunto.trim(), detalhes: detalhes.trim() });
      toast && toast("Solicitação enviada ✓");
      setAssunto(""); setDetalhes("");
      await carregar();
    } catch (e2) {
      console.error(e2);
      toast && toast("Erro ao enviar solicitação");
    } finally {
      setEnviando(false);
    }
  };

  return (
    <>
      <div style={{ marginTop: 24, fontSize: 11, fontWeight: 700, color: T.muted, textTransform: "uppercase", letterSpacing: "0.08em" }}>
        Solicitar material pedagógico
      </div>
      <p style={{ fontSize: 13, color: T.muted, marginTop: 4 }}>
        Peça material pedagógico à coordenação. (Fallback usado enquanto não há login de professor.)
      </p>

      <form onSubmit={enviar} style={{ marginTop: 8, background: "#fff", border: `1px solid ${T.line}`, borderRadius: 14, padding: 16 }}>
        <label style={{ display: "block", fontSize: 12, fontWeight: 600, color: T.muted, marginBottom: 4 }}>Assunto *</label>
        <input
          value={assunto}
          onChange={(e) => setAssunto(e.target.value)}
          placeholder="Ex.: Material sobre frações para o 6º ano"
          style={{ width: "100%", padding: "10px 12px", borderRadius: 10, border: `1px solid ${T.line}`, fontSize: 13, boxSizing: "border-box", marginBottom: 12 }}
        />
        <label style={{ display: "block", fontSize: 12, fontWeight: 600, color: T.muted, marginBottom: 4 }}>Detalhes</label>
        <textarea
          value={detalhes}
          onChange={(e) => setDetalhes(e.target.value)}
          placeholder="Descreva o que você precisa"
          style={{ width: "100%", padding: "10px 12px", borderRadius: 10, border: `1px solid ${T.line}`, fontSize: 13, boxSizing: "border-box", minHeight: 70, fontFamily: "inherit" }}
        />
        <button type="submit" disabled={enviando}
          style={{ display: "flex", alignItems: "center", gap: 6, marginTop: 12, background: T.forest, color: "#fff", border: "none", borderRadius: 10, padding: "10px 16px", fontSize: 13, fontWeight: 700, opacity: enviando ? 0.7 : 1 }}>
          {enviando ? <Loader2 className="kl-spin" size={16} /> : <Send size={16} />}
          {enviando ? "Enviando..." : "Enviar solicitação"}
        </button>
      </form>

      <div style={{ marginTop: 20, fontSize: 11, fontWeight: 700, color: T.muted, textTransform: "uppercase", letterSpacing: "0.08em" }}>
        Minhas solicitações
      </div>

      {solicitacoes === null && (
        <div style={{ display: "flex", alignItems: "center", gap: 8, color: T.muted, fontSize: 13, padding: 12 }}>
          <Loader2 className="kl-spin" size={16} /> Carregando...
        </div>
      )}

      {solicitacoes !== null && erro && (
        <div style={{ marginTop: 8, padding: 24, textAlign: "center", background: "#fff", border: `1px solid ${T.line}`, borderRadius: 14 }}>
          <AlertTriangle size={26} color={T.danger} />
          <div style={{ fontSize: 13, color: T.muted, marginTop: 6 }}>{erro}</div>
          <button onClick={carregar} style={{ marginTop: 10, padding: "8px 16px", borderRadius: 10, border: "none", background: T.forest, color: "#fff", fontWeight: 600, fontSize: 13 }}>
            <RefreshCw size={13} style={{ verticalAlign: -2, marginRight: 6 }} />Tentar de novo
          </button>
        </div>
      )}

      {solicitacoes !== null && !erro && solicitacoes.length === 0 && (
        <div style={{ marginTop: 8, padding: 24, textAlign: "center", background: "#fff", border: `1px solid ${T.line}`, borderRadius: 14 }}>
          <BookOpen size={26} color={T.muted} />
          <div style={{ fontSize: 13, color: T.muted, marginTop: 6 }}>Nenhuma solicitação enviada ainda.</div>
        </div>
      )}

      {solicitacoes !== null && solicitacoes.length > 0 && (
        <div style={{ marginTop: 8, background: "#fff", border: `1px solid ${T.line}`, borderRadius: 14, overflow: "hidden" }}>
          {solicitacoes.map((s, i) => {
            const info = SITUACAO_INFO[s.situacao] || { label: s.situacao, bg: T.paper };
            return (
              <div key={s.id} style={{ padding: "12px 14px", borderTop: i ? `1px solid ${T.line}` : "none", display: "flex", justifyContent: "space-between", alignItems: "center", gap: 8, flexWrap: "wrap" }}>
                <div>
                  <div style={{ fontSize: 13, fontWeight: 700, color: T.ink }}>{s.assunto}</div>
                  <div style={{ fontSize: 11, color: T.muted }}>Prazo estimado: {formatarPrazo(s.prazo_resposta)}</div>
                </div>
                <span style={{ fontSize: 11, fontWeight: 700, padding: "4px 10px", borderRadius: 999, background: info.bg, color: T.ink }}>
                  {info.label}
                </span>
              </div>
            );
          })}
        </div>
      )}
    </>
  );
}
