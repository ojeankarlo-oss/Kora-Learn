import React, { useCallback, useEffect, useState } from "react";
import { Users, UserPlus, Pencil, UserX, UserCheck, RefreshCw, AlertTriangle, Loader2, X, Link2 } from "lucide-react";
import {
  listarColaboradores, criarColaborador, atualizarColaborador,
  desligarColaborador, reativarColaborador, listarUnidades,
  vincularAcessoProfessorColaborador,
} from "./lib/api";

// Reconhece funcoes de ensino (hoje so "professor(a)"; poderia crescer para uma
// lista configuravel por escola no futuro) para decidir quando oferecer o botao
// de dar acesso/vincular turmas.
function ehFuncaoDeEnsino(funcao) {
  return /professor/i.test(funcao || "");
}

const brl = new Intl.NumberFormat("pt-BR", { style: "currency", currency: "BRL" });

const TIPOS_VINCULO = [
  { value: "clt", label: "CLT" },
  { value: "pj", label: "PJ" },
  { value: "voluntario", label: "Voluntário" },
  { value: "bolsista", label: "Bolsista" },
  { value: "estagiario", label: "Estagiário" },
  { value: "outro", label: "Outro" },
];

function rotuloTipoVinculo(valor) {
  return TIPOS_VINCULO.find((t) => t.value === valor)?.label || valor || "—";
}

function formatarCentavos(centavos) {
  return brl.format((Number(centavos) || 0) / 100);
}

function hojeISO() {
  return new Date().toISOString().slice(0, 10);
}

// Converte "3500,00" ou "3500" em centavos. Retorna null se vazio, NaN se invalido.
function valorParaCentavos(texto) {
  const t = String(texto ?? "").trim();
  if (!t) return null;
  const limpo = t.replace(/\./g, "").replace(",", ".");
  const num = Number(limpo);
  if (!isFinite(num) || num < 0) return NaN;
  return Math.round(num * 100);
}

function seloSituacao(situacao, T) {
  if (situacao === "ativo") return { label: "Ativo", bg: "#EAF6F0", fg: T?.success || "#2E8B63" };
  if (situacao === "afastado") return { label: "Afastado", bg: "#FFF5E3", fg: T?.amber || "#E9A13B" };
  return { label: "Desligado", bg: T?.paper || "#F1F4F2", fg: T?.muted || "#5C6E67" };
}

