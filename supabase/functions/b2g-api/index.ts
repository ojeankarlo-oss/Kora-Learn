import { createClient } from "npm:@supabase/supabase-js@2";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "x-api-key, x-client-info, apikey, content-type, idempotency-key, x-request-id",
  "Access-Control-Allow-Methods": "GET, POST, OPTIONS",
  "Access-Control-Expose-Headers": "X-Request-Id, X-RateLimit-Remaining, Retry-After",
};

const MAX_BODY_BYTES = 16 * 1024;
const MAX_NAME_LENGTH = 160;
const MAX_EMAIL_LENGTH = 320;
const MAX_PHONE_LENGTH = 40;
const MAX_NOTES_LENGTH = 5_000;
const MAX_IDEMPOTENCY_KEY_LENGTH = 128;
const RATE_LIMIT_WINDOW_SECONDS = 60;

const CONTACT_TYPES = ["lead", "contato", "prospect", "cliente"] as const;
const CONTACT_STATUSES = ["ativo", "inativo", "bloqueado"] as const;
const CONTACT_SOURCES = ["website", "indicacao", "evento", "campanha", "manual", "whatsapp", "parceiro"] as const;

type ContactInput = {
  nome: string;
  email: string | null;
  telefone: string | null;
  tipo: (typeof CONTACT_TYPES)[number];
  fonte: (typeof CONTACT_SOURCES)[number];
  notas: string | null;
};

type ParseResult =
  | { ok: true; value: ContactInput }
  | { ok: false; status: number; erro: string };

type RateLimitResult = {
  allowed: boolean;
  retry_after_seconds: number;
  remaining: number;
};

const CONTACT_SELECT = "id, nome, email, telefone, tipo, status, fonte, criado_em, atualizado_em, idempotency_key, idempotency_fingerprint";

function requestIdFrom(req: Request): string {
  const supplied = req.headers.get("x-request-id")?.trim();
  return supplied ? supplied.slice(0, 128) : crypto.randomUUID();
}

function logEvent(event: string, fields: Record<string, unknown> = {}): void {
  console.log(JSON.stringify({
    service: "b2g-api",
    event,
    at: new Date().toISOString(),
    ...fields,
  }));
}

function json(
  body: unknown,
  status = 200,
  requestId = "",
  extraHeaders: Record<string, string> = {},
): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: {
      ...corsHeaders,
      "Content-Type": "application/json",
      ...(requestId ? { "X-Request-Id": requestId } : {}),
      ...extraHeaders,
    },
  });
}

function apiKeyFromRequest(req: Request): string | null {
  // API keys are accepted only through x-api-key. Authorization Bearer is not a
  // second authentication mode because it is reserved for Supabase JWTs.
  const direct = req.headers.get("x-api-key")?.trim();
  return direct || null;
}

function clientAddressFromRequest(req: Request): string {
  const forwarded = req.headers.get("x-forwarded-for")?.split(",")[0]?.trim();
  const real = req.headers.get("x-real-ip")?.trim();
  return (forwarded || real || "unknown").slice(0, 128);
}

