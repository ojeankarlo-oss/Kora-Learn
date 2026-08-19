import { createClient } from "npm:@supabase/supabase-js@2";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-api-key, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "GET, POST, OPTIONS",
};

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });
}

function apiKeyFromRequest(req: Request): string | null {
  const direct = req.headers.get("x-api-key")?.trim();
  if (direct) return direct;
  const authorization = req.headers.get("authorization") || "";
  return authorization.startsWith("Bearer ") ? authorization.slice(7).trim() : null;
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });

  try {
    const supabaseUrl = Deno.env.get("SUPABASE_URL");
    const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
    if (!supabaseUrl || !serviceRoleKey) return json({ erro: "Configuração interna ausente" }, 500);

    const chave = apiKeyFromRequest(req);
    if (!chave) return json({ erro: "API key ausente" }, 401);

    const admin = createClient(supabaseUrl, serviceRoleKey, {
      auth: { persistSession: false, autoRefreshToken: false },
    });
    const { data: apiKey, error: keyError } = await admin
      .from("api_keys")
      .select("id, tenant_id")
      .eq("chave", chave)
      .eq("ativo", true)
      .or(`expires_at.is.null,expires_at.gt.${new Date().toISOString()}`)
      .maybeSingle();
    if (keyError) throw keyError;
    if (!apiKey) return json({ erro: "API key inválida ou expirada" }, 401);

    await admin.from("api_keys").update({ ultimo_uso: new Date().toISOString() }).eq("id", apiKey.id);

    const url = new URL(req.url);
    const caminho = url.pathname.replace(/\/+/g, "/");
    if (req.method === "GET" && (caminho.endsWith("/health") || caminho.endsWith("/"))) {
      return json({ ok: true });
    }

    if (caminho.endsWith("/contacts") && req.method === "GET") {
      const status = url.searchParams.get("status") || "ativo";
      const tipo = url.searchParams.get("tipo");
      let query = admin.from("contacts")
        .select("id, nome, email, telefone, tipo, status, fonte, criado_em, atualizado_em")
        .eq("tenant_id", apiKey.tenant_id)
        .eq("status", status);
      if (tipo) query = query.eq("tipo", tipo);
      const { data, error } = await query.order("criado_em", { ascending: false }).limit(100);
      if (error) throw error;
      return json({ contatos: data ?? [] });
    }

    if (caminho.endsWith("/contacts") && req.method === "POST") {
      const body = await req.json();
      if (!String(body?.nome || "").trim()) return json({ erro: "nome é obrigatório" }, 400);
      const { data, error } = await admin.from("contacts").insert({
        tenant_id: apiKey.tenant_id,
        nome: String(body.nome).trim(),
        email: body.email || null,
        telefone: body.telefone || null,
        tipo: body.tipo || "lead",
        fonte: body.fonte || "manual",
        notas: body.notas || null,
      }).select("id, nome, email, telefone, tipo, status, fonte, criado_em").single();
      if (error) throw error;
      return json({ contato: data }, 201);
    }

    return json({ erro: "Endpoint não encontrado" }, 404);
  } catch (error) {
    console.error("b2g-api", error);
    return json({ erro: "Falha interna ao processar a requisição" }, 500);
  }
});
