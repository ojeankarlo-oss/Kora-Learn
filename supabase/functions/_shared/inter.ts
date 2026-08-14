export type InterConfig = {
  clientId: string;
  clientSecret: string;
  cert: string;
  key: string;
  pixKey: string;
  account?: string;
  sandbox: boolean;
};

const PRODUCAO_BASE = "https://cdpj.partners.bancointer.com.br";
const SANDBOX_BASE = "https://cdpj-sandbox.partners.uatinter.co";

function requireEnv(nome: string): string {
  const valor = Deno.env.get(nome)?.trim();
  if (!valor) throw new Error(`Secret ausente: ${nome}`);
  return valor;
}

export function loadInterConfig(): InterConfig {
  return {
    clientId: requireEnv("INTER_CLIENT_ID"),
    clientSecret: requireEnv("INTER_CLIENT_SECRET"),
    cert: requireEnv("INTER_CERT_PEM"),
    key: requireEnv("INTER_KEY_PEM"),
    pixKey: requireEnv("INTER_PIX_KEY"),
    account: Deno.env.get("INTER_ACCOUNT")?.trim() || undefined,
    sandbox: (Deno.env.get("INTER_ENV") || "sandbox").toLowerCase() !== "producao",
  };
}

export function interBaseUrl(config: InterConfig): string {
  return config.sandbox ? SANDBOX_BASE : PRODUCAO_BASE;
}

function baseHeaders(config: InterConfig, accessToken: string): Headers {
  const headers = new Headers({
    Authorization: `Bearer ${accessToken}`,
    Accept: "application/json",
    "Content-Type": "application/json",
  });
  if (config.account) headers.set("x-conta-corrente", config.account);
  return headers;
}

export async function interAccessToken(config: InterConfig, client: Deno.HttpClient): Promise<string> {
  const body = new URLSearchParams({
    client_id: config.clientId,
    client_secret: config.clientSecret,
    grant_type: "client_credentials",
    scope: "cob.write",
  });
  const basic = btoa(`${config.clientId}:${config.clientSecret}`);
  const response = await fetch(`${interBaseUrl(config)}/oauth/v2/token`, {
    method: "POST",
    client,
    headers: {
      Authorization: `Basic ${basic}`,
      "Content-Type": "application/x-www-form-urlencoded",
      Accept: "application/json",
    },
    body,
  });
  const payload = await response.json().catch(() => ({}));
  if (!response.ok || !payload.access_token) {
    throw new Error(`Banco Inter OAuth ${response.status}: ${payload.detail || payload.error || "token não obtido"}`);
  }
  return payload.access_token as string;
}

export async function interRequest(
  config: InterConfig,
  client: Deno.HttpClient,
  accessToken: string,
  path: string,
  init: RequestInit = {},
): Promise<unknown> {
  const headers = baseHeaders(config, accessToken);
  for (const [nome, valor] of new Headers(init.headers || {})) headers.set(nome, valor);
  const response = await fetch(`${interBaseUrl(config)}${path}`, {
    ...init,
    client,
    headers,
  });
  const texto = await response.text();
  let payload: unknown = {};
  try {
    payload = texto ? JSON.parse(texto) : {};
  } catch {
    payload = { raw: texto };
  }
  if (!response.ok) {
    const detalhe = typeof payload === "object" && payload !== null
      ? (payload as Record<string, unknown>).detail || (payload as Record<string, unknown>).title
      : undefined;
    throw new Error(`Banco Inter ${response.status}: ${detalhe || "requisição recusada"}`);
  }
  return payload;
}

export async function withInterClient<T>(fn: (client: Deno.HttpClient, config: InterConfig) => Promise<T>): Promise<T> {
  const config = loadInterConfig();
  const client = Deno.createHttpClient({ cert: config.cert, key: config.key });
  try {
    return await fn(client, config);
  } finally {
    client.close();
  }
}
