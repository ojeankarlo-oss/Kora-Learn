import React, { useCallback, useEffect, useState } from "react";
import { Wallet, TrendingUp, AlertTriangle, CheckCircle2, Clock, XCircle, RefreshCw, Loader2 } from "lucide-react";
import { kpisFinanceiro, listarMatriculas, gerarMensalidades, listarTitulos, darBaixaTitulo, cancelarTitulo } from "./lib/api";

const brl = new Intl.NumberFormat("pt-BR", { style: "currency", currency: "BRL" });
const FORMAS = ["Pix", "Dinheiro", "Cartão", "Boleto", "Outro"];

function formatarCentavos(centavos) {
  return brl.format((Number(centavos) || 0) / 100);
}

function formatarData(iso) {
  if (!iso) return "";
  const [ano, mes, dia] = String(iso).slice(0, 10).split("-");
  return `${dia}/${mes}/${ano}`;
}

function hojeISO() {
  return new Date().toISOString().slice(0, 10);
}

// Converte "150,00" ou "150" em centavos (inteiro).
function valorParaCentavos(texto) {
  const limpo = String(texto).trim().replace(/\./g, "").replace(",", ".");
  const num = Number(limpo);
  if (!isFinite(num) || num < 0) return NaN;
  return Math.round(num * 100);
}

function situacaoExibicao(t) {
  if (t.situacao === "aberto" && t.data_vencimento < hojeISO()) return "vencido";
  return t.situacao;
}

function seloInfo(sit, T) {
  if (sit === "pago") return { label: "Pago", bg: T?.success || "#2E8B63", fg: "#fff", Icon: CheckCircle2 };
  if (sit === "vencido") return { label: "Vencido", bg: T?.danger || "#C24A3F", fg: "#fff", Icon: AlertTriangle };
  if (sit === "cancelado") return { label: "Cancelado", bg: T?.line || "#DDE5E1", fg: T?.muted || "#5C6E67", Icon: XCircle };
  return { label: "Aberto", bg: T?.amberSoft || "#FBEFDA", fg: T?.ink || "#10201A", Icon: Clock };
}

const FILTROS = [
  { id: "todos", label: "Todos" },
  { id: "aberto", label: "Abertos" },
  { id: "vencido", label: "Vencidos" },
  { id: "pago", label: "Pagos" },
  { id: "cancelado", label: "Cancelados" },
];

