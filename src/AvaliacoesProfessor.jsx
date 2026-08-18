import React, { useCallback, useEffect, useMemo, useState } from "react";
import { Award, CheckCircle2, ClipboardList, FileQuestion, Loader2, Plus, RefreshCw, Save, Trash2 } from "lucide-react";
import {
  listarQuestoesDisciplina,
  criarQuestao,
  listarAvaliacoesDisciplina,
  criarAvaliacao,
  vincularQuestoesAvaliacao,
  atualizarSituacaoAvaliacao,
  tentativasAvaliacao,
  corrigirRespostaAvaliacao,
} from "./lib/api";

const ALTERNATIVA_IDS = ["a", "b"];

function alternativasIniciais() {
  return ALTERNATIVA_IDS.map((id) => ({ id, texto: "" }));
}

function rotuloAlternativa(index) {
  return String.fromCharCode(65 + index);
}

export default function AvaliacoesProfessor({ perfil, turma, T, toast }) {
  const [aba, setAba] = useState("banco");
  const [questoes, setQuestoes] = useState([]);
  const [avaliacoes, setAvaliacoes] = useState([]);
  const [carregando, setCarregando] = useState(true);
  const [erro, setErro] = useState("");
  const [salvando, setSalvando] = useState(false);
  const [avaliacaoSelecionada, setAvaliacaoSelecionada] = useState(null);
  const [tentativas, setTentativas] = useState([]);
  const [tentativasCarregando, setTentativasCarregando] = useState(false);
  const [correcaoValores, setCorrecaoValores] = useState({});

  const [questaoEnunciado, setQuestaoEnunciado] = useState("");
  const [questaoTipo, setQuestaoTipo] = useState("objetiva");
  const [questaoDificuldade, setQuestaoDificuldade] = useState("medio");
  const [questaoPontos, setQuestaoPontos] = useState(1);
  const [alternativas, setAlternativas] = useState(alternativasIniciais);
  const [respostaCorreta, setRespostaCorreta] = useState("a");
  const [respostaEsperada, setRespostaEsperada] = useState("");

  const [provaTitulo, setProvaTitulo] = useState("");
  const [provaDescricao, setProvaDescricao] = useState("");
  const [provaModo, setProvaModo] = useState("presencial");
  const [provaRegra, setProvaRegra] = useState("manual");
  const [provaIntervalo, setProvaIntervalo] = useState(60);
  const [provaTentativas, setProvaTentativas] = useState(1);
  const [provaNotaMinima, setProvaNotaMinima] = useState(60);
  const [provaExpira, setProvaExpira] = useState(2);
  const [provaQuantidade, setProvaQuantidade] = useState("");
  const [questoesEscolhidas, setQuestoesEscolhidas] = useState([]);

  const cor = {
    line: T?.line || "#DDE5E1",
    muted: T?.muted || "#5C6E67",
    ink: T?.ink || "#10201A",
    forest: T?.forest || "#17604A",
    danger: T?.danger || "#C24A3F",
    amber: T?.amber || "#E9A13B",
    card: T?.card || "#fff",
    paper: T?.paper || "#F1F4F2",
  };
  const box = { background: cor.card, borderRadius: 14, border: `1px solid ${cor.line}`, padding: 16, marginBottom: 12 };
  const field = { width: "100%", padding: "8px 10px", borderRadius: 8, border: `1px solid ${cor.line}`, fontSize: 13, boxSizing: "border-box", fontFamily: "inherit" };
  const label = { display: "block", fontSize: 12, fontWeight: 700, color: cor.muted, marginBottom: 4 };
  const secondaryButton = { display: "inline-flex", alignItems: "center", gap: 6, border: `1px solid ${cor.line}`, background: cor.card, color: cor.ink, borderRadius: 999, padding: "7px 12px", fontSize: 12, fontWeight: 700 };

  const carregar = useCallback(async () => {
    try {
      setErro("");
      setCarregando(true);
      const [q, a] = await Promise.all([
        listarQuestoesDisciplina(turma.disciplinaId),
        listarAvaliacoesDisciplina(turma.disciplinaId),
      ]);
      setQuestoes(q);
      setAvaliacoes(a);
    } catch (e) {
      console.error(e);
      setErro("Não foi possível carregar as avaliações desta disciplina.");
    } finally {
      setCarregando(false);
    }
  }, [turma.disciplinaId]);

  useEffect(() => { carregar(); }, [carregar]);

  const questoesAtivas = useMemo(() => questoes.filter((q) => q.ativa !== false), [questoes]);

  function adicionarAlternativa() {
    setAlternativas((atual) => [...atual, { id: `alt-${Date.now()}`, texto: "" }]);
  }

  function removerAlternativa(id) {
    setAlternativas((atual) => {
      if (atual.length <= 2) return atual;
      const novaLista = atual.filter((item) => item.id !== id);
      setRespostaCorreta((atualCorreta) => atualCorreta === id ? (novaLista[0]?.id || "") : atualCorreta);
      return novaLista;
    });
  }

  async function salvarQuestao(e) {
    e.preventDefault();
    if (!questaoEnunciado.trim()) { toast?.("Informe o enunciado."); return; }
    const alternativasValidas = alternativas.filter((item) => item.texto.trim());
    if (questaoTipo === "objetiva" && (alternativasValidas.length < 2 || !alternativasValidas.some((item) => item.id === respostaCorreta))) {
      toast?.("Inclua pelo menos duas alternativas e marque o gabarito no círculo ao lado da correta."); return;
    }
    setSalvando(true);
    try {
      await criarQuestao({
        tenantId: perfil.tenant_id,
        disciplinaId: turma.disciplinaId,
        enunciado: questaoEnunciado.trim(),
        tipo: questaoTipo,
        dificuldade: questaoDificuldade,
        alternativas: questaoTipo === "objetiva" ? alternativasValidas : [],
        respostaCorreta: questaoTipo === "objetiva" ? respostaCorreta : null,
        respostaEsperada: questaoTipo === "dissertativa" ? respostaEsperada.trim() : null,
        pontos: questaoPontos,
      });
      toast?.("Questão adicionada ao banco ✓");
      setQuestaoEnunciado("");
      setRespostaEsperada("");
      setQuestaoTipo("objetiva");
      setAlternativas(alternativasIniciais());
      setRespostaCorreta("a");
      await carregar();
    } catch (e) {
      console.error(e);
      toast?.("Não foi possível salvar a questão.");
    } finally {
      setSalvando(false);
    }
  }

  function alternarQuestao(id) {
    setQuestoesEscolhidas((atual) => atual.includes(id) ? atual.filter((x) => x !== id) : [...atual, id]);
  }

  async function salvarProva(e) {
    e.preventDefault();
    if (!provaTitulo.trim()) { toast?.("Informe o título da prova."); return; }
    if (questoesEscolhidas.length === 0) { toast?.("Selecione pelo menos uma questão."); return; }
    setSalvando(true);
    try {
      const prova = await criarAvaliacao({
        tenantId: perfil.tenant_id,
        cursoId: turma.cursoId,
        disciplinaId: turma.disciplinaId,
        turmaId: turma.turmaId,
        titulo: provaTitulo.trim(),
        descricao: provaDescricao.trim(),
        modoAplicacao: provaModo,
        regraLiberacao: provaRegra,
        intervaloDias: provaRegra === "coorte" ? provaIntervalo : 0,
        tentativasPermitidas: provaTentativas,
        notaMinima: provaNotaMinima,
        expiraEmDias: provaExpira || null,
        quantidadeQuestoes: provaQuantidade || null,
        criadoPor: perfil.id,
      });
      await vincularQuestoesAvaliacao(prova.id, questoesEscolhidas);
      toast?.("Prova criada como rascunho ✓");
      setProvaTitulo("");
      setProvaDescricao("");
      setQuestoesEscolhidas([]);
      await carregar();
      setAba("provas");
    } catch (e) {
      console.error(e);
      toast?.("Não foi possível criar a prova.");
    } finally {
      setSalvando(false);
    }
  }

  async function publicar(prova) {
    try {
      await atualizarSituacaoAvaliacao(prova.id, prova.situacao === "publicada" ? "rascunho" : "publicada");
      toast?.(prova.situacao === "publicada" ? "Prova retirada da publicação." : "Prova publicada para os alunos ✓");
      await carregar();
    } catch (e) {
      console.error(e);
      toast?.("Não foi possível alterar a publicação.");
    }
  }

  async function carregarTentativas(prova) {
    setAvaliacaoSelecionada(prova);
    setTentativasCarregando(true);
    try {
      setTentativas(await tentativasAvaliacao(prova.id));
    } catch (e) {
      console.error(e);
      toast?.("Não foi possível carregar as tentativas.");
      setTentativas([]);
    } finally {
      setTentativasCarregando(false);
    }
  }

  async function corrigir(resposta) {
    const valor = Number(correcaoValores[resposta.id]?.pontos);
    if (!Number.isFinite(valor) || valor < 0) { toast?.("Informe uma pontuação válida."); return; }
    try {
      await corrigirRespostaAvaliacao(resposta.id, valor, correcaoValores[resposta.id]?.comentario || "");
      toast?.("Resposta corrigida ✓");
      await carregarTentativas(avaliacaoSelecionada);
    } catch (e) {
      console.error(e);
      toast?.(e?.message || "Não foi possível corrigir a resposta.");
    }
  }

  if (carregando) return <div style={{ ...box, display: "flex", alignItems: "center", gap: 8, color: cor.muted }}><Loader2 size={16} className="kl-spin" /> Carregando banco de questões...</div>;
  if (erro) return <div style={box}><div style={{ color: cor.danger, fontSize: 13 }}>{erro}</div><button onClick={carregar} style={{ ...secondaryButton, marginTop: 10 }}><RefreshCw size={13} /> Tentar novamente</button></div>;

  return (
    <div>
      <div style={{ display: "flex", alignItems: "center", gap: 8, marginBottom: 14 }}>
        <Award size={20} color={cor.forest} />
        <div><div style={{ fontSize: 16, fontWeight: 800, color: cor.ink }}>Avaliações de {turma.disciplinaNome || "disciplina"}</div><div style={{ fontSize: 12, color: cor.muted }}>Banco de questões, regras e correções</div></div>
      </div>
      <div style={{ display: "flex", gap: 8, flexWrap: "wrap", marginBottom: 14 }}>
        {[{ id: "banco", label: "Banco de questões", Icon: FileQuestion }, { id: "provas", label: "Provas", Icon: ClipboardList }, { id: "correcao", label: "Correções", Icon: CheckCircle2 }].map(({ id, label: text, Icon }) => <button key={id} onClick={() => setAba(id)} style={{ display: "inline-flex", alignItems: "center", gap: 6, background: aba === id ? cor.forest : "none", color: aba === id ? "#fff" : cor.muted, border: aba === id ? "none" : `1px solid ${cor.line}`, borderRadius: 999, padding: "6px 12px", fontSize: 12, fontWeight: 700 }}><Icon size={13} /> {text}</button>)}
      </div>

      {aba === "banco" && (
        <>
          <div style={box}>
            <div style={{ fontSize: 14, fontWeight: 800, color: cor.ink, marginBottom: 12, display: "flex", alignItems: "center", gap: 8 }}><Plus size={16} color={cor.forest} /> Nova questão</div>
            <form onSubmit={salvarQuestao}>
              <label style={label}>Enunciado</label>
              <textarea value={questaoEnunciado} onChange={(e) => setQuestaoEnunciado(e.target.value)} rows={4} placeholder="Escreva a questão..." style={{ ...field, resize: "vertical", marginBottom: 10 }} />
              <div style={{ display: "grid", gridTemplateColumns: "1fr 1fr 100px", gap: 8 }}>
                <div><label style={label}>Tipo</label><select value={questaoTipo} onChange={(e) => setQuestaoTipo(e.target.value)} style={field}><option value="objetiva">Objetiva</option><option value="dissertativa">Dissertativa</option></select></div>
                <div><label style={label}>Dificuldade</label><select value={questaoDificuldade} onChange={(e) => setQuestaoDificuldade(e.target.value)} style={field}><option value="facil">Fácil</option><option value="medio">Média</option><option value="dificil">Difícil</option></select></div>
                <div><label style={label}>Pontos</label><input type="number" min="0.1" step="0.1" value={questaoPontos} onChange={(e) => setQuestaoPontos(e.target.value)} style={field} /></div>
              </div>

              {questaoTipo === "objetiva" ? (
                <div style={{ marginTop: 14, padding: 12, borderRadius: 10, background: cor.paper }}>
                  <div style={{ fontSize: 12, fontWeight: 800, color: cor.ink }}>Alternativas e gabarito</div>
                  <div style={{ fontSize: 11, color: cor.muted, margin: "4px 0 10px" }}>Digite cada alternativa. Marque o círculo ao lado da opção correta.</div>
                  {alternativas.map((alt, index) => (
                    <div key={alt.id} style={{ display: "grid", gridTemplateColumns: "24px 24px 1fr auto", gap: 7, alignItems: "center", marginBottom: 8 }}>
                      <input type="radio" name="gabarito" checked={respostaCorreta === alt.id} onChange={() => setRespostaCorreta(alt.id)} aria-label={`Marcar alternativa ${rotuloAlternativa(index)} como correta`} />
                      <span style={{ fontWeight: 800, color: cor.muted }}>{rotuloAlternativa(index)}</span>
                      <input value={alt.texto} onChange={(e) => setAlternativas((atual) => atual.map((item) => item.id === alt.id ? { ...item, texto: e.target.value } : item))} placeholder={`Texto da alternativa ${rotuloAlternativa(index)}`} style={field} />
                      <button type="button" onClick={() => removerAlternativa(alt.id)} disabled={alternativas.length <= 2} title={alternativas.length <= 2 ? "Mínimo de duas alternativas" : "Remover alternativa"} aria-label={`Remover alternativa ${rotuloAlternativa(index)}`} style={{ display: "inline-flex", alignItems: "center", justifyContent: "center", width: 32, height: 32, border: `1px solid ${cor.line}`, background: cor.card, color: alternativas.length <= 2 ? cor.line : cor.danger, borderRadius: 8 }}><Trash2 size={14} /></button>
                    </div>
                  ))}
                  <button type="button" onClick={adicionarAlternativa} style={{ ...secondaryButton, marginTop: 2 }}><Plus size={14} /> Adicionar alternativa</button>
                  <div style={{ fontSize: 11, color: cor.muted, marginTop: 8 }}>Mínimo: 2 alternativas. O gabarito é salvo pelo identificador da opção, não pela posição.</div>
                </div>
              ) : (
                <div style={{ marginTop: 14, padding: 12, borderRadius: 10, background: cor.paper }}>
                  <label style={label}>Resposta esperada (opcional)</label>
                  <div style={{ fontSize: 11, color: cor.muted, marginBottom: 6 }}>Use este campo como referência para a correção manual; ele não aparece para o aluno.</div>
                  <textarea value={respostaEsperada} onChange={(e) => setRespostaEsperada(e.target.value)} rows={4} placeholder="Critérios ou resposta esperada para orientar a correção..." style={{ ...field, resize: "vertical" }} />
                </div>
              )}

              <button type="submit" disabled={salvando} style={{ marginTop: 12, display: "inline-flex", alignItems: "center", gap: 6, background: cor.forest, color: "#fff", border: "none", borderRadius: 999, padding: "9px 16px", fontSize: 13, fontWeight: 700 }}>{salvando ? <Loader2 size={14} className="kl-spin" /> : <Save size={14} />} Salvar questão</button>
            </form>
          </div>
          <div style={box}>
            <div style={{ display: "flex", justifyContent: "space-between", alignItems: "center", gap: 8, flexWrap: "wrap", marginBottom: 10 }}><div style={{ fontSize: 14, fontWeight: 800, color: cor.ink }}>{questoesAtivas.length} questão(ões) ativas</div><button type="button" onClick={carregar} style={secondaryButton}><RefreshCw size={13} /> Atualizar lista</button></div>
            {questoesAtivas.length === 0 ? <div style={{ fontSize: 13, color: cor.muted }}>Nenhuma questão ativa encontrada para esta disciplina. Verifique se o curso/disciplina selecionado é o mesmo usado no cadastro.</div> : questoesAtivas.map((q) => <div key={q.id} style={{ padding: "10px 0", borderTop: `1px solid ${cor.line}` }}><div style={{ fontSize: 13, fontWeight: 700, color: cor.ink }}>{q.enunciado}</div><div style={{ fontSize: 11, color: cor.muted, marginTop: 3 }}>{q.tipo === "objetiva" ? "Objetiva" : "Dissertativa"} · {q.dificuldade} · {q.pontos} ponto(s)</div></div>)}
          </div>
        </>
      )}

      {aba === "provas" && (
        <>
          <div style={box}>
            <div style={{ fontSize: 14, fontWeight: 800, color: cor.ink, marginBottom: 12 }}>Montar nova prova</div>
            <form onSubmit={salvarProva}>
              <label style={label}>Título</label><input value={provaTitulo} onChange={(e) => setProvaTitulo(e.target.value)} placeholder="Ex.: Avaliação da Unidade 1" style={{ ...field, marginBottom: 9 }} />
              <label style={label}>Descrição</label><textarea value={provaDescricao} onChange={(e) => setProvaDescricao(e.target.value)} rows={2} placeholder="Orientações ao aluno" style={{ ...field, resize: "vertical", marginBottom: 9 }} />
              <div style={{ display: "grid", gridTemplateColumns: "1fr 1fr", gap: 8 }}><div><label style={label}>Aplicação</label><select value={provaModo} onChange={(e) => setProvaModo(e.target.value)} style={field}><option value="presencial">Presencial/manual</option><option value="ead">EAD</option></select></div><div><label style={label}>Liberação</label><select value={provaRegra} onChange={(e) => setProvaRegra(e.target.value)} style={field}><option value="manual">Manual</option><option value="coorte">Por coorte</option></select></div></div>
              <div style={{ display: "grid", gridTemplateColumns: "repeat(4, 1fr)", gap: 8, marginTop: 9 }}><div><label style={label}>Intervalo (dias)</label><input type="number" min="0" value={provaIntervalo} onChange={(e) => setProvaIntervalo(e.target.value)} disabled={provaRegra !== "coorte"} style={field} /></div><div><label style={label}>Tentativas</label><input type="number" min="1" max="10" value={provaTentativas} onChange={(e) => setProvaTentativas(e.target.value)} style={field} /></div><div><label style={label}>Nota mínima %</label><input type="number" min="0" max="100" value={provaNotaMinima} onChange={(e) => setProvaNotaMinima(e.target.value)} style={field} /></div><div><label style={label}>Expira em dias</label><input type="number" min="1" value={provaExpira} onChange={(e) => setProvaExpira(e.target.value)} style={field} /></div></div>
              <div style={{ marginTop: 9 }}><label style={label}>Limite de questões (opcional; sorteia um subconjunto)</label><input type="number" min="1" value={provaQuantidade} onChange={(e) => setProvaQuantidade(e.target.value)} placeholder={`Todas (${questoesAtivas.length})`} style={field} /></div>
              <div style={{ marginTop: 12, padding: 12, borderRadius: 10, background: cor.paper }}>
                <div style={{ display: "flex", justifyContent: "space-between", gap: 8, alignItems: "center", flexWrap: "wrap", marginBottom: 8 }}><div><div style={{ fontSize: 12, fontWeight: 800, color: cor.ink }}>Selecionar questões ({questoesEscolhidas.length})</div><div style={{ fontSize: 11, color: cor.muted }}>Marque as questões que entrarão nesta prova.</div></div><span style={{ fontSize: 11, fontWeight: 800, color: cor.forest }}>{questoesAtivas.length} disponíveis</span></div>
                {questoesAtivas.length === 0 ? <div style={{ padding: 10, borderRadius: 8, background: cor.card, color: cor.muted, fontSize: 12 }}>Nenhuma questão disponível para selecionar nesta disciplina.</div> : questoesAtivas.map((q) => <label key={q.id} style={{ display: "flex", gap: 9, alignItems: "flex-start", padding: "9px 8px", borderRadius: 8, border: `1px solid ${questoesEscolhidas.includes(q.id) ? cor.forest : cor.line}`, background: questoesEscolhidas.includes(q.id) ? "#EAF6F0" : cor.card, fontSize: 12, color: cor.ink, marginBottom: 7, cursor: "pointer" }}><input type="checkbox" checked={questoesEscolhidas.includes(q.id)} onChange={() => alternarQuestao(q.id)} style={{ marginTop: 2 }} /><span><strong style={{ display: "block" }}>{q.enunciado}</strong><small style={{ color: cor.muted }}>{q.tipo === "objetiva" ? "Objetiva" : "Dissertativa"} · {q.dificuldade} · {q.pontos} ponto(s)</small></span></label>)}
              </div>
              <button type="submit" disabled={salvando} style={{ marginTop: 12, display: "inline-flex", alignItems: "center", gap: 6, background: cor.forest, color: "#fff", border: "none", borderRadius: 999, padding: "9px 16px", fontSize: 13, fontWeight: 700 }}>{salvando ? <Loader2 size={14} className="kl-spin" /> : <Save size={14} />} Salvar rascunho</button>
            </form>
          </div>
          <div style={box}><div style={{ fontSize: 14, fontWeight: 800, color: cor.ink, marginBottom: 10 }}>Provas desta disciplina</div>{avaliacoes.length === 0 ? <div style={{ fontSize: 13, color: cor.muted }}>Nenhuma prova montada ainda.</div> : avaliacoes.map((prova) => <div key={prova.id} style={{ borderTop: `1px solid ${cor.line}`, padding: "10px 0", display: "flex", justifyContent: "space-between", alignItems: "center", gap: 8, flexWrap: "wrap" }}><div><div style={{ fontSize: 13, fontWeight: 800, color: cor.ink }}>{prova.titulo}</div><div style={{ fontSize: 11, color: cor.muted }}>{prova.situacao} · {prova.avaliacao_questoes?.length || 0} questão(ões) · {prova.regra_liberacao === "coorte" ? `coorte a cada ${prova.intervalo_dias} dias` : "manual"}</div></div><button onClick={() => publicar(prova)} style={{ display: "inline-flex", alignItems: "center", gap: 5, background: prova.situacao === "publicada" ? cor.amber : cor.forest, color: prova.situacao === "publicada" ? cor.ink : "#fff", border: "none", borderRadius: 999, padding: "6px 11px", fontSize: 11, fontWeight: 700 }}>{prova.situacao === "publicada" ? "Despublicar" : "Publicar"}</button></div>)}</div>
        </>
      )}

      {aba === "correcao" && (
        <div style={box}>
          <div style={{ fontSize: 14, fontWeight: 800, color: cor.ink, marginBottom: 10 }}>Correção de dissertativas</div>
          <select value={avaliacaoSelecionada?.id || ""} onChange={(e) => { const prova = avaliacoes.find((item) => item.id === e.target.value); if (prova) carregarTentativas(prova); }} style={{ ...field, marginBottom: 12 }}><option value="">Selecione uma prova</option>{avaliacoes.filter((a) => a.situacao === "publicada").map((a) => <option key={a.id} value={a.id}>{a.titulo}</option>)}</select>
          {tentativasCarregando ? <div style={{ display: "flex", gap: 8, color: cor.muted }}><Loader2 size={15} className="kl-spin" /> Carregando tentativas...</div> : !avaliacaoSelecionada ? <div style={{ fontSize: 13, color: cor.muted }}>Selecione uma prova publicada.</div> : tentativas.length === 0 ? <div style={{ fontSize: 13, color: cor.muted }}>Nenhuma tentativa recebida ainda.</div> : tentativas.map((tentativa) => <div key={tentativa.id} style={{ borderTop: `1px solid ${cor.line}`, padding: "10px 0" }}><div style={{ display: "flex", justifyContent: "space-between", gap: 8, fontSize: 13, color: cor.ink }}><strong>Tentativa {tentativa.numero_tentativa}</strong><span>{tentativa.situacao} · {tentativa.percentual ?? "—"}%</span></div>{(tentativa.avaliacao_respostas || []).filter((r) => !r.corrigida).map((resposta) => <div key={resposta.id} style={{ marginTop: 9, padding: 10, borderRadius: 9, background: cor.paper }}><div style={{ fontSize: 12, fontWeight: 700, color: cor.ink }}>{questoes.find((q) => q.id === resposta.questao_id)?.enunciado || "Resposta dissertativa"}</div>{questoes.find((q) => q.id === resposta.questao_id)?.resposta_esperada && <div style={{ fontSize: 11, color: cor.muted, marginTop: 5, padding: "6px 8px", borderRadius: 7, background: cor.card }}><strong>Referência do professor:</strong> {questoes.find((q) => q.id === resposta.questao_id).resposta_esperada}</div>}<div style={{ fontSize: 13, color: cor.ink, marginTop: 6, whiteSpace: "pre-wrap" }}>{resposta.resposta_texto || "(sem resposta)"}</div><div style={{ display: "grid", gridTemplateColumns: "100px 1fr auto", gap: 7, marginTop: 8 }}><input type="number" min="0" step="0.1" placeholder="Pontos" value={correcaoValores[resposta.id]?.pontos || ""} onChange={(e) => setCorrecaoValores((atual) => ({ ...atual, [resposta.id]: { ...atual[resposta.id], pontos: e.target.value } }))} style={field} /><input placeholder="Comentário (opcional)" value={correcaoValores[resposta.id]?.comentario || ""} onChange={(e) => setCorrecaoValores((atual) => ({ ...atual, [resposta.id]: { ...atual[resposta.id], comentario: e.target.value } }))} style={field} /><button onClick={() => corrigir(resposta)} style={{ display: "inline-flex", alignItems: "center", gap: 5, background: cor.forest, color: "#fff", border: "none", borderRadius: 8, padding: "7px 10px", fontSize: 11, fontWeight: 700 }}><CheckCircle2 size={13} /> Corrigir</button></div></div>)}</div>)}
        </div>
      )}
    </div>
  );
}
