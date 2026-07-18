import React, { useEffect, useState } from "react";
import { criarPreMatricula, listarCursosPublico, obterTenantPublico, listarUnidadesPublico } from "./lib/api";
import { TEMA_PADRAO, montarTema, aplicarAcessibilidade } from "./theme";
import ControleAcessibilidade from "./AcessibilidadeControle";

const NECESSIDADES_OPCOES = [
  { chave: "baixa_visao", label: "Baixa visão" },
  { chave: "cegueira", label: "Cegueira" },
  { chave: "surdez", label: "Surdez ou baixa audição" },
  { chave: "fisica_motora", label: "Deficiência física/motora" },
  { chave: "tea", label: "TEA" },
  { chave: "tdah", label: "TDAH" },
];

function LogoKoraImg({ logo_url, nomeMarca, T, size = 32 }) {
  if (logo_url) {
    return (
      <div style={{ display: "flex", alignItems: "center", gap: 8 }}>
        <img 
          src={logo_url} 
          alt={nomeMarca}
          style={{ height: size, borderRadius: 8, objectFit: "contain" }}
        />
        <div style={{ fontFamily: "'Archivo', sans-serif" }}>
          <div style={{ fontSize: size * 0.8, fontWeight: 800, color: T.forest }}>
            {nomeMarca}
          </div>
        </div>
      </div>
    );
  }
  
  const c = T.forest;
  const FONT = "'Archivo', 'Inter', sans-serif";
  return (
    <svg width={size * 3.2} height={size} viewBox="0 0 128 40" fill="none">
      <rect width="40" height="40" rx="10" fill={T.amberSoft} />
      <text x="20" y="28" textAnchor="middle" fontFamily={FONT}
        fontSize="22" fontWeight="800" fill={c}>K</text>
      <text x="55" y="28" fontFamily={FONT} fontSize="20" fontWeight="700" fill={c}>KORA</text>
      <text x="55" y="38" fontFamily={FONT} fontSize="9" fontWeight="400"
        fill={T.muted} letterSpacing="2">LEARN</text>
    </svg>
  );
}

function Campo({ label, type = "text", value, onChange, placeholder, required, T }) {
  const FONT = "'Archivo', 'Inter', sans-serif";
  return (
    <div style={{ marginTop: 16 }}>
      <label style={{ display: "block", fontSize: 12, fontWeight: 600,
        color: T.muted, marginBottom: 4 }}>
        {label}{required && <span style={{ color: T.amber }}> *</span>}
      </label>
      <input
        type={type}
        value={value}
        onChange={e => onChange(e.target.value)}
        placeholder={placeholder}
        required={required}
        style={{
          width: "100%", padding: "10px 14px", borderRadius: 10,
          border: `1.5px solid ${T.line}`, fontSize: 14, fontFamily: FONT,
          outline: "none", boxSizing: "border-box", color: T.ink,
          background: "#fff",
        }}
      />
    </div>
  );
}