export default function FinanceiroGestor({ perfil, toast, T }) {
  const [kpis, setKpis] = useState(null);
  const [kpisErro, setKpisErro] = useState("");
  const [matriculas, setMatriculas] = useState([]);
  const [titulos, setTitulos] = useState(null);
  const [titulosErro, setTitulosErro] = useState("");
  const [filtro, setFiltro] = useState("todos");
  const [busca, setBusca] = useState("");
  const [salvando, setSalvando] = useState(false);
  const [baixando, setBaixando] = useState(null);

  // Formulario de mensalidades
  const [matriculaId, setMatriculaId] = useState("");
  const [valorTexto, setValorTexto] = useState("");
  const [parcelas, setParcelas] = useState(1);
  const [diaVencimento, setDiaVencimento] = useState(10);
  const [competencia, setCompetencia] = useState(new Date().toISOString().slice(0, 7));

  const carregarKpis = useCallback(async () => {
    try {
      setKpisErro("");
      const data = await kpisFinanceiro();
      setKpis(data);
    } catch (e) {
      console.error(e);
      setKpisErro("Não foi possível carregar os indicadores.");
      setKpis(null);
    }
  }, []);

  const carregarTitulos = useCallback(async () => {
    try {
      setTitulosErro("");
      const situacaoQuery = filtro === "todos" || filtro === "vencido" ? undefined : filtro;
      let lista = await listarTitulos({ situacao: situacaoQuery, busca });
      if (filtro === "vencido") {
        lista = lista.filter((t) => t.situacao === "aberto" && t.data_vencimento < hojeISO());
      }
      setTitulos(lista);
    } catch (e) {
      console.error(e);
      setTitulosErro("Não foi possível carregar os títulos.");
      setTitulos([]);
    }
  }, [filtro, busca]);

  const carregarMatriculas = useCallback(async () => {
    try {
      const data = await listarMatriculas();
      setMatriculas((data || []).filter((m) => m.situacao === "ativa"));
    } catch (e) {
      console.error(e);
      setMatriculas([]);
    }
  }, []);

  useEffect(() => { carregarKpis(); }, [carregarKpis]);
  useEffect(() => { carregarMatriculas(); }, [carregarMatriculas]);
  useEffect(() => { carregarTitulos(); }, [carregarTitulos]);

  async function gerarParcelas() {
    const m = matriculas.find((x) => String(x.id) === String(matriculaId));
    if (!m) { toast?.("Selecione uma matrícula ativa."); return; }
    const centavos = valorParaCentavos(valorTexto);
    if (!Number.isFinite(centavos) || centavos <= 0) { toast?.("Informe um valor válido (ex.: 150,00)."); return; }
    const n = Number(parcelas);
    if (!n || n < 1 || n > 24) { toast?.("Número de parcelas deve ser de 1 a 24."); return; }
    setSalvando(true);
    try {
      const criadas = await gerarMensalidades({
        matriculaId: m.id,
        usuarioId: m.aluno?.id,
        tenantId: perfil.tenant_id,
        cursoNome: m.curso?.nome || "Curso",
        valorCentavos: centavos,
        parcelas: n,
        diaVencimento: Number(diaVencimento),
        primeiraCompetencia: competencia,
      });
      toast?.(`${criadas.length} parcelas geradas`);
      setValorTexto("");
      await Promise.all([carregarKpis(), carregarTitulos()]);
    } catch (e) {
      console.error(e);
      toast?.("Erro ao gerar parcelas.");
    } finally {
      setSalvando(false);
    }
  }

  async function baixar(t) {
    const forma = window.prompt(`Forma de pagamento (${FORMAS.join(", ")}):`, "Pix");
    if (forma === null) return;
    const formaValida = FORMAS.find((f) => f.toLowerCase() === forma.trim().toLowerCase()) || "Outro";
    setBaixando(t.id);
    try {
      await darBaixaTitulo(t.id, formaValida);
      toast?.("Baixa registrada.");
      await Promise.all([carregarKpis(), carregarTitulos()]);
    } catch (e) {
      console.error(e);
      toast?.("Erro ao dar baixa.");
    } finally {
      setBaixando(null);
    }
  }

  async function cancelar(t) {
    if (!window.confirm("Cancelar este título?")) return;
    const motivo = window.prompt("Motivo (opcional):", "") || "";
    setBaixando(t.id);
    try {
      await cancelarTitulo(t.id, motivo);
      toast?.("Título cancelado.");
      await Promise.all([carregarKpis(), carregarTitulos()]);
    } catch (e) {
      console.error(e);
      toast?.("Erro ao cancelar.");
    } finally {
      setBaixando(null);
    }
  }

  const box = { background: T?.card || "#fff", borderRadius: 14, border: `1px solid ${T?.line || "#DDE5E1"}`, padding: 16, marginBottom: 16 };
  const rotulo = { fontSize: 12, fontWeight: 700, color: T?.muted || "#5C6E67", marginBottom: 4, display: "block" };
  const campo = { width: "100%", padding: "8px 10px", borderRadius: 8, border: `1px solid ${T?.line || "#DDE5E1"}`, fontSize: 13, boxSizing: "border-box" };

  return (
    <div style={{ marginTop: 16 }}>
      {/* KPIs */}
      {kpisErro ? (
        <div style={box}>
          <div style={{ color: T?.danger || "#C24A3F", fontSize: 14, marginBottom: 10 }}>{kpisErro}</div>
          <button onClick={carregarKpis} style={{ display: "inline-flex", alignItems: "center", gap: 6, border: `1px solid ${T?.line}`, background: "none", borderRadius: 999, padding: "6px 14px", fontSize: 13, fontWeight: 700, cursor: "pointer", color: T?.ink }}>
            <RefreshCw size={14} /> Tentar de novo
          </button>
        </div>
      ) : kpis === null ? (
        <div style={{ ...box, display: "flex", alignItems: "center", gap: 8, color: T?.muted }}>
          <Loader2 size={16} className="kl-spin" /> Carregando indicadores...
        </div>
      ) : (
        <div style={{ display: "flex", gap: 12, flexWrap: "wrap", marginBottom: 16 }}>
          {[
            { titulo: "A receber no mês", dado: kpis.aReceberMes, cor: T?.forest || "#17604A", Icon: TrendingUp },
            { titulo: "Recebido no mês", dado: kpis.recebidoMes, cor: T?.success || "#2E8B63", Icon: CheckCircle2 },
            { titulo: "Vencidos", dado: kpis.vencidos, cor: T?.danger || "#C24A3F", Icon: AlertTriangle },
          ].map(({ titulo, dado, cor, Icon }) => (
            <div key={titulo} style={{ ...box, marginBottom: 0, flex: "1 1 180px", minWidth: 180 }}>
              <div style={{ display: "flex", alignItems: "center", gap: 6, fontSize: 12, fontWeight: 700, color: T?.muted }}>
                <Icon size={14} color={cor} /> {titulo}
              </div>
              <div style={{ fontSize: 20, fontWeight: 800, color: T?.ink, marginTop: 6 }}>{formatarCentavos(dado.total)}</div>
              <div style={{ fontSize: 12, color: T?.muted }}>{dado.qtd} {dado.qtd === 1 ? "título" : "títulos"}</div>
            </div>
          ))}
        </div>
      )}

      {/* Lançar mensalidades */}
      <div style={box}>
        <div style={{ fontSize: 15, fontWeight: 800, color: T?.ink, display: "flex", alignItems: "center", gap: 8, marginBottom: 12 }}>
          <Wallet size={18} color={T?.forest || "#17604A"} /> Lançar mensalidades
        </div>
        <div style={{ display: "grid", gridTemplateColumns: "repeat(auto-fit, minmax(150px, 1fr))", gap: 10 }}>
          <div style={{ gridColumn: "1 / -1" }}>
            <label style={rotulo}>Aluno / matrícula</label>
            <select style={campo} value={matriculaId} onChange={(e) => setMatriculaId(e.target.value)}>
              <option value="">Selecione...</option>
              {matriculas.map((m) => (
                <option key={m.id} value={m.id}>{m.aluno?.nome || "Aluno"} — {m.curso?.nome || "Curso"}</option>
              ))}
            </select>
          </div>
          <div>
            <label style={rotulo}>Valor da parcela</label>
            <input style={campo} placeholder="150,00" value={valorTexto} onChange={(e) => setValorTexto(e.target.value)} inputMode="decimal" />
          </div>
          <div>
            <label style={rotulo}>Nº de parcelas</label>
            <input style={campo} type="number" min={1} max={24} value={parcelas} onChange={(e) => setParcelas(e.target.value)} />
          </div>
          <div>
            <label style={rotulo}>Dia de vencimento</label>
            <input style={campo} type="number" min={1} max={28} value={diaVencimento} onChange={(e) => setDiaVencimento(e.target.value)} />
          </div>
          <div>
            <label style={rotulo}>Mês da 1ª parcela</label>
            <input style={campo} type="month" value={competencia} onChange={(e) => setCompetencia(e.target.value)} />
          </div>
        </div>
        <button onClick={gerarParcelas} disabled={salvando} style={{ marginTop: 12, display: "inline-flex", alignItems: "center", gap: 6, background: T?.forest || "#17604A", color: "#fff", border: "none", borderRadius: 999, padding: "9px 18px", fontSize: 13, fontWeight: 700, cursor: salvando ? "default" : "pointer", opacity: salvando ? 0.7 : 1 }}>
          {salvando ? <Loader2 size={14} className="kl-spin" /> : <Wallet size={14} />} Gerar parcelas
        </button>
      </div>

      {/* Lista de títulos */}
      <div style={box}>
        <div style={{ display: "flex", justifyContent: "space-between", alignItems: "center", gap: 10, flexWrap: "wrap", marginBottom: 12 }}>
          <div style={{ display: "flex", gap: 6, flexWrap: "wrap" }}>
            {FILTROS.map((f) => (
              <button key={f.id} onClick={() => setFiltro(f.id)} style={{ background: filtro === f.id ? T?.forest || "#17604A" : "none", color: filtro === f.id ? "#fff" : T?.muted, border: filtro === f.id ? "none" : `1px solid ${T?.line}`, borderRadius: 999, padding: "5px 12px", fontSize: 12, fontWeight: 700, cursor: "pointer" }}>
                {f.label}
              </button>
            ))}
          </div>
          <input style={{ ...campo, maxWidth: 220 }} placeholder="Buscar por nome do aluno" value={busca} onChange={(e) => setBusca(e.target.value)} />
        </div>

        {titulosErro ? (
          <div>
            <div style={{ color: T?.danger || "#C24A3F", fontSize: 14, marginBottom: 10 }}>{titulosErro}</div>
            <button onClick={carregarTitulos} style={{ display: "inline-flex", alignItems: "center", gap: 6, border: `1px solid ${T?.line}`, background: "none", borderRadius: 999, padding: "6px 14px", fontSize: 13, fontWeight: 700, cursor: "pointer", color: T?.ink }}>
              <RefreshCw size={14} /> Tentar de novo
            </button>
          </div>
        ) : titulos === null ? (
          <div style={{ display: "flex", alignItems: "center", gap: 8, color: T?.muted, fontSize: 14 }}>
            <Loader2 size={16} className="kl-spin" /> Carregando títulos...
          </div>
        ) : titulos.length === 0 ? (
          <div style={{ textAlign: "center", color: T?.muted, fontSize: 14, padding: "12px 0" }}>Nenhum título encontrado.</div>
        ) : (
          <div style={{ display: "flex", flexDirection: "column", gap: 8 }}>
            {titulos.map((t) => {
              const sit = situacaoExibicao(t);
              const selo = seloInfo(sit, T);
              const SeloIcon = selo.Icon;
              const podeAgir = t.situacao === "aberto";
              return (
                <div key={t.id} style={{ border: `1px solid ${T?.line || "#DDE5E1"}`, borderRadius: 10, padding: 12, display: "flex", justifyContent: "space-between", alignItems: "center", gap: 10, flexWrap: "wrap" }}>
                  <div style={{ flex: "1 1 200px", minWidth: 180 }}>
                    <div style={{ fontSize: 14, fontWeight: 700, color: T?.ink }}>{t.aluno?.nome || "Aluno"}</div>
                    <div style={{ fontSize: 12, color: T?.muted }}>{t.descricao}</div>
                    <div style={{ fontSize: 12, color: T?.muted }}>Venc.: {formatarData(t.data_vencimento)}</div>
                  </div>
                  <div style={{ fontSize: 14, fontWeight: 800, color: T?.ink }}>{formatarCentavos(t.valor_centavos)}</div>
                  <span style={{ display: "inline-flex", alignItems: "center", gap: 4, background: selo.bg, color: selo.fg, borderRadius: 999, padding: "3px 10px", fontSize: 11, fontWeight: 700 }}>
                    <SeloIcon size={12} /> {selo.label}
                  </span>
                  {podeAgir && (
                    <div style={{ display: "flex", gap: 6 }}>
                      <button onClick={() => baixar(t)} disabled={baixando === t.id} style={{ background: T?.forest || "#17604A", color: "#fff", border: "none", borderRadius: 999, padding: "5px 12px", fontSize: 12, fontWeight: 700, cursor: "pointer" }}>Dar baixa</button>
                      <button onClick={() => cancelar(t)} disabled={baixando === t.id} style={{ background: "none", color: T?.danger || "#C24A3F", border: `1px solid ${T?.line}`, borderRadius: 999, padding: "5px 12px", fontSize: 12, fontWeight: 700, cursor: "pointer" }}>Cancelar</button>
                    </div>
                  )}
                </div>
              );
            })}
          </div>
        )}
      </div>
    </div>
  );
}
