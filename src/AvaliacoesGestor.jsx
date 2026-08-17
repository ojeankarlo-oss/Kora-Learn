import React, { useCallback, useEffect, useState } from "react";
import { AlertTriangle, BookOpen, ClipboardCheck, Loader2, RefreshCw } from "lucide-react";
import { listarCursosDoGestor, listarDisciplinasDoCurso, listarTurmasDoGestor } from "./lib/api";
import AvaliacoesProfessor from "./AvaliacoesProfessor";

export default function AvaliacoesGestor({ perfil, T, toast }) {
  const [cursos, setCursos] = useState([]);
  const [cursoId, setCursoId] = useState("");
  const [disciplinas, setDisciplinas] = useState([]);
  const [disciplinaId, setDisciplinaId] = useState("");
  const [turmas, setTurmas] = useState([]);
  const [turmaId, setTurmaId] = useState("");
  const [carregando, setCarregando] = useState(true);
  const [erro, setErro] = useState("");

  const carregarCursos = useCallback(async () => {
    try {
      setErro("");
      setCarregando(true);
      const lista = await listarCursosDoGestor();
      setCursos(lista);
      setCursoId((atual) => atual && lista.some((item) => item.id === atual) ? atual : lista[0]?.id || "");
    } catch (e) {
      console.error(e);
      setErro("Não foi possível carregar os cursos para as provas.");
    } finally {
      setCarregando(false);
    }
  }, []);

  useEffect(() => { carregarCursos(); }, [carregarCursos]);

  useEffect(() => {
    let ativo = true;
    async function carregarEstrutura() {
      if (!cursoId) { setDisciplinas([]); setTurmas([]); setDisciplinaId(""); setTurmaId(""); return; }
      try {
        setErro("");
        const [disciplinasLista, turmasLista] = await Promise.all([
          listarDisciplinasDoCurso(cursoId),
          listarTurmasDoGestor(cursoId),
        ]);
        if (!ativo) return;
        setDisciplinas(disciplinasLista);
        setTurmas(turmasLista);
        setDisciplinaId((atual) => atual && disciplinasLista.some((item) => item.id === atual) ? atual : disciplinasLista[0]?.id || "");
        setTurmaId((atual) => atual && turmasLista.some((item) => item.id === atual) ? atual : turmasLista[0]?.id || "");
      } catch (e) {
        console.error(e);
        if (ativo) setErro("Não foi possível carregar disciplinas e turmas do curso.");
      }
    }
    carregarEstrutura();
    return () => { ativo = false; };
  }, [cursoId]);

  const curso = cursos.find((item) => item.id === cursoId);
  const disciplina = disciplinas.find((item) => item.id === disciplinaId);
  const turma = turmas.find((item) => item.id === turmaId);
  const campo = { width: "100%", padding: "9px 10px", borderRadius: 9, border: `1px solid ${T?.line || "#DDE5E1"}`, background: T?.card || "#fff", color: T?.ink || "#10201A", fontSize: 13, boxSizing: "border-box" };

  if (carregando) return <div style={{ display: "flex", gap: 8, alignItems: "center", color: T?.muted || "#5C6E67", fontSize: 13, padding: 16 }}><Loader2 size={16} className="kl-spin" /> Carregando estrutura acadêmica...</div>;

  return (
    <div>
      <div style={{ display: "flex", alignItems: "center", gap: 8, marginTop: 24, marginBottom: 12 }}>
        <ClipboardCheck size={20} color={T?.forest || "#17604A"} />
        <div><div style={{ fontSize: 17, fontWeight: 800, color: T?.ink || "#10201A" }}>Provas</div><div style={{ fontSize: 12, color: T?.muted || "#5C6E67" }}>Crie provas, selecione questões e acompanhe correções.</div></div>
      </div>

      <div style={{ display: "grid", gridTemplateColumns: "repeat(3, 1fr)", gap: 10, padding: 14, borderRadius: 14, border: `1px solid ${T?.line || "#DDE5E1"}`, background: T?.card || "#fff", marginBottom: 14 }}>
        <label style={{ fontSize: 12, fontWeight: 700, color: T?.muted || "#5C6E67" }}>Curso<select value={cursoId} onChange={(e) => setCursoId(e.target.value)} style={{ ...campo, marginTop: 5 }}><option value="">Selecione</option>{cursos.map((item) => <option key={item.id} value={item.id}>{item.nome}</option>)}</select></label>
        <label style={{ fontSize: 12, fontWeight: 700, color: T?.muted || "#5C6E67" }}>Disciplina<select value={disciplinaId} onChange={(e) => setDisciplinaId(e.target.value)} style={{ ...campo, marginTop: 5 }} disabled={!cursoId}><option value="">Selecione</option>{disciplinas.map((item) => <option key={item.id} value={item.id}>{item.nome}</option>)}</select></label>
        <label style={{ fontSize: 12, fontWeight: 700, color: T?.muted || "#5C6E67" }}>Turma<select value={turmaId} onChange={(e) => setTurmaId(e.target.value)} style={{ ...campo, marginTop: 5 }} disabled={!cursoId}><option value="">Selecione</option>{turmas.map((item) => <option key={item.id} value={item.id}>{item.nome}</option>)}</select></label>
      </div>

      {erro && <div style={{ display: "flex", alignItems: "center", justifyContent: "space-between", gap: 8, padding: 12, borderRadius: 10, background: "#FCECEA", color: T?.danger || "#C24A3F", fontSize: 13, marginBottom: 14 }}><span style={{ display: "inline-flex", alignItems: "center", gap: 7 }}><AlertTriangle size={15} /> {erro}</span><button onClick={carregarCursos} style={{ display: "inline-flex", alignItems: "center", gap: 5, background: "none", border: "1px solid currentColor", color: "inherit", borderRadius: 999, padding: "5px 9px", fontSize: 11, fontWeight: 700 }}><RefreshCw size={12} /> Tentar</button></div>}
      {!cursoId ? <div style={{ padding: 24, textAlign: "center", borderRadius: 14, border: `1px solid ${T?.line || "#DDE5E1"}`, color: T?.muted || "#5C6E67", fontSize: 13 }}><BookOpen size={24} style={{ display: "block", margin: "0 auto 8px" }} />Cadastre um curso antes de montar uma prova.</div> : !disciplinaId || !turmaId ? <div style={{ padding: 24, textAlign: "center", borderRadius: 14, border: `1px solid ${T?.line || "#DDE5E1"}`, color: T?.muted || "#5C6E67", fontSize: 13 }}>Selecione curso, disciplina e turma para abrir o banco de questões.</div> : <AvaliacoesProfessor perfil={perfil} turma={{ turmaId: turma.id, turmaNome: turma.nome, cursoId: curso.id, cursoNome: curso.nome, disciplinaId: disciplina.id, disciplinaNome: disciplina.nome }} T={T} toast={toast} />}
    </div>
  );
}