async function sha256Hex(value: string): Promise<string> {
  const bytes = new TextEncoder().encode(value);
  const digest = await crypto.subtle.digest("SHA-256", bytes);
  return Array.from(new Uint8Array(digest), (byte) => byte.toString(16).padStart(2, "0")).join("");
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function isBasicEmail(value: string): boolean {
  return /^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(value);
}

function optionalText(
  body: Record<string, unknown>,
  field: string,
  maxLength: number,
): { ok: true; value: string | null } | { ok: false; erro: string } {
  const raw = body[field];
  if (raw === undefined || raw === null) return { ok: true, value: null };
  if (typeof raw !== "string") return { ok: false, erro: `${field} deve ser texto` };
  const value = raw.trim();
  if (value.length > maxLength) return { ok: false, erro: `${field} excede o tamanho permitido` };
  return { ok: true, value: value || null };
}

async function parseContactBody(req: Request): Promise<ParseResult> {
  const contentType = req.headers.get("content-type") || "";
  if (contentType && !/^application\/json(?:\s*;|$)/i.test(contentType)) {
    return { ok: false, status: 415, erro: "Content-Type deve ser application/json" };
  }

  const raw = await req.text();
  if (new TextEncoder().encode(raw).byteLength > MAX_BODY_BYTES) {
    return { ok: false, status: 413, erro: "Payload excede o tamanho permitido" };
  }

  let parsed: unknown;
  try {
    parsed = JSON.parse(raw);
  } catch {
    return { ok: false, status: 400, erro: "JSON inválido" };
  }

  if (!isRecord(parsed)) {
    return { ok: false, status: 400, erro: "O corpo deve ser um objeto JSON" };
  }

  // tenant_id may be present for backward compatibility, but is deliberately
  // ignored; the tenant authority always comes from the authenticated API key.
  const allowedFields = new Set(["nome", "email", "telefone", "tipo", "fonte", "notas", "tenant_id"]);
  const unexpectedField = Object.keys(parsed).find((field) => !allowedFields.has(field));
  if (unexpectedField) {
    return { ok: false, status: 400, erro: `Campo não permitido: ${unexpectedField}` };
  }

  if (typeof parsed.nome !== "string") {
    return { ok: false, status: 400, erro: "nome é obrigatório e deve ser texto" };
  }
  const nome = parsed.nome.trim();
  if (!nome) return { ok: false, status: 400, erro: "nome é obrigatório" };
  if (nome.length > MAX_NAME_LENGTH) {
    return { ok: false, status: 400, erro: "nome excede o tamanho permitido" };
  }

  const email = optionalText(parsed, "email", MAX_EMAIL_LENGTH);
  if (!email.ok) return { ok: false, status: 400, erro: email.erro };
  if (email.value && !isBasicEmail(email.value)) {
    return { ok: false, status: 400, erro: "email inválido" };
  }

  const telefone = optionalText(parsed, "telefone", MAX_PHONE_LENGTH);
  if (!telefone.ok) return { ok: false, status: 400, erro: telefone.erro };

  const notas = optionalText(parsed, "notas", MAX_NOTES_LENGTH);
  if (!notas.ok) return { ok: false, status: 400, erro: notas.erro };

  const tipo = parsed.tipo === undefined ? "lead" : parsed.tipo;
  if (typeof tipo !== "string" || !CONTACT_TYPES.includes(tipo as (typeof CONTACT_TYPES)[number])) {
    return { ok: false, status: 400, erro: "tipo inválido" };
  }

  const fonte = parsed.fonte === undefined ? "manual" : parsed.fonte;
  if (typeof fonte !== "string" || !CONTACT_SOURCES.includes(fonte as (typeof CONTACT_SOURCES)[number])) {
    return { ok: false, status: 400, erro: "fonte inválida" };
  }

  return {
    ok: true,
    value: {
      nome,
      email: email.value,
      telefone: telefone.value,
      tipo: tipo as ContactInput["tipo"],
      fonte: fonte as ContactInput["fonte"],
      notas: notas.value,
    },
  };
}

function idempotencyKeyFromRequest(req: Request): string | null {
  const key = req.headers.get("idempotency-key")?.trim();
  return key || null;
}

function routeForRateLimit(method: string, path: string): string | null {
  if (method === "GET" && (path.endsWith("/health") || path.endsWith("/"))) return "GET:/health";
  if (method === "GET" && path.endsWith("/contacts")) return "GET:/contacts";
  if (method === "POST" && path.endsWith("/contacts")) return "POST:/contacts";
  return null;
}

async function consumeRateLimit(
  admin: ReturnType<typeof createClient>,
  apiKeyId: string | null,
  tenantId: string | null,
  clientAddress: string,
  route: string,
): Promise<{ ok: true; value: RateLimitResult } | { ok: false }> {
  const ipHash = await sha256Hex(clientAddress);
  const { data, error } = await admin.rpc("consume_b2g_rate_limits", {
    p_api_key_id: apiKeyId,
    p_tenant_id: tenantId,
    p_ip_hash: ipHash,
    p_route: route,
    p_window_seconds: RATE_LIMIT_WINDOW_SECONDS,
  });
  if (error || !Array.isArray(data) || !data[0]) return { ok: false };
  return {
    ok: true,
    value: {
      allowed: Boolean(data[0].allowed),
      retry_after_seconds: Number(data[0].retry_after_seconds || 0),
      remaining: Number(data[0].remaining || 0),
    },
  };
}

function rateHeaders(rate: RateLimitResult): Record<string, string> {
  const headers: Record<string, string> = {
    "X-RateLimit-Remaining": String(Math.max(0, rate.remaining)),
  };
  if (!rate.allowed) headers["Retry-After"] = String(Math.max(1, rate.retry_after_seconds));
  return headers;
}

Deno.serve(async (req) => {
  const requestId = requestIdFrom(req);
  const startedAt = Date.now();
  const url = new URL(req.url);
  const caminho = url.pathname.replace(/\/+/g, "/");
  const route = routeForRateLimit(req.method, caminho);
  const clientAddress = clientAddressFromRequest(req);

  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });

  const finish = (
    body: unknown,
    status: number,
    extraHeaders: Record<string, string> = {},
  ): Response => {
    logEvent("request_completed", {
      request_id: requestId,
      method: req.method,
      route: caminho,
      status,
      duration_ms: Date.now() - startedAt,
    });
    return json(body, status, requestId, extraHeaders);
  };

  try {
    const supabaseUrl = Deno.env.get("SUPABASE_URL");
    const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
    if (!supabaseUrl || !serviceRoleKey) {
      logEvent("configuration_missing", { request_id: requestId, route: caminho });
      return finish({ erro: "Configuração interna ausente" }, 500);
    }

    const admin = createClient(supabaseUrl, serviceRoleKey, {
      auth: { persistSession: false, autoRefreshToken: false },
    });

    const chave = apiKeyFromRequest(req);
    if (!chave) {
      if (route) {
        const rate = await consumeRateLimit(admin, null, null, clientAddress, route);
        if (rate.ok && !rate.value.allowed) {
          logEvent("rate_limited", { request_id: requestId, route });
          return finish({ erro: "Muitas requisições" }, 429, rateHeaders(rate.value));
        }
      }
      logEvent("authentication_rejected", { request_id: requestId, reason: "api_key_missing" });
      return finish({ erro: "API key ausente" }, 401);
    }

    const chaveHash = await sha256Hex(chave);
    const { data: apiKey, error: keyError } = await admin
      .from("api_keys")
      .select("id, tenant_id")
      .eq("chave_hash", chaveHash)
      .eq("ativo", true)
      .is("revoked_at", null)
      .or(`expires_at.is.null,expires_at.gt.${new Date().toISOString()}`)
      .maybeSingle();
    if (keyError) {
      logEvent("dependency_failed", { request_id: requestId, dependency: "api_keys", operation: "lookup" });
      return finish({ erro: "Falha interna ao processar a requisição" }, 500);
    }

    if (!apiKey) {
      if (route) {
        const rate = await consumeRateLimit(admin, null, null, clientAddress, route);
        if (rate.ok && !rate.value.allowed) {
          logEvent("rate_limited", { request_id: requestId, route });
          return finish({ erro: "Muitas requisições" }, 429, rateHeaders(rate.value));
        }
      }
      logEvent("authentication_rejected", { request_id: requestId, reason: "api_key_invalid_or_expired" });
      return finish({ erro: "API key inválida ou expirada" }, 401);
    }

    if (route) {
      const rate = await consumeRateLimit(admin, apiKey.id, apiKey.tenant_id, clientAddress, route);
      if (!rate.ok) {
        logEvent("dependency_failed", { request_id: requestId, dependency: "api_rate_limit_buckets", operation: "consume" });
        return finish({ erro: "Falha interna ao processar a requisição" }, 503);
      }
      if (!rate.value.allowed) {
        logEvent("rate_limited", { request_id: requestId, route });
        return finish({ erro: "Muitas requisições" }, 429, rateHeaders(rate.value));
      }
    }

    const { error: usageError } = await admin
      .from("api_keys")
      .update({ ultimo_uso: new Date().toISOString() })
      .eq("id", apiKey.id);
    if (usageError) {
      logEvent("telemetry_update_failed", { request_id: requestId, operation: "api_key_last_used" });
    }

    if (req.method === "GET" && (caminho.endsWith("/health") || caminho.endsWith("/"))) {
      return finish({ ok: true }, 200);
    }

    if (caminho.endsWith("/contacts") && req.method === "GET") {
      const status = url.searchParams.get("status") || "ativo";
      const tipo = url.searchParams.get("tipo");
      if (!CONTACT_STATUSES.includes(status as (typeof CONTACT_STATUSES)[number])) {
        return finish({ erro: "status inválido" }, 400);
      }
      if (tipo && !CONTACT_TYPES.includes(tipo as (typeof CONTACT_TYPES)[number])) {
        return finish({ erro: "tipo inválido" }, 400);
      }

      let query = admin.from("contacts")
        .select("id, nome, email, telefone, tipo, status, fonte, criado_em, atualizado_em")
        .eq("tenant_id", apiKey.tenant_id)
        .eq("status", status);
      if (tipo) query = query.eq("tipo", tipo);
      const { data, error } = await query.order("criado_em", { ascending: false }).limit(100);
      if (error) {
        logEvent("dependency_failed", { request_id: requestId, dependency: "contacts", operation: "list" });
        return finish({ erro: "Falha interna ao processar a requisição" }, 500);
      }
      return finish({ contatos: data ?? [] }, 200);
    }

    if (caminho.endsWith("/contacts") && req.method === "POST") {
      const parsed = await parseContactBody(req);
      if (!parsed.ok) return finish({ erro: parsed.erro }, parsed.status);

      const idempotencyKey = idempotencyKeyFromRequest(req);
      if (idempotencyKey && (idempotencyKey.length < 8 || idempotencyKey.length > MAX_IDEMPOTENCY_KEY_LENGTH)) {
        return finish({ erro: "Idempotency-Key inválida" }, 400);
      }
      const idempotencyFingerprint = idempotencyKey
        ? await sha256Hex(JSON.stringify(parsed.value))
        : null;

      if (idempotencyKey) {
        const { data: existing, error: existingError } = await admin
          .from("contacts")
          .select(CONTACT_SELECT)
          .eq("tenant_id", apiKey.tenant_id)
          .eq("idempotency_key", idempotencyKey)
          .maybeSingle();
        if (existingError) {
          logEvent("dependency_failed", { request_id: requestId, dependency: "contacts", operation: "idempotency_lookup" });
          return finish({ erro: "Falha interna ao processar a requisição" }, 500);
        }
        if (existing) {
          if (existing.idempotency_fingerprint !== idempotencyFingerprint) {
            return finish({ erro: "Idempotency-Key já utilizada com outro payload" }, 409);
          }
          return finish({ contato: existing, idempotent_replay: true }, 200);
        }
      }

      const { data, error } = await admin.from("contacts").insert({
        tenant_id: apiKey.tenant_id,
        nome: parsed.value.nome,
        email: parsed.value.email,
        telefone: parsed.value.telefone,
        tipo: parsed.value.tipo,
        fonte: parsed.value.fonte,
        notas: parsed.value.notas,
        ...(idempotencyKey
          ? { idempotency_key: idempotencyKey, idempotency_fingerprint: idempotencyFingerprint }
          : {}),
      }).select("id, nome, email, telefone, tipo, status, fonte, criado_em, idempotency_key").single();
      if (error) {
        if (idempotencyKey && error.code === "23505") {
          const { data: raced } = await admin
            .from("contacts")
            .select(CONTACT_SELECT)
            .eq("tenant_id", apiKey.tenant_id)
            .eq("idempotency_key", idempotencyKey)
            .maybeSingle();
          if (raced && raced.idempotency_fingerprint === idempotencyFingerprint) {
            return finish({ contato: raced, idempotent_replay: true }, 200);
          }
          return finish({ erro: "Idempotency-Key já utilizada com outro payload" }, 409);
        }
        logEvent("dependency_failed", { request_id: requestId, dependency: "contacts", operation: "create" });
        return finish({ erro: "Falha interna ao processar a requisição" }, 500);
      }
      return finish({ contato: data }, 201);
    }

    return finish({ erro: "Endpoint não encontrado" }, 404);
  } catch {
    logEvent("request_failed", {
      request_id: requestId,
      method: req.method,
      route: caminho,
      duration_ms: Date.now() - startedAt,
    });
    return json({ erro: "Falha interna ao processar a requisição" }, 500, requestId);
  }
});