function ColaboradorModal({ inicial, unidades, souPerfilGestor, salvando, onSalvar, onFechar, T }) {
  const [nome, setNome] = useState(inicial?.nome || "");
  const [nomeSocial, setNomeSocial] = useState(inicial?.nome_social || "");
  const [cpf, setCpf] = useState(inicial?.cpf || "");
  const [email, setEmail] = useState(inicial?.email || "");
  const [telefone, setTelefone] = useState(inicial?.telefone || "");
  const [funcao, setFuncao] = useState(inicial?.funcao || "");
  const [tipoVinculo, setTipoVinculo] = useState(inicial?.tipo_vinculo || "clt");
  const [unidadeId, setUnidadeId] = useState(inicial?.unidade_id || "");
  const [cargaHoraria, setCargaHoraria] = useState(inicial?.carga_horaria ?? "");
  const [dataAdmissao, setDataAdmissao] = useState(inicial?.data_admissao || hojeISO());
  const [salarioTexto, setSalarioTexto] = useState(
    souPerfilGestor && inicial?.salario_centavos != null
      ? String(inicial.salario_centavos / 100).replace(".", ",")
      : ""
  );
  const [erro, setErro] = useState("");

  const corLine = T?.line || "#DDE5E1";
  const corMuted = T?.muted || "#5C6E67";
  const corInk = T?.ink || "#10201A";
  const corForest = T?.forest || "#17604A";
  const corDanger = T?.danger || "#C24A3F";

  const rotulo = { display: "block", fontSize: 12, fontWeight: 600, color: corMuted, marginBottom: 4 };
  const campo = { width: "100%", boxSizing: "border-box", padding: "10px 12px", borderRadius: 10, border: `1.5px solid ${corLine}`, fontSize: 14 };

  const handleSubmit = (e) => {
    e.preventDefault();
    setErro("");

    if (!nome.trim()) { setErro("Informe o nome do colaborador."); return; }
    if (!funcao.trim()) { setErro("Informe a função."); return; }

    let salarioCentavos;
    if (souPerfilGestor) {
      salarioCentavos = valorParaCentavos(salarioTexto);
      if (Number.isNaN(salarioCentavos)) { setErro("Informe um salário válido (ex.: 3500,00) ou deixe em branco."); return; }
    }

    const dados = {
      nome: nome.trim(),
      nome_social: nomeSocial.trim() || null,
      cpf: cpf.trim() || null,
      email: email.trim() || null,
      telefone: telefone.trim() || null,
      funcao: funcao.trim(),
      tipo_vinculo: tipoVinculo,
      unidade_id: unidadeId || null,
      carga_horaria: cargaHoraria !== "" ? Number(cargaHoraria) : null,
      data_admissao: dataAdmissao || null,
      ...(souPerfilGestor ? { salario_centavos: salarioCentavos } : {}),
    };

    onSalvar(dados);
  };

  return (
    <div
      onClick={onFechar}
      style={{ position: "fixed", inset: 0, background: "rgba(16,32,26,0.45)", display: "flex", alignItems: "center", justifyContent: "center", zIndex: 60, padding: 16 }}
    >
      <div
        onClick={(e) => e.stopPropagation()}
        style={{ width: "100%", maxWidth: 560, maxHeight: "85vh", overflowY: "auto", background: "#fff", borderRadius: 16, padding: 20 }}
      >
        <div style={{ display: "flex", justifyContent: "space-between", alignItems: "center", marginBottom: 16 }}>
          <h2 style={{ fontSize: 16, fontWeight: 800, color: corInk, margin: 0 }}>
            {inicial ? "Editar colaborador" : "Cadastrar colaborador"}
          </h2>
          <button onClick={onFechar} style={{ background: "none", border: "none", cursor: "pointer", padding: 4 }}>
            <X size={18} color={corMuted} />
          </button>
        </div>

        <form onSubmit={handleSubmit}>
          <div style={{ marginBottom: 12 }}>
            <label style={rotulo}>Nome *</label>
            <input style={campo} value={nome} onChange={(e) => setNome(e.target.value)} placeholder="Nome completo" />
          </div>

          <div style={{ marginBottom: 12 }}>
            <label style={rotulo}>Nome social (opcional)</label>
            <input style={campo} value={nomeSocial} onChange={(e) => setNomeSocial(e.target.value)} placeholder="Nome social" />
          </div>

          <div style={{ display: "grid", gridTemplateColumns: "1fr 1fr", gap: 10, marginBottom: 12 }}>
            <div>
              <label style={rotulo}>CPF</label>
              <input style={campo} value={cpf} onChange={(e) => setCpf(e.target.value)} placeholder="000.000.000-00" />
            </div>
            <div>
              <label style={rotulo}>Telefone</label>
              <input style={campo} value={telefone} onChange={(e) => setTelefone(e.target.value)} placeholder="(00) 00000-0000" />
            </div>
          </div>

          <div style={{ marginBottom: 12 }}>
            <label style={rotulo}>E-mail</label>
            <input type="email" style={campo} value={email} onChange={(e) => setEmail(e.target.value)} placeholder="colaborador@exemplo.com" />
          </div>

          <div style={{ display: "grid", gridTemplateColumns: "1fr 1fr", gap: 10, marginBottom: 12 }}>
            <div>
              <label style={rotulo}>Função *</label>
              <input style={campo} value={funcao} onChange={(e) => setFuncao(e.target.value)} placeholder="Ex.: Professora" />
            </div>
            <div>
              <label style={rotulo}>Tipo de vínculo</label>
              <select style={campo} value={tipoVinculo} onChange={(e) => setTipoVinculo(e.target.value)}>
                {TIPOS_VINCULO.map((t) => (
                  <option key={t.value} value={t.value}>{t.label}</option>
                ))}
              </select>
            </div>
          </div>

          <div style={{ display: "grid", gridTemplateColumns: "1fr 1fr", gap: 10, marginBottom: 12 }}>
            <div>
              <label style={rotulo}>Unidade</label>
              <select style={campo} value={unidadeId} onChange={(e) => setUnidadeId(e.target.value)}>
                <option value="">Sem unidade definida</option>
                {unidades.map((u) => (
                  <option key={u.id} value={u.id}>{u.nome}</option>
                ))}
              </select>
            </div>
            <div>
              <label style={rotulo}>Carga horária (h/semana)</label>
              <input type="number" min={0} style={campo} value={cargaHoraria} onChange={(e) => setCargaHoraria(e.target.value)} placeholder="40" />
            </div>
          </div>

          <div style={{ marginBottom: 12 }}>
            <label style={rotulo}>Data de admissão</label>
            <input type="date" style={campo} value={dataAdmissao} onChange={(e) => setDataAdmissao(e.target.value)} />
          </div>

          {souPerfilGestor && (
            <div style={{ marginBottom: 12 }}>
              <label style={rotulo}>Salário (confidencial — visível apenas à gestão)</label>
              <input style={campo} value={salarioTexto} onChange={(e) => setSalarioTexto(e.target.value)} placeholder="3500,00" inputMode="decimal" />
            </div>
          )}

          {erro && (
            <div style={{ marginBottom: 12, padding: 10, borderRadius: 10, background: "#FBEFEC", color: corDanger, fontSize: 13, fontWeight: 500 }}>
              {erro}
            </div>
          )}

          <div style={{ display: "flex", gap: 8, marginTop: 4 }}>
            <button type="submit" disabled={salvando}
              style={{ flex: 1, padding: "12px 14px", borderRadius: 12, border: "none", background: salvando ? corMuted : corForest, color: "#fff", fontWeight: 700, fontSize: 14, cursor: salvando ? "not-allowed" : "pointer" }}>
              {salvando ? "Salvando..." : inicial ? "Salvar alterações" : "Cadastrar colaborador"}
            </button>
            <button type="button" onClick={onFechar}
              style={{ padding: "12px 18px", borderRadius: 12, border: `1px solid ${corLine}`, background: "none", color: corInk, fontWeight: 700, fontSize: 14, cursor: "pointer" }}>
              Cancelar
            </button>
          </div>
        </form>
      </div>
    </div>
  );
}

