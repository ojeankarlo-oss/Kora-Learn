import React, { useCallback, useEffect, useState } from "react";
import {
  ClipboardList, RefreshCw, Loader2,
  CheckCircle2, XCircle, AlertCircle, CheckCheck,
} from "lucide-react";
import {
  minhasTurmasParaChamada, criarRegistroAula, alunosDaTurma,
  lancarPresencas, historicoAulasTurma,
} from "./lib/api";

const AMBIENTES_SUGERIDOS = ["Sala de aula", "Quadra", "Laboratório", "Online", "Externo"];

const SITUACOES = [
  { value: "presente", label: "Presente", Icon: CheckCircle2 },
  { value: "ausente", label: "Ausente", Icon: XCircle },
  { value: "justificada", label: "Justificada", Icon: AlertCircle },
];

function hojeISO() {
  return new Date().toISOString().slice(0, 10);
}

function formatarData(iso) {
  if (!iso) return "";
  const [ano, mes, dia] = String(iso).slice(0, 10).split("-");
  return `${dia}/${mes}/${ano}`;
}

function resumoPresencas(presencas) {
  const lista = presencas || [];
  const presentes = lista.filter((p) => p.situacao === "presente").length;
  const ausentes = lista.filter((p) => p.situacao === "ausente").length;
  const justificadas = lista.filter((p) => p.situacao === "justificada").length;
  const partes = [];
  if (presentes) partes.push(`${presentes} presente${presentes > 1 ? "s" : ""}`);
  if (ausentes) partes.push(`${ausentes} ausente${ausentes > 1 ? "s" : ""}`);
  if (justificadas) partes.push(`${justificadas} justificada${justificadas > 1 ? "s" : ""}`);
  return partes.length ? partes.join(", ") : "Sem registros de presença";
}

