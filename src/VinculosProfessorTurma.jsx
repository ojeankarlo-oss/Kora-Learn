import React, { useCallback, useEffect, useState } from "react";
import { Link2, Trash2, RefreshCw, AlertTriangle, Loader2, UserCog } from "lucide-react";
import {
  listarVinculosProfessorTurma, listarProfessores, listarTurmasAtivas,
  vincularProfessorTurma, desvincularProfessorTurma,
} from "./lib/api";

// O cadastro de professor agora acontece sempre pelo RH (ficha do colaborador
// -> "Dar acesso de professor" / "Vincular às turmas"), que chega aqui com
// professorPreSelecionado ja preenchido. Esta tela passa a servir so para
// GERENCIAR vinculos ja criados (vincular a mais turmas, listar, desvincular).
export default function VinculosProfessorTurma({ T, toast, perfil, professorPreSelecionado }) {
  const [vinculos, setVinculos] = useState(null);
  const [erro, setErro] = useState("");
  const [professores, setProfessores] = useState([]);
  const [turmas, setTurmas] = useState([]);
  const [professorId, setProfessorId] = useState("");
  const [turmaId, setTurmaId] = useState("");
  const [vinculando, setVinculando] = useState(false);
  const [removendoId, setRemovendoId] = useState(null);
  const [meVinculando, setMeVinculando] = useState(false);

  const corLine = T?.line || "#DDE5E1";
  const corMuted = T?.muted || "#5C6E67";
  const corInk = T?.ink || "#10201A";
  const corForest = T?.forest || "#17604A";
  const corDanger = T?.danger || "#C24A3F";

  const carregar = useCallback(async () => {
    try {
      setErro("");
      const data = await listarVinculosProfessorTurma();
      setVinculos(data);
    } catch (e) {
      console.error(e);
      setErro("Não foi possível carregar os vínculos.");
      setVinculos([]);
    }
  }, []);

  const carregarListas = useCallback(async () => {
    try {
      const [profs, tms] = await Promise.all([listarProfessores(), listarTurmasAtivas()]);
      setProfessores(profs);
      setTurmas(tms);
    } catch (e) {
      console.error(e);
      setProfessores([]);
      setTurmas([]);
    }
  }, []);

  useEffect(() => { carregar(); }, [carregar]);
  useEffect(() => { carregarListas(); }, [carregarListas]);

  // Pre-seleciona o professor vindo do RH (botão "Vincular às turmas").
  useEffect(() => {
    if (professorPreSelecionado?.usuario_id) {
      setProfessorId(professorPreSelecionado.usuario_id);
    }
  }, [professorPreSelecionado]);

  const vincular = async () => {
    if (!professorId || !turmaId) { toast?.("Selecione o professor e a turma."); return; }
    setVinculando(true);
    try {
      await vincularProfessorTurma(professorId, turmaId);
      toast?.("Vínculo criado ✓");
      setProfessorId(""); setTurmaId("");
      await carregar();
    } catch (e) {
      console.error(e);
      toast?.("Erro ao criar vínculo");
    } finally {
      setVinculando(false);
    }
  };

  const remover = async (vinculo) => {
    if (!window.confirm(`Remover o vínculo de ${vinculo.professor?.nome ?? "professor"} com ${vinculo.turma?.nome ?? "turma"}?`)) return;
    setRemovendoId(vinculo.id);
    try {
      await desvincularProfessorTurma(vinculo.id);
      toast?.("Vínculo removido");
      await carregar();
    } catch (e) {
      console.error(e);
      toast?.("Erro ao remover vínculo");
    } finally {
      setRemovendoId(null);
    }
  };

  // Atalho de teste: o gestor logado se vincula como professor da turma selecionada,
  // para poder acessar as telas de professor (Materiais/Agenda/Chamada) sem depender
  // de um cadastro de professor separado.
  const meVincular = async () => {
    if (!turmaId) { toast?.("Selecione uma turma."); return; }
    if (!perfil?.id) return;
    setMeVinculando(true);
    try {
      await vincularProfessorTurma(perfil.id, turmaId);
      toast?.("Você agora está vinculado como professor dessa turma ✓");
      await carregar();
    } catch (e) {
      console.error(e);
      toast?.("Erro ao vincular você como professor da turma");
    } finally {
      setMeVinculando(false);
    }
  };

  const box = { background: T?.card || "#fff", borderRadius: 14, border: `1px solid ${corLine}`, padding: 16, marginTop: 16 };
  const rotulo = { display: "block", fontSize: 12, fontWeight: 700, color: corMuted, marginBottom: 4 };
  const campo = { width: "100%", padding: "8px 10px", borderRadius: 8, border: `1px solid ${corLine}`, fontSize: 13, boxSizing: "border-box" };

  return (
    <div style={box}>
      <div style={{ fontSize: 15, fontWeight: 800, color: corInk, display: "flex", alignItems: "center", gap: 8, marginBottom: 12 }}>
        <Link2 size={18} color={corForest} /> Vínculo professor ↔ turma
      </div>

      {professores.length === 0 && (
        <div style={{ marginBottom: 12, padding: 10, borderRadius: 10, background: "#FFF5E3", color: T?.amber || "#E9A13B", fontSize: 13 }}>
          Nenhum usuário com perfil "professor" cadastrado ainda. Vá até a aba <strong>RH</strong>, abra a ficha do colaborador e use o botão "Dar acesso de professor" (ou vincule-se você mesmo abaixo, para testes).
        </div>
      )}

      {professorPreSelecionado?.usuario_id && (
        <div style={{ marginBottom: 12, padding: 10, borderRadius: 10, background: "#EAF6F0", color: corForest, fontSize: 13, fontWeight: 600 }}>
          Professor pré-selecionado: {professorPreSelecionado.nome}. Escolha a turma abaixo e clique em Vincular.
        </div>
      )}

      <div style={{ display: "grid", gridTemplateColumns: "1fr 1fr auto", gap: 10, alignItems: "end" }}>
        <div>
          <label style={rotulo}>Professor</label>
          <select style={campo} value={professorId} onChange={(e) => setProfessorId(e.target.value)} disabled={professores.length === 0}>
            <option value="">Selecione...</option>
            {professores.map((p) => (
              <option key={p.id} value={p.id}>{p.nome}</option>
            ))}
          </select>
        </div>
        <div>
          <label style={rotulo}>Turma</label>
          <select style={campo} value={turmaId} onChange={(e) => setTurmaId(e.target.value)} disabled={turmas.length === 0}>
            <option value="">Selecione...</option>
            {turmas.map((t) => (
              <option key={t.id} value={t.id}>{t.nome}</option>
            ))}
          </select>
        </div>
        <button onClick={vincular} disabled={vinculando || professores.length === 0 || turmas.length === 0}
          style={{ background: corForest, color: "#fff", border: "none", borderRadius: 10, padding: "8px 16px", fontSize: 13, fontWeight: 700, cursor: vinculando ? "not-allowed" : "pointer" }}>
          {vinculando ? "Vinculando..." : "Vincular"}
        </button>
      </div>

      {perfil?.id && (
        <div style={{ marginTop: 10 }}>
          <button onClick={meVincular} disabled={meVinculando || !turmaId}
            style={{ display: "flex", alignItems: "center", gap: 6, background: "none", border: `1px solid ${corLine}`, color: corInk, borderRadius: 999, padding: "6px 14px", fontSize: 12, fontWeight: 700, cursor: (meVinculando || !turmaId) ? "not-allowed" : "pointer" }}>
            <UserCog size={13} /> {meVinculando ? "Vinculando..." : "Me vincular como professor desta turma"}
          </button>
          <div style={{ fontSize: 11, color: corMuted, marginTop: 4 }}>
            Selecione a turma acima e use este botão para testar rapidamente as telas de professor com sua própria conta de gestor.
          </div>
        </div>
      )}

      <div style={{ marginTop: 16 }}>
        {erro ? (
          <div>
            <div style={{ color: corDanger, fontSize: 13, marginBottom: 8 }}>{erro}</div>
            <button onClick={carregar} style={{ display: "inline-flex", alignItems: "center", gap: 6, border: `1px solid ${corLine}`, background: "none", borderRadius: 999, padding: "6px 14px", fontSize: 13, fontWeight: 700, cursor: "pointer", color: corInk }}>
              <RefreshCw size={14} /> Tentar de novo
            </button>
          </div>
        ) : vinculos === null ? (
          <div style={{ display: "flex", alignItems: "center", gap: 8, color: corMuted, fontSize: 13 }}>
            <Loader2 size={16} className="kl-spin" /> Carregando vínculos...
          </div>
        ) : vinculos.length === 0 ? (
          <div style={{ color: corMuted, fontSize: 13 }}>Nenhum vínculo cadastrado ainda.</div>
        ) : (
          <div style={{ display: "flex", flexDirection: "column", gap: 8 }}>
            {vinculos.map((v) => (
              <div key={v.id} style={{ display: "flex", justifyContent: "space-between", alignItems: "center", gap: 8, padding: "8px 12px", border: `1px solid ${corLine}`, borderRadius: 10, flexWrap: "wrap" }}>
                <div style={{ fontSize: 13, color: corInk }}>
                  <strong>{v.professor?.nome ?? "Professor"}</strong> → {v.turma?.nome ?? "Turma"}
                </div>
                <button onClick={() => remover(v)} disabled={removendoId === v.id}
                  style={{ display: "flex", alignItems: "center", gap: 4, background: "none", border: `1px solid ${corDanger}`, color: corDanger, borderRadius: 10, padding: "5px 10px", fontSize: 12, fontWeight: 700, cursor: removendoId === v.id ? "not-allowed" : "pointer" }}>
                  <Trash2 size={13} /> Remover
                </button>
              </div>
            ))}
          </div>
        )}
      </div>
    </div>
  );
}
