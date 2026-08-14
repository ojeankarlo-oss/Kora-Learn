import { createClient } from "npm:@supabase/supabase-js@2.52.0";
import { interAccessToken, interRequest, withInterClient } from "../_shared/inter.ts";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });
}

function requireUuid(value: unknown): string {
  const texto = String(value || "");
  if (!/^[0-9a-f-]{36}$/i.test(texto)) throw new Error("tituloId inválido");
  return texto;
}

function novoTxid(): string {
  return `KORA${crypto.randomUUID().replaceAll("-", "").slice(0, 28)}`;
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  if (req.method !== "POST") return json({ erro: "Método não permitido" }, 405);

  const authHeader = req.headers.get("Authorization");
  if (!authHeader?.startsWith("Bearer ")) return json({ erro: "Autenticação obrigatória" }, 401);

  try {
    const { tituloId: tituloIdRaw } = await req.json();
    const tituloId = requireUuid(tituloIdRaw);
    const supabaseUrl = Deno.env.get("SUPABASE_URL");
    const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
    const anonKey = Deno.env.get("SUPABASE_ANON_KEY");
    if (!supabaseUrl || !serviceRoleKey || !anonKey) throw new Error("Secrets do Supabase ausentes");

    const userClient = createClient(supabaseUrl, anonKey, {
      global: { headers: { Authorization: authHeader } },
      auth: { persistSession: false, autoRefreshToken: false },
    });
    const { data: { user }, error: userError } = await userClient.auth.getUser();
    if (userError || !user) return json({ erro: "Sessão inválida" }, 401);

    const admin = createClient(supabaseUrl, serviceRoleKey, {
      auth: { persistSession: false, autoRefreshToken: false },
    });
    const { data: perfil, error: perfilError } = await admin
      .from("usuarios")
      .select("id, auth_user_id, tenant_id, perfil, nome")
      .eq("auth_user_id", user.id)
      .single();
    if (perfilError || !perfil) return json({ erro: "Perfil não encontrado" }, 403);

    const { data: titulo, error: tituloError } = await admin
      .from("titulos")
      .select("id, tenant_id, usuario_id, descricao, valor_centavos, data_vencimento, situacao")
      .eq("id", tituloId)
      .single();
    if (tituloError || !titulo) return json({ erro: "Título não encontrado" }, 404);
    if (titulo.tenant_id !== perfil.tenant_id) return json({ erro: "Título fora do tenant atual" }, 403);

    const staff = ["gestor", "super_admin"].includes(perfil.perfil);
    if (!staff && titulo.usuario_id !== perfil.id) return json({ erro: "Sem acesso a este título" }, 403);
    if (titulo.situacao !== "aberto") return json({ erro: "Somente títulos em aberto podem gerar Pix" }, 409);

    const { data: existente } = await admin
      .from("pix_cobrancas")
      .select("id, txid, location, pix_copia_e_cola, situacao, valor_centavos, expira_em")
      .eq("titulo_id", titulo.id)
      .maybeSingle();
    if (existente && existente.situacao === "criada" && (!existente.expira_em || new Date(existente.expira_em) > new Date())) {
      return json({ cobranca: existente, reutilizada: true });
    }

    const pix = await withInterClient(async (client, config) => {
      const token = await interAccessToken(config, client);
      const txid = novoTxid();
      const payload = await interRequest(config, client, token, `/pix/v2/cob/${txid}`, {
        method: "PUT",
        body: JSON.stringify({
          calendario: { expiracao: 3600 },
          valor: { original: (Number(titulo.valor_centavos) / 100).toFixed(2), modalidadeAlteracao: 0 },
          chave: config.pixKey,
          solicitacaoPagador: `Pagamento KORA — ${String(titulo.descricao).slice(0, 100)}`,
          infoAdicionais: [{ nome: "Referencia", valor: titulo.id }],
        }),
      });
      return { config, payload: payload as Record<string, unknown>, txid };
    });

    const banco = pix.payload;
    const location = String(banco.location || (banco.loc as Record<string, unknown> | undefined)?.location || "") || null;
    const pixCopiaECola = String(banco.pixCopiaECola || location || "") || null;
    const expiraEm = new Date(Date.now() + 3600 * 1000).toISOString();
    const { data: cobranca, error: insertError } = await admin
      .from("pix_cobrancas")
      .upsert({
        tenant_id: titulo.tenant_id,
        titulo_id: titulo.id,
        txid: pix.txid,
        chave: pix.config.pixKey,
        location,
        pix_copia_e_cola: pixCopiaECola,
        status_banco: String(banco.status || "ATIVA"),
        situacao: "criada",
        valor_centavos: titulo.valor_centavos,
        expira_em: expiraEm,
        resposta_banco: banco,
        erro: null,
        updated_at: new Date().toISOString(),
      }, { onConflict: "titulo_id" })
      .select("id, txid, location, pix_copia_e_cola, situacao, valor_centavos, expira_em")
      .single();
    if (insertError || !cobranca) throw insertError || new Error("Não foi possível salvar a cobrança Pix");

    return json({ cobranca, reutilizada: false });
  } catch (error) {
    console.error("pix-create", error);
    return json({ erro: error instanceof Error ? error.message : "Erro ao gerar Pix" }, 500);
  }
});
