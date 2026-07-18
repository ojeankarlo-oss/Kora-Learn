// ============================================================
// KORA LEARN — Sistema de temas (white-label)
// Salvar em: src/theme.js
// ============================================================

// Tema padrão KORA
export const TEMA_PADRAO = {
  // Identidade
  nomeMarca: "KORA Learn",
  slogan: "Cada aula aprendida, uma vida se transforma.",
  logo_url: null, // null = usar LogoKora desenhado
  
  // Cores
  forest: "#17604A",      // cor primária
  forestDark: "#0E4536",  // (derivado: ~20% mais escuro)
  amber: "#E9A13B",       // cor de destaque
  amberSoft: "#FBEFDA",   // (derivado: clareado)
  
  // Suporte
  paper: "#F1F4F2",
  card: "#FFFFFF",
  ink: "#10201A",
  line: "#DDE5E1",
  muted: "#5C6E67",
  danger: "#C24A3F",
  success: "#2E8B63",
  
  // Módulos (padrão: todos habilitados)
  modulos: {
    inscricao_publica: true,
    alunos: true,
    financeiro: false,
    documentos: false,
    rh: false,
  },
};

/**
 * Escurece uma cor hex em aproximadamente % da intensidade
 * Exemplo: escurecerCor("#17604A", 20) → #0E4536
 */
function escurecerCor(hex, percent = 20) {
  const r = parseInt(hex.slice(1, 3), 16);
  const g = parseInt(hex.slice(3, 5), 16);
  const b = parseInt(hex.slice(5, 7), 16);
  
  const novoR = Math.max(0, Math.floor(r * (1 - percent / 100)));
  const novoG = Math.max(0, Math.floor(g * (1 - percent / 100)));
  const novoB = Math.max(0, Math.floor(b * (1 - percent / 100)));
  
  return `#${novoR.toString(16).padStart(2, "0")}${novoG.toString(16).padStart(2, "0")}${novoB.toString(16).padStart(2, "0")}`;
}

/**
 * Clareia uma cor hex em aproximadamente % da intensidade
 * Exemplo: calareiCor("#E9A13B", 30) → #FBEFDA
 */
function clarearCor(hex, percent = 30) {
  const r = parseInt(hex.slice(1, 3), 16);
  const g = parseInt(hex.slice(3, 5), 16);
  const b = parseInt(hex.slice(5, 7), 16);
  
  const novoR = Math.min(255, Math.floor(r + (255 - r) * (percent / 100)));
  const novoG = Math.min(255, Math.floor(g + (255 - g) * (percent / 100)));
  const novoB = Math.min(255, Math.floor(b + (255 - b) * (percent / 100)));
  
  return `#${novoR.toString(16).padStart(2, "0")}${novoG.toString(16).padStart(2, "0")}${novoB.toString(16).padStart(2, "0")}`;
}

/* ---------------- ACESSIBILIDADE (fonte + alto contraste) ---------------- */

// 'normal' | 'grande' | 'muito_grande' → multiplicador aplicado via var(--kl-font-scale)
export const ESCALA_FONTE = {
  normal: 1,
  grande: 1.15,
  muito_grande: 1.3,
};

// Paleta de alto contraste — tem prioridade sobre a marca do tenant.
// Fundo bem claro/escuro conforme o padrão de cada tela, texto e bordas no extremo do contraste (AA+).
export const CORES_ALTO_CONTRASTE = {
  paper: "#FFFFFF",
  card: "#FFFFFF",
  ink: "#000000",
  line: "#000000",
  muted: "#1F1F1F",
  forest: "#0B3D2E",
  forestDark: "#000000",
  amber: "#7A4E00",
  amberSoft: "#FFFFFF",
  danger: "#8B0000",
  success: "#0B3D2E",
};

/**
 * Aplica as preferências de acessibilidade (fonte/contraste) sobre um tema já montado.
 * Alto contraste sobrepõe as cores da marca do tenant, por ser uma exigência de acessibilidade.
 */
export function aplicarAcessibilidade(tema, { prefFonte = "normal", altoContraste = false } = {}) {
  return {
    ...tema,
    ...(altoContraste ? CORES_ALTO_CONTRASTE : null),
    fontScale: ESCALA_FONTE[prefFonte] ?? 1,
    altoContraste: !!altoContraste,
  };
}

/**
 * Monta um tema mesclando os dados do tenant com o padrão
 * tenantPub: { id, nome, slug, logo_url, marca: { cor_primaria, cor_destaque, slogan }, modulos: {...} }
 */
export function montarTema(tenantPub) {
  if (!tenantPub) return TEMA_PADRAO;
  
  const marca = tenantPub.marca || {};
  const corPrimaria = marca.cor_primaria || TEMA_PADRAO.forest;
  const corDestaque = marca.cor_destaque || TEMA_PADRAO.amber;
  
  return {
    ...TEMA_PADRAO,
    nomeMarca: tenantPub.nome || TEMA_PADRAO.nomeMarca,
    slogan: marca.slogan || TEMA_PADRAO.slogan,
    logo_url: tenantPub.logo_url || TEMA_PADRAO.logo_url,
    
    // Cores dinâmicas do tenant
    forest: corPrimaria,
    forestDark: escurecerCor(corPrimaria, 20),
    amber: corDestaque,
    amberSoft: clarearCor(corDestaque, 30),
    
    // Módulos do tenant (mescla com padrão)
    modulos: {
      ...TEMA_PADRAO.modulos,
      ...(tenantPub.modulos || {}),
    },
  };
}