export default function RH({ perfil, toast, T, onVincularTurmas }) {
  const souPerfilGestor = perfil?.perfil === "gestor" || perfil?.perfil === "super_admin";

  const [unidades, setUnidades] = useState([]);
  const [unidadeFiltro, setUnidadeFiltro] = useState("");
  const [busca, setBusca] = useState("");
  const [colaboradores, setColaboradores] = useState(null);
  const [erro, setErro] = useState("");
  const [modalAberto, setModalAberto] = useState(false);
  const [editando, setEditando] = useState(null);
  const [salvando, setSalvando] = useState(false);
  const [processandoId, setProcessandoId] = useState(null);
  const [vinculandoId, setVinculandoId] = useState(null);

  const carregarUnidades = useCallback(async () => {
    try {
      const data = await listarUnidades();
      setUnidades(data);
    } catch (e) {
      console.error(e);
      setUnidades([]);
    }
  }, []);

  const carregar = useCallback(async () => {
    try {
      setErro("");
      const data = await listarColaboradores({ souPerfilGestor, unidadeId: unidadeFiltro || undefined, busca });
      setColaboradores(data);
    } catch (e) {
      console.error(e);
      setErro("Não foi possível carregar os colaboradores.");
      setColaboradores([]);
    }
  }, [souPerfilGestor, unidadeFiltro, busca]);

  useEffect(() => { carregarUnidades(); }, [carregarUnidades]);
  useEffect(() => { carregar(); }, [carregar]);

  const abrirCriar = () => { setEditando(null); setModalAberto(true); };
  const abrirEditar = (colab) => { setEditando(colab); setModalAberto(true); };
  const fecharModal = () => { if (salvando) return; setModalAberto(false); setEditando(null); };

  const salvar = async (dados) => {
    setSalvando(true);
    try {
      if (editando) {
        await atualizarColaborador(editando.id, dados);
        toast?.("Colaborador atualizado ✓");
      } else {
        await criarColaborador({ ...dados, tenant_id: perfil.tenant_id });
        toast?.("Colaborador cadastrado ✓");
      }
      setModalAberto(false);
      setEditando(null);
      await carregar();
    } catch (e) {
      console.error(e);
      toast?.("Erro ao salvar colaborador");
    } finally {
      setSalvando(false);
    }
  };

  const desligar = async (colab) => {
    if (!window.confirm(`Desligar ${colab.nome}?`)) return;
    const dataInformada = window.prompt("Data de desligamento (AAAA-MM-DD):", hojeISO());
    if (dataInformada === null) return;
    if (!/^\d{4}-\d{2}-\d{2}$/.test(dataInformada.trim())) {
      toast?.("Data inválida. Use o formato AAAA-MM-DD.");
      return;
    }
    setProcessandoId(colab.id);
    try {
      await desligarColaborador(colab.id, dataInformada.trim());
      toast?.("Colaborador desligado");
      await carregar();
    } catch (e) {
      console.error(e);
      toast?.("Erro ao desligar colaborador");
    } finally {
      setProcessandoId(null);
    }
  };

  const reativar = async (colab) => {
    if (!window.confirm(`Reativar ${colab.nome}?`)) return;
    setProcessandoId(colab.id);
    try {
      await reativarColaborador(colab.id);
      toast?.("Colaborador reativado");
      await carregar();
    } catch (e) {
      console.error(e);
      toast?.("Erro ao reativar colaborador");
    } finally {
      setProcessandoId(null);
    }
  };

  // Cria o login de professor deste colaborador (se ainda nao tiver) reaproveitando
  // nome/email ja cadastrados no RH, e abre a tela de vinculo com turmas ja
  // pre-selecionando esse professor. Ponto de entrada unico do cadastro de professor.
  const vincularProfessor = async (colab) => {
    setVinculandoId(colab.id);
    try {
      const jaTinhaAcesso = !!colab.usuario_id;
      const usuarioId = await vincularAcessoProfessorColaborador(colab);
      if (!jaTinhaAcesso) {
        toast?.("Login de professor criado ✓");
        await carregar();
      }
      onVincularTurmas?.({ ...colab, usuario_id: usuarioId });
    } catch (e) {
      console.error(e);
      toast?.(e?.message || "Erro ao dar acesso de professor");
    } finally {
      setVinculandoId(null);
    }
  };

  const corLine = T?.line || "#DDE5E1";
  const corMuted = T?.muted || "#5C6E67";
  const corInk = T?.ink || "#10201A";
  const corForest = T?.forest || "#17604A";
  const corDanger = T?.danger || "#C24A3F";

  return (
    <div style={{ marginTop: 20 }}>
      <div style={{ display: "flex", justifyContent: "space-between", alignItems: "center", gap: 10, flexWrap: "wrap", marginBottom: 12 }}>
        <div style={{ display: "flex", alignItems: "center", gap: 8 }}>
          <Users size={18} color={corForest} />
          <div style={{ fontSize: 15, fontWeight: 800, color: corInk }}>Colaboradores</div>
        </div>
        <button onClick={abrirCriar}
          style={{ display: "flex", alignItems: "center", gap: 6, background: corForest, color: "#fff", border: "none", borderRadius: 999, padding: "8px 14px", fontSize: 12, fontWeight: 700, cursor: "pointer" }}>
          <UserPlus size={14} /> Cadastrar colaborador
        </button>
      </div>

      <div style={{ display: "flex", gap: 8, flexWrap: "wrap", marginBottom: 12 }}>
        <select
          value={unidadeFiltro}
          onChange={(e) => setUnidadeFiltro(e.target.value)}
          style={{ padding: "8px 12px", borderRadius: 10, border: `1px solid ${corLine}`, fontSize: 13 }}
        >
          <option value="">Todas as unidades</option>
          {unidades.map((u) => (
            <option key={u.id} value={u.id}>{u.nome}</option>
          ))}
        </select>
        <input
          value={busca}
          onChange={(e) => setBusca(e.target.value)}
          placeholder="Buscar por nome"
          style={{ flex: "1 1 200px", padding: "8px 12px", borderRadius: 10, border: `1px solid ${corLine}`, fontSize: 13, boxSizing: "border-box" }}
        />
        <button onClick={carregar} style={{ display: "flex", alignItems: "center", gap: 4, background: "none", border: "none", color: corForest, fontSize: 12, fontWeight: 700, cursor: "pointer" }}>
          <RefreshCw size={12} /> Atualizar
        </button>
      </div>

      {erro ? (
        <div style={{ padding: 24, textAlign: "center", border: `1px solid ${corLine}`, borderRadius: 14 }}>
          <AlertTriangle size={26} color={corDanger} />
          <div style={{ fontSize: 13, color: corMuted, marginTop: 6 }}>{erro}</div>
          <button onClick={carregar}
            style={{ marginTop: 10, display: "inline-flex", alignItems: "center", gap: 6, background: corForest, color: "#fff", border: "none", borderRadius: 999, padding: "8px 16px", fontSize: 13, fontWeight: 700, cursor: "pointer" }}>
            <RefreshCw size={13} /> Tentar de novo
          </button>
        </div>
      ) : colaboradores === null ? (
        <div style={{ display: "flex", alignItems: "center", gap: 8, color: corMuted, fontSize: 13, padding: 24 }}>
          <Loader2 className="kl-spin" size={16} /> Carregando colaboradores...
        </div>
      ) : colaboradores.length === 0 ? (
        <div style={{ padding: 24, textAlign: "center", border: `1px solid ${corLine}`, borderRadius: 14 }}>
          <Users size={26} color={corMuted} />
          <div style={{ fontSize: 13, color: corMuted, marginTop: 6 }}>Nenhum colaborador cadastrado ainda.</div>
        </div>
      ) : (
        <div style={{ border: `1px solid ${corLine}`, borderRadius: 14, overflow: "hidden" }}>
          {colaboradores.map((c, i) => {
            const selo = seloSituacao(c.situacao, T);
            const unidadeNome = unidades.find((u) => u.id === c.unidade_id)?.nome;
            const ocupado = processandoId === c.id;
            return (
              <div key={c.id} style={{ padding: "12px 14px", borderTop: i ? `1px solid ${corLine}` : "none", display: "flex", justifyContent: "space-between", alignItems: "center", gap: 8, flexWrap: "wrap" }}>
                <div>
                  <div style={{ fontSize: 14, fontWeight: 700, color: corInk }}>
                    {c.nome}{c.nome_social ? ` (${c.nome_social})` : ""}
                  </div>
                  <div style={{ fontSize: 12, color: corMuted }}>
                    {c.funcao} · {rotuloTipoVinculo(c.tipo_vinculo)}{unidadeNome ? ` · ${unidadeNome}` : ""}
                  </div>
                  {souPerfilGestor && (
                    <div style={{ fontSize: 12, color: corMuted, marginTop: 2 }}>
                      {c.salario_centavos != null ? formatarCentavos(c.salario_centavos) : "Salário não informado"}
                    </div>
                  )}
                </div>
                <div style={{ display: "flex", alignItems: "center", gap: 8, flexWrap: "wrap" }}>
                  <span style={{ fontSize: 11, fontWeight: 700, padding: "4px 10px", borderRadius: 999, background: selo.bg, color: selo.fg }}>
                    {selo.label}
                  </span>
                  <button onClick={() => abrirEditar(c)} disabled={ocupado}
                    style={{ display: "flex", alignItems: "center", gap: 4, background: "none", border: `1px solid ${corLine}`, color: corInk, borderRadius: 10, padding: "6px 10px", fontSize: 12, fontWeight: 700, cursor: ocupado ? "not-allowed" : "pointer" }}>
                    <Pencil size={13} /> Editar
                  </button>
                  {ehFuncaoDeEnsino(c.funcao) && c.situacao !== "desligado" && (
                    <button onClick={() => vincularProfessor(c)} disabled={ocupado || vinculandoId === c.id}
                      style={{ display: "flex", alignItems: "center", gap: 4, background: "none", border: `1px solid ${corForest}`, color: corForest, borderRadius: 10, padding: "6px 10px", fontSize: 12, fontWeight: 700, cursor: (ocupado || vinculandoId === c.id) ? "not-allowed" : "pointer" }}>
                      <Link2 size={13} /> {vinculandoId === c.id ? "Vinculando..." : c.usuario_id ? "Vincular às turmas" : "Dar acesso de professor"}
                    </button>
                  )}
                  {c.situacao !== "desligado" ? (
                    <button onClick={() => desligar(c)} disabled={ocupado}
                      style={{ display: "flex", alignItems: "center", gap: 4, background: corDanger, color: "#fff", border: "none", borderRadius: 10, padding: "8px 12px", fontSize: 12, fontWeight: 700, cursor: ocupado ? "not-allowed" : "pointer" }}>
                      <UserX size={13} /> Desligar
                    </button>
                  ) : (
                    <button onClick={() => reativar(c)} disabled={ocupado}
                      style={{ display: "flex", alignItems: "center", gap: 4, background: corForest, color: "#fff", border: "none", borderRadius: 10, padding: "8px 12px", fontSize: 12, fontWeight: 700, cursor: ocupado ? "not-allowed" : "pointer" }}>
                      <UserCheck size={13} /> Reativar
                    </button>
                  )}
                </div>
              </div>
            );
          })}
        </div>
      )}

      {modalAberto && (
        <ColaboradorModal
          key={editando?.id || "novo"}
          inicial={editando}
          unidades={unidades}
          souPerfilGestor={souPerfilGestor}
          salvando={salvando}
          onSalvar={salvar}
          onFechar={fecharModal}
          T={T}
        />
      )}
    </div>
  );
}