export default function Chamada({ perfil, toast, T }) {
  const [turmas, setTurmas] = useState(null);
  const [turmasErro, setTurmasErro] = useState("");
  const [turmaId, setTurmaId] = useState("");
  const [dataAula, setDataAula] = useState(hojeISO());
  const [tipo, setTipo] = useState("sincrona");
  const [ambiente, setAmbiente] = useState("");
  const [observacao, setObservacao] = useState("");
  const [iniciando, setIniciando] = useState(false);

  const [registroAtual, setRegistroAtual] = useState(null);
  const [alunos, setAlunos] = useState(null);
  const [alunosErro, setAlunosErro] = useState("");
  const [presencasPorAluno, setPresencasPorAluno] = useState({});
  const [salvando, setSalvando] = useState(false);

  const [historico, setHistorico] = useState(null);
  const [historicoErro, setHistoricoErro] = useState("");

  const corLine = T?.line || "#DDE5E1";
  const corMuted = T?.muted || "#5C6E67";
  const corInk = T?.ink || "#10201A";
  const corForest = T?.forest || "#17604A";
  const corDanger = T?.danger || "#C24A3F";
  const corSuccess = T?.success || "#2E8B63";
  const corAmber = T?.amber || "#E9A13B";

  const carregarTurmas = useCallback(async () => {
    try {
      setTurmasErro("");
      const data = await minhasTurmasParaChamada();
      setTurmas(data);
    } catch (e) {
      console.error(e);
      setTurmasErro("Não foi possível carregar as turmas.");
      setTurmas([]);
    }
  }, []);

  useEffect(() => { carregarTurmas(); }, [carregarTurmas]);

  const carregarHistorico = useCallback(async (id) => {
    if (!id) { setHistorico(null); return; }
    try {
      setHistoricoErro("");
      setHistorico(null);
      const data = await historicoAulasTurma(id);
      setHistorico(data);
    } catch (e) {
      console.error(e);
      setHistoricoErro("Não foi possível carregar o histórico de aulas.");
      setHistorico([]);
    }
  }, []);

  useEffect(() => { carregarHistorico(turmaId); }, [turmaId, carregarHistorico]);

  const turmaSelecionada = (turmas || []).find((t) => String(t.id) === String(turmaId));

  const iniciarChamada = async () => {
    if (!turmaId) { toast?.("Selecione uma turma."); return; }
    if (!dataAula) { toast?.("Selecione a data da aula."); return; }
    setIniciando(true);
    try {
      const registro = await criarRegistroAula({
        turmaId,
        disciplinaId: turmaSelecionada?.disciplinaId ?? null,
        dataAula,
        tipo,
        ambiente: ambiente.trim(),
        observacao: observacao.trim(),
      });
      setRegistroAtual(registro);
      setAlunosErro("");
      setAlunos(null);
      const lista = await alunosDaTurma(turmaId);
      setAlunos(lista);
      const inicial = {};
      lista.forEach((a) => { inicial[a.id] = "presente"; });
      setPresencasPorAluno(inicial);
    } catch (e) {
      console.error(e);
      toast?.("Erro ao iniciar a chamada. Verifique se a turma possui disciplina vinculada.");
      setAlunosErro("Não foi possível carregar os alunos da turma.");
    } finally {
      setIniciando(false);
    }
  };

  const marcarTodosPresentes = () => {
    const todos = {};
    (alunos || []).forEach((a) => { todos[a.id] = "presente"; });
    setPresencasPorAluno(todos);
  };

  const marcarSituacao = (alunoId, situacao) => {
    setPresencasPorAluno((prev) => ({ ...prev, [alunoId]: situacao }));
  };

  const salvarChamada = async () => {
    if (!registroAtual) return;
    setSalvando(true);
    try {
      const lista = (alunos || []).map((a) => ({
        usuario_id: a.id,
        situacao: presencasPorAluno[a.id] || "presente",
      }));
      await lancarPresencas(registroAtual.id, lista);
      toast?.("Chamada salva ✓");
      setRegistroAtual(null);
      setAlunos(null);
      setPresencasPorAluno({});
      setAmbiente("");
      setObservacao("");
      setDataAula(hojeISO());
      setTipo("sincrona");
      await carregarHistorico(turmaId);
    } catch (e) {
      console.error(e);
      toast?.("Erro ao salvar a chamada.");
    } finally {
      setSalvando(false);
    }
  };

  const box = { background: T?.card || "#fff", borderRadius: 14, border: `1px solid ${corLine}`, padding: 16, marginBottom: 16 };
  const rotulo = { fontSize: 12, fontWeight: 700, color: corMuted, marginBottom: 4, display: "block" };
  const campo = { width: "100%", padding: "8px 10px", borderRadius: 8, border: `1px solid ${corLine}`, fontSize: 13, boxSizing: "border-box" };

  return (
    <div style={{ marginTop: 16 }}>
      <div style={box}>
        <div style={{ fontSize: 15, fontWeight: 800, color: corInk, display: "flex", alignItems: "center", gap: 8, marginBottom: 12 }}>
          <ClipboardList size={18} color={corForest} /> Fazer chamada
        </div>

        {turmasErro ? (
          <div>
            <div style={{ color: corDanger, fontSize: 13, marginBottom: 8 }}>{turmasErro}</div>
            <button onClick={carregarTurmas} style={{ display: "inline-flex", alignItems: "center", gap: 6, border: `1px solid ${corLine}`, background: "none", borderRadius: 999, padding: "6px 14px", fontSize: 13, fontWeight: 700, cursor: "pointer", color: corInk }}>
              <RefreshCw size={14} /> Tentar de novo
            </button>
          </div>
        ) : turmas === null ? (
          <div style={{ display: "flex", alignItems: "center", gap: 8, color: corMuted, fontSize: 13 }}>
            <Loader2 size={16} className="kl-spin" /> Carregando turmas...
          </div>
        ) : turmas.length === 0 ? (
          <div style={{ color: corMuted, fontSize: 13 }}>Nenhuma turma disponível para lançar chamada.</div>
        ) : (
          <>
            <div style={{ display: "grid", gridTemplateColumns: "repeat(auto-fit, minmax(150px, 1fr))", gap: 10 }}>
              <div>
                <label style={rotulo}>Turma</label>
                <select style={campo} value={turmaId} onChange={(e) => { setTurmaId(e.target.value); setRegistroAtual(null); setAlunos(null); }} disabled={!!registroAtual}>
                  <option value="">Selecione...</option>
                  {turmas.map((t) => (
                    <option key={t.id} value={t.id}>{t.nome}</option>
                  ))}
                </select>
              </div>
              <div>
                <label style={rotulo}>Data da aula</label>
                <input type="date" style={campo} value={dataAula} onChange={(e) => setDataAula(e.target.value)} disabled={!!registroAtual} />
              </div>
              <div>
                <label style={rotulo}>Tipo</label>
                <div style={{ display: "flex", gap: 6 }}>
                  {[{ v: "sincrona", l: "Síncrona" }, { v: "assincrona", l: "Assíncrona" }].map((op) => (
                    <button key={op.v} type="button" onClick={() => setTipo(op.v)} disabled={!!registroAtual}
                      style={{ flex: 1, background: tipo === op.v ? corForest : "none", color: tipo === op.v ? "#fff" : corMuted, border: tipo === op.v ? "none" : `1px solid ${corLine}`, borderRadius: 8, padding: "8px 6px", fontSize: 12, fontWeight: 700, cursor: registroAtual ? "not-allowed" : "pointer" }}>
                      {op.l}
                    </button>
                  ))}
                </div>
              </div>
              <div style={{ gridColumn: "1 / -1" }}>
                <label style={rotulo}>Ambiente</label>
                <input
                  style={campo}
                  list="ambientes-sugeridos"
                  value={ambiente}
                  onChange={(e) => setAmbiente(e.target.value)}
                  placeholder="Sala de aula"
                  disabled={!!registroAtual}
                />
                <datalist id="ambientes-sugeridos">
                  {AMBIENTES_SUGERIDOS.map((a) => <option key={a} value={a} />)}
                </datalist>
              </div>
              <div style={{ gridColumn: "1 / -1" }}>
                <label style={rotulo}>Observação (opcional)</label>
                <input
                  style={campo}
                  value={observacao}
                  onChange={(e) => setObservacao(e.target.value)}
                  placeholder="Ex.: Aula de educação física na quadra"
                  disabled={!!registroAtual}
                />
              </div>
            </div>

            {!registroAtual && (
              <button onClick={iniciarChamada} disabled={iniciando}
                style={{ marginTop: 14, display: "inline-flex", alignItems: "center", gap: 6, background: corForest, color: "#fff", border: "none", borderRadius: 999, padding: "9px 18px", fontSize: 13, fontWeight: 700, cursor: iniciando ? "default" : "pointer", opacity: iniciando ? 0.7 : 1 }}>
                {iniciando ? <Loader2 size={14} className="kl-spin" /> : <ClipboardList size={14} />} Iniciar chamada
              </button>
            )}
          </>
        )}
      </div>

      {registroAtual && (
        <div style={box}>
          <div style={{ display: "flex", justifyContent: "space-between", alignItems: "center", flexWrap: "wrap", gap: 8, marginBottom: 12 }}>
            <div style={{ fontSize: 14, fontWeight: 800, color: corInk }}>
              Chamada de {formatarData(dataAula)} — {turmaSelecionada?.nome}
            </div>
            <button onClick={marcarTodosPresentes} type="button"
              style={{ display: "inline-flex", alignItems: "center", gap: 6, background: "none", border: `1px solid ${corLine}`, borderRadius: 999, padding: "6px 12px", fontSize: 12, fontWeight: 700, cursor: "pointer", color: corInk }}>
              <CheckCheck size={14} /> Marcar todos presentes
            </button>
          </div>

          {alunosErro ? (
            <div style={{ color: corDanger, fontSize: 13 }}>{alunosErro}</div>
          ) : alunos === null ? (
            <div style={{ display: "flex", alignItems: "center", gap: 8, color: corMuted, fontSize: 13 }}>
              <Loader2 size={16} className="kl-spin" /> Carregando alunos...
            </div>
          ) : alunos.length === 0 ? (
            <div style={{ color: corMuted, fontSize: 13 }}>Nenhum aluno matriculado ativo nesta turma.</div>
          ) : (
            <>
              <div style={{ display: "flex", flexDirection: "column", gap: 8 }}>
                {alunos.map((a) => {
                  const situacaoAtual = presencasPorAluno[a.id] || "presente";
                  return (
                    <div key={a.id} style={{ display: "flex", justifyContent: "space-between", alignItems: "center", gap: 8, padding: "8px 12px", border: `1px solid ${corLine}`, borderRadius: 10, flexWrap: "wrap" }}>
                      <div style={{ fontSize: 13, fontWeight: 600, color: corInk }}>{a.nome}</div>
                      <div style={{ display: "flex", gap: 6 }}>
                        {SITUACOES.map(({ value, label, Icon }) => {
                          const ativo = situacaoAtual === value;
                          const cor = value === "presente" ? corSuccess : value === "ausente" ? corDanger : corAmber;
                          return (
                            <button key={value} type="button" onClick={() => marcarSituacao(a.id, value)}
                              style={{ display: "flex", alignItems: "center", gap: 4, background: ativo ? cor : "none", color: ativo ? "#fff" : cor, border: `1px solid ${cor}`, borderRadius: 999, padding: "5px 10px", fontSize: 11, fontWeight: 700, cursor: "pointer" }}>
                              <Icon size={12} /> {label}
                            </button>
                          );
                        })}
                      </div>
                    </div>
                  );
                })}
              </div>

              <button onClick={salvarChamada} disabled={salvando}
                style={{ marginTop: 14, width: "100%", padding: "12px 14px", borderRadius: 12, border: "none", background: salvando ? corMuted : corForest, color: "#fff", fontWeight: 700, fontSize: 14, cursor: salvando ? "not-allowed" : "pointer" }}>
                {salvando ? "Salvando..." : "Salvar chamada"}
              </button>
            </>
          )}
        </div>
      )}

      <div style={box}>
        <div style={{ fontSize: 14, fontWeight: 800, color: corInk, marginBottom: 12 }}>Últimas aulas registradas</div>
        {!turmaId ? (
          <div style={{ color: corMuted, fontSize: 13 }}>Selecione uma turma para ver o histórico.</div>
        ) : historicoErro ? (
          <div>
            <div style={{ color: corDanger, fontSize: 13, marginBottom: 8 }}>{historicoErro}</div>
            <button onClick={() => carregarHistorico(turmaId)} style={{ display: "inline-flex", alignItems: "center", gap: 6, border: `1px solid ${corLine}`, background: "none", borderRadius: 999, padding: "6px 14px", fontSize: 13, fontWeight: 700, cursor: "pointer", color: corInk }}>
              <RefreshCw size={14} /> Tentar de novo
            </button>
          </div>
        ) : historico === null ? (
          <div style={{ display: "flex", alignItems: "center", gap: 8, color: corMuted, fontSize: 13 }}>
            <Loader2 size={16} className="kl-spin" /> Carregando histórico...
          </div>
        ) : historico.length === 0 ? (
          <div style={{ color: corMuted, fontSize: 13 }}>Nenhuma aula registrada ainda nesta turma.</div>
        ) : (
          <div style={{ display: "flex", flexDirection: "column", gap: 8 }}>
            {historico.map((r) => (
              <div key={r.id} style={{ padding: "10px 12px", border: `1px solid ${corLine}`, borderRadius: 10 }}>
                <div style={{ display: "flex", justifyContent: "space-between", flexWrap: "wrap", gap: 6 }}>
                  <div style={{ fontSize: 13, fontWeight: 700, color: corInk }}>
                    {formatarData(r.data_aula)} · {r.tipo === "sincrona" ? "Síncrona" : "Assíncrona"}{r.ambiente ? ` · ${r.ambiente}` : ""}
                  </div>
                </div>
                <div style={{ fontSize: 12, color: corMuted, marginTop: 2 }}>{resumoPresencas(r.presencas)}</div>
                {r.observacao && <div style={{ fontSize: 12, color: corMuted, marginTop: 2 }}>{r.observacao}</div>}
              </div>
            ))}
          </div>
        )}
      </div>
    </div>
  );
}
