import React, { useCallback, useEffect, useState } from "react";
import { AlertTriangle, CheckCircle2, Clock3, FileText, RefreshCw, Wallet, Users, Inbox, ArrowRight } from "lucide-react";
import { prioridadesDoDia } from "./lib/api";

const ICONES = {
  chamados: Inbox,
  financeiro: Wallet,
  frequencia: Users,
  documentos: FileText,
};

export default function PainelPrioridades({ T, unidadeId, onNavigate }) {
  const [itens, setItens] = useState(null);
  const [erro, setErro] = useState("");

  const carregar = useCallback(async () => {
    try {
      setErro("");
      setItens(await prioridadesDoDia(unidadeId));
    } catch (e) {
      console.error(e);
      setErro("Não foi possível carregar as prioridades agora.");
      setItens([]);
    }
  }, [unidadeId]);

  useEffect(() => { carregar(); }, [carregar]);

  const box = { background: T?.card || "#fff", borderRadius: 14, border: `1px solid ${T?.line || "#DDE5E1"}`, padding: 16, marginTop: 16 };
  const ink = T?.ink || "#10201A";
  const muted = T?.muted || "#5C6E67";
  const forest = T?.forest || "#17604A";
  const danger = T?.danger || "#C24A3F";
  const amber = T?.amber || "#E9A13B";

  const total = (itens || []).reduce((acc, item) => acc + Number(item.quantidade || 0), 0);
  const criticos = (itens || []).reduce((acc, item) => acc + Number(item.quantidade_critica || 0), 0);

  return (
    <section aria-labelledby="prioridades-do-dia" style={box}>
      <div style={{ display: "flex", justifyContent: "space-between", alignItems: "flex-start", gap: 12, flexWrap: "wrap" }}>
        <div>
          <div style={{ display: "flex", alignItems: "center", gap: 8 }}>
            <Clock3 size={18} color={forest} />
            <h2 id="prioridades-do-dia" className="kl-display" style={{ margin: 0, color: ink, fontSize: 17, fontWeight: 800 }}>Prioridades do dia</h2>
          </div>
          <div style={{ color: muted, fontSize: 12, marginTop: 4 }}>Um resumo dos pontos que pedem atenção nos módulos.</div>
        </div>
        <button onClick={carregar} aria-label="Atualizar prioridades" style={{ display: "inline-flex", alignItems: "center", gap: 5, border: `1px solid ${T?.line || "#DDE5E1"}`, background: "none", borderRadius: 999, padding: "6px 10px", color: muted, fontSize: 11, fontWeight: 700, cursor: "pointer" }}><RefreshCw size={12} /> Atualizar</button>
      </div>

      {itens === null ? (
        <div style={{ display: "flex", alignItems: "center", gap: 8, color: muted, fontSize: 13, marginTop: 14 }}><RefreshCw size={14} className="kl-spin" /> Consolidando dados...</div>
      ) : erro ? (
        <div style={{ color: danger, fontSize: 13, marginTop: 14 }}>{erro}</div>
      ) : total === 0 ? (
        <div style={{ display: "flex", alignItems: "center", gap: 8, marginTop: 14, padding: "10px 12px", borderRadius: 10, background: T?.successSoft || "#EAF6F0", color: T?.forestDark || "#0E4536", fontSize: 13, fontWeight: 700 }}><CheckCircle2 size={16} /> Nenhuma prioridade pendente no momento.</div>
      ) : (
        <div style={{ display: "grid", gridTemplateColumns: "repeat(auto-fit, minmax(190px, 1fr))", gap: 8, marginTop: 14 }}>
          {(itens || []).map((item) => {
            const Icon = ICONES[item.categoria] || AlertTriangle;
            const critica = Number(item.quantidade_critica || 0) > 0;
            return (
              <button key={item.categoria} onClick={() => onNavigate?.(item.rota)} style={{ textAlign: "left", border: `1px solid ${critica ? `${danger}66` : T?.line || "#DDE5E1"}`, background: critica ? `${danger}0D` : "transparent", borderRadius: 11, padding: 11, cursor: onNavigate ? "pointer" : "default" }}>
                <div style={{ display: "flex", justifyContent: "space-between", alignItems: "center", gap: 8 }}>
                  <Icon size={16} color={critica ? danger : forest} />
                  <span style={{ minWidth: 24, textAlign: "center", borderRadius: 999, padding: "3px 7px", background: critica ? danger : amber, color: critica ? "#fff" : ink, fontSize: 12, fontWeight: 800 }}>{item.quantidade}</span>
                </div>
                <div style={{ color: ink, fontSize: 12, fontWeight: 800, marginTop: 8 }}>{item.titulo}</div>
                <div style={{ color: muted, fontSize: 11, marginTop: 3, lineHeight: 1.35 }}>{item.descricao}</div>
                {onNavigate && <div style={{ display: "inline-flex", alignItems: "center", gap: 4, color: forest, fontSize: 10, fontWeight: 700, marginTop: 8 }}>Abrir módulo <ArrowRight size={11} /></div>}
              </button>
            );
          })}
        </div>
      )}
      {itens !== null && !erro && total > 0 && <div style={{ color: muted, fontSize: 11, marginTop: 10 }}>{total} item(ns) no total{criticos > 0 ? ` · ${criticos} crítico(s)` : ""}.</div>}
    </section>
  );
}
