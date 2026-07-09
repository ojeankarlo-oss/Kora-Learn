import React, { useEffect, useState } from "react";
import { criarPreMatricula, listarCursosPublico, obterTenantPublico } from "./lib/api";
import { TEMA_PADRAO, montarTema } from "./theme";

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
  const [tema, setTema] = useState(TEMA_PADRAO);
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
        const temaMontado = montarTema(tenantPub);
        setTema(temaMontado);
        
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
      await criarPreMatricula({
        tenantId: tenantId || import.meta.env.VITE_TENANT_ID,
        cursoId: cursoId || null,
        origem: "site",
        nome,
        email: normalizedEmail,
        telefone,
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
      }}>
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
      }}>
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
      }}>
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
    }}>
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