export default function PreMatricula() {
  // temaBase: identidade visual do tenant (marca). tema: temaBase + acessibilidade aplicada.
  const [temaBase, setTemaBase] = useState(TEMA_PADRAO);
  const [prefFonte, setPrefFonte] = useState("normal");
  const [altoContraste, setAltoContraste] = useState(false);
  const tema = aplicarAcessibilidade(temaBase, { prefFonte, altoContraste });
  const [nome, setNome] = useState("");
  const [email, setEmail] = useState("");
  const [telefone, setTelefone] = useState("");
  const [cursoId, setCursoId] = useState("");
  const [cursos, setCursos] = useState([]);
  const [loading, setLoading] = useState(false);
  const [sucesso, setSucesso] = useState(false);
  const [erro, setErro] = useState("");
  const [loadingTenant, setLoadingTenant] = useState(true);
  const [tenantNaoEncontrado, setTenantNaoEncontrado] = useState(false);
  const [inscricaoEncerrada, setInscricaoEncerrada] = useState(false);
  const [tenantId, setTenantId] = useState(null);
  const [unidadesPublico, setUnidadesPublico] = useState([]);
  const [unidadeId, setUnidadeId] = useState("");
  const [temNecessidade, setTemNecessidade] = useState(false);
  const [necessidadesSelecionadas, setNecessidadesSelecionadas] = useState([]);
  const [outraSelecionada, setOutraSelecionada] = useState(false);
  const [outraTexto, setOutraTexto] = useState("");

  function alternarNecessidade(chave) {
    setNecessidadesSelecionadas((prev) =>
      prev.includes(chave) ? prev.filter((c) => c !== chave) : [...prev, chave]
    );
  }

  // Parsear query da URL (dentro do hash)
  const extrairSlugDaURL = () => {
    const hash = window.location.hash; // Ex: #/inscricao?t=kora-demo
    const match = hash.match(/\?t=([^&]+)/);
    return match ? match[1] : "kora-demo";
  };

  // Carregar tenant e atualizar tema
  useEffect(() => {
    const slug = extrairSlugDaURL();
    setLoadingTenant(true);
    
    obterTenantPublico(slug)
      .then((tenantPub) => {
        if (!tenantPub) {
          setTenantNaoEncontrado(true);
          setLoadingTenant(false);
          return;
        }
        
        setTenantId(tenantPub.id);
        listarUnidadesPublico(tenantPub.id)
          .then((lista) => setUnidadesPublico(lista || []))
          .catch(() => setUnidadesPublico([]));
        const temaMontado = montarTema(tenantPub);
        setTemaBase(temaMontado);
        
        // Verificar se inscrição está desabilitada
        if (tenantPub.modulos && tenantPub.modulos.inscricao_publica === false) {
          setInscricaoEncerrada(true);
        }
        
        setLoadingTenant(false);
      })
      .catch((e) => {
        console.error("Erro ao carregar tenant público", e);
        setTenantNaoEncontrado(true);
        setLoadingTenant(false);
      });
  }, []);

  // Carregar cursos
  useEffect(() => {
    if (inscricaoEncerrada || tenantNaoEncontrado) return;
    
    let ativo = true;
    listarCursosPublico()
      .then((data) => {
        if (ativo) setCursos(data);
      })
      .catch(() => {
        if (ativo) setErro("Não foi possível carregar os cursos disponíveis.");
      });
    return () => {
      ativo = false;
    };
  }, [inscricaoEncerrada, tenantNaoEncontrado]);

  async function handleSubmit(e) {
    e.preventDefault();
    setErro("");
    const emailRegex = /^[^\s@]+@[^\s@]+\.[^\s@]+$/i;
    const normalizedEmail = email.trim().toLowerCase();

    if (!emailRegex.test(normalizedEmail)) {
      setErro("Por favor, informe um e-mail válido.");
      return;
    }
    setLoading(true);
    try {
      const necessidadesEspecificas = temNecessidade
        ? [
            ...necessidadesSelecionadas,
            ...(outraSelecionada && outraTexto.trim() ? [`outra:${outraTexto.trim()}`] : []),
          ]
        : null;
      await criarPreMatricula({
        tenantId: tenantId || import.meta.env.VITE_TENANT_ID,
        cursoId: cursoId || null,
          unidadeId: unidadesPublico.length === 1 ? unidadesPublico[0].id : (unidadeId || null),
        origem: "site",
        nome,
        email: normalizedEmail,
        telefone,
        temNecessidadeEspecifica: temNecessidade,
        necessidadesEspecificas,
      });
      setSucesso(true);
    } catch (err) {
      setErro("Ocorreu um erro ao enviar. Tente novamente.");
    } finally {
      setLoading(false);
    }
  }

  const FONT = "'Archivo', 'Inter', sans-serif";

  // Estado de carregamento
  if (loadingTenant) {
    return (
      <div style={{
        minHeight: "100vh",
        background: tema.forestDark,
        display: "flex",
        flexDirection: "column",
        alignItems: "center",
        justifyContent: "center",
        padding: "24px 16px",
        fontFamily: FONT,
        zoom: "var(--kl-font-scale)",
      }}>
        <ControleAcessibilidade prefFonte={prefFonte} altoContraste={altoContraste} onFonte={setPrefFonte} onContraste={setAltoContraste} T={tema} />
        <div style={{ fontSize: 14, color: "#CFE0D8" }}>Carregando…</div>
      </div>
    );
  }

  // Tenant não encontrado
  if (tenantNaoEncontrado) {
    return (
      <div style={{
        minHeight: "100vh",
        background: tema.forestDark,
        display: "flex",
        flexDirection: "column",
        alignItems: "center",
        justifyContent: "center",
        padding: "24px 16px",
        fontFamily: FONT,
        zoom: "var(--kl-font-scale)",
      }}>
        <ControleAcessibilidade prefFonte={prefFonte} altoContraste={altoContraste} onFonte={setPrefFonte} onContraste={setAltoContraste} T={tema} />
        <div style={{ marginBottom: 28, textAlign: "center" }}>
          <LogoKoraImg logo_url={tema.logo_url} nomeMarca={tema.nomeMarca} T={tema} size={34} />
        </div>
        <div style={{
          background: "#fff", borderRadius: 20, padding: "28px 24px",
          width: "100%", maxWidth: 400, boxShadow: "0 8px 40px #00000033",
          textAlign: "center",
        }}>
          <div style={{ fontSize: 18, fontWeight: 700, color: tema.ink, marginBottom: 12 }}>
            Página não encontrada
          </div>
          <p style={{ fontSize: 14, color: tema.muted, lineHeight: 1.6 }}>
            Desculpe, não conseguimos encontrar a página que você procura. Verifique o link e tente novamente.
          </p>
        </div>
      </div>
    );
  }

  // Inscrição encerrada
  if (inscricaoEncerrada) {
    return (
      <div style={{
        minHeight: "100vh",
        background: tema.forestDark,
        display: "flex",
        flexDirection: "column",
        alignItems: "center",
        justifyContent: "center",
        padding: "24px 16px",
        fontFamily: FONT,
        zoom: "var(--kl-font-scale)",
      }}>
        <ControleAcessibilidade prefFonte={prefFonte} altoContraste={altoContraste} onFonte={setPrefFonte} onContraste={setAltoContraste} T={tema} />
        <div style={{ marginBottom: 28, textAlign: "center" }}>
          <LogoKoraImg logo_url={tema.logo_url} nomeMarca={tema.nomeMarca} T={tema} size={34} />
          <p style={{ color: "#CFE0D8", fontSize: 14, marginTop: 12,
            maxWidth: 300, lineHeight: 1.5 }}>
            {tema.slogan}
          </p>
        </div>
        <div style={{
          background: "#fff", borderRadius: 20, padding: "28px 24px",
          width: "100%", maxWidth: 400, boxShadow: "0 8px 40px #00000033",
          textAlign: "center",
        }}>
          <div style={{ fontSize: 18, fontWeight: 700, color: tema.ink, marginBottom: 12 }}>
            Inscrições encerradas
          </div>
          <p style={{ fontSize: 14, color: tema.muted, lineHeight: 1.6 }}>
            As inscrições estão encerradas no momento. Fale com a secretaria.
          </p>
        </div>
      </div>
    );
  }

  // Formulário normal
  return (
    <div style={{
      minHeight: "100vh",
      background: tema.forestDark,
      display: "flex",
      flexDirection: "column",
      alignItems: "center",
      justifyContent: "center",
      padding: "24px 16px",
      fontFamily: FONT,
      zoom: "var(--kl-font-scale)",
    }}>
      <ControleAcessibilidade prefFonte={prefFonte} altoContraste={altoContraste} onFonte={setPrefFonte} onContraste={setAltoContraste} T={tema} />
      <div style={{ marginBottom: 28, textAlign: "center" }}>
        <LogoKoraImg logo_url={tema.logo_url} nomeMarca={tema.nomeMarca} T={tema} size={34} />
        <p style={{ color: "#CFE0D8", fontSize: 14, marginTop: 12,
          maxWidth: 300, lineHeight: 1.5 }}>
          {tema.slogan}
        </p>
      </div>
      <div style={{
        background: "#fff", borderRadius: 20, padding: "28px 24px",
        width: "100%", maxWidth: 400, boxShadow: "0 8px 40px #00000033",
      }}>
        {sucesso ? (
          <div style={{ textAlign: "center", padding: "8px 0" }}>
            <div style={{ fontSize: 48, marginBottom: 12 }}>🎉</div>
            <div style={{ fontSize: 18, fontWeight: 700, color: tema.forest, marginBottom: 8 }}>
              Inscrição recebida!
            </div>
            <p style={{ fontSize: 14, color: tema.muted, lineHeight: 1.6 }}>
              Em breve nossa equipe entra em contato.
            </p>
            <p style={{ fontSize: 13, color: tema.muted, marginTop: 16, fontStyle: "italic" }}>
              {tema.slogan}
            </p>
          </div>
        ) : (
          <form onSubmit={handleSubmit}>
            <div style={{ fontSize: 18, fontWeight: 700, color: tema.ink, marginBottom: 4 }}>
              Pré-matrícula
            </div>
            <div style={{ fontSize: 13, color: tema.muted, marginBottom: 8 }}>
              Preencha os dados abaixo para garantir sua vaga.
            </div>
            <Campo label="Nome completo" value={nome} onChange={setNome}
              placeholder="Seu nome" required T={tema} />
            <Campo label="E-mail" type="email" value={email} onChange={setEmail}
              placeholder="seu@email.com" required T={tema} />
            <Campo label="Telefone / WhatsApp" value={telefone}
              onChange={setTelefone} placeholder="(00) 00000-0000" T={tema} />
            <div style={{ marginTop: 16 }}>
              <label style={{ display: "block", fontSize: 12, fontWeight: 600,
                color: tema.muted, marginBottom: 4 }}>
                Curso de interesse
              </label>
              <select
                value={cursoId}
                onChange={(e) => setCursoId(e.target.value)}
                style={{
                  width: "100%", padding: "10px 14px", borderRadius: 10,
                  border: `1.5px solid ${tema.line}`, fontSize: 14, fontFamily: FONT,
                  outline: "none", boxSizing: "border-box", color: tema.ink,
                  background: "#fff",
                }}
              >
                <option value="">Quero conhecer os cursos</option>
                {cursos.map((curso) => (
                  <option key={curso.id} value={curso.id}>{curso.nome}</option>
                ))}
              </select>
            </div>
            {unidadesPublico.length >= 2 && (
              <div style={{ marginTop: 16 }}>
                <label style={{ display: "block", fontSize: 12, fontWeight: 600,
                  color: tema.muted, marginBottom: 4 }}>
                  Unidade / Polo
                </label>
                <select
                  value={unidadeId}
                  onChange={(e) => setUnidadeId(e.target.value)}
                  style={{
                    width: "100%", padding: "10px 14px", borderRadius: 10,
                    border: `1.5px solid ${tema.line}`, fontSize: 14, fontFamily: FONT,
                    outline: "none", boxSizing: "border-box", color: tema.ink,
                    background: "#fff",
                  }}
                >
                  <option value="">Qualquer unidade</option>
                  {unidadesPublico.map((u) => (
                    <option key={u.id} value={u.id}>{u.nome}</option>
                  ))}
                </select>
              </div>
            )}
            <div style={{ marginTop: 20 }}>
              <label style={{ display: "block", fontSize: 12, fontWeight: 600,
                color: tema.muted, marginBottom: 8 }}>
                Você tem alguma deficiência ou necessidade específica? (opcional)
              </label>
              <div style={{ display: "flex", gap: 8 }}>
                <button
                  type="button"
                  onClick={() => setTemNecessidade(true)}
                  style={{
                    flex: 1, padding: "8px 10px", borderRadius: 10,
                    border: `1.5px solid ${temNecessidade ? tema.forest : tema.line}`,
                    background: temNecessidade ? tema.forest : "#fff",
                    color: temNecessidade ? "#fff" : tema.ink,
                    fontFamily: FONT, fontSize: 13, fontWeight: 700,
                  }}
                >
                  Sim
                </button>
                <button
                  type="button"
                  onClick={() => { setTemNecessidade(false); setNecessidadesSelecionadas([]); setOutraSelecionada(false); setOutraTexto(""); }}
                  style={{
                    flex: 1, padding: "8px 10px", borderRadius: 10,
                    border: `1.5px solid ${!temNecessidade ? tema.forest : tema.line}`,
                    background: !temNecessidade ? tema.forest : "#fff",
                    color: !temNecessidade ? "#fff" : tema.ink,
                    fontFamily: FONT, fontSize: 13, fontWeight: 700,
                  }}
                >
                  Não
                </button>
              </div>

              {temNecessidade && (
                <div style={{ marginTop: 12 }}>
                  <p style={{ fontSize: 12, color: tema.muted, lineHeight: 1.5, marginTop: 0, marginBottom: 10 }}>
                    Essa informação é opcional e usada apenas para prepararmos o melhor atendimento para você.
                    Fica visível somente à coordenação pedagógica da escola.
                  </p>
                  <div style={{ display: "flex", flexDirection: "column", gap: 8 }}>
                    {NECESSIDADES_OPCOES.map((op) => (
                      <label key={op.chave} style={{ display: "flex", alignItems: "center", gap: 8, fontSize: 13, color: tema.ink, fontFamily: FONT }}>
                        <input
                          type="checkbox"
                          checked={necessidadesSelecionadas.includes(op.chave)}
                          onChange={() => alternarNecessidade(op.chave)}
                        />
                        {op.label}
                      </label>
                    ))}
                    <label style={{ display: "flex", alignItems: "center", gap: 8, fontSize: 13, color: tema.ink, fontFamily: FONT }}>
                      <input
                        type="checkbox"
                        checked={outraSelecionada}
                        onChange={(e) => setOutraSelecionada(e.target.checked)}
                      />
                      Outra
                    </label>
                    {outraSelecionada && (
                      <input
                        value={outraTexto}
                        onChange={(e) => setOutraTexto(e.target.value)}
                        placeholder="Qual?"
                        style={{
                          width: "100%", padding: "8px 12px", borderRadius: 8,
                          border: `1.5px solid ${tema.line}`, fontSize: 13, fontFamily: FONT,
                          outline: "none", boxSizing: "border-box", color: tema.ink,
                        }}
                      />
                    )}
                  </div>
                </div>
              )}
            </div>
            {erro && (
              <div style={{ marginTop: 12, fontSize: 13, color: tema.danger,
                background: "#fdf0ef", borderRadius: 8, padding: "8px 12px" }}>
                {erro}
              </div>
            )}
            <button
              type="submit"
              disabled={loading}
              style={{
                marginTop: 20, width: "100%", padding: "13px",
                background: loading ? tema.muted : tema.forest,
                color: "#fff", border: "none", borderRadius: 12,
                fontSize: 15, fontWeight: 700, fontFamily: FONT,
                cursor: loading ? "not-allowed" : "pointer",
                transition: "background 0.2s",
              }}
            >
              {loading ? "Enviando..." : "Quero me inscrever"}
            </button>
          </form>
        )}
      </div>
    </div>
  );
}
