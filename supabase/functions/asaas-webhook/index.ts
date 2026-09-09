import { createClient } from "npm:@supabase/supabase-js@2.52.0";

const corsHeaders = { "Access-Control-Allow-Origin": "*", "Access-Control-Allow-Headers": "content-type, asaas-access-token", "Access-Control-Allow-Methods": "POST, OPTIONS" };
function json(body: unknown, status = 200): Response { return new Response(JSON.stringify(body), { status, headers: { ...corsHeaders, "Content-Type": "application/json" } }); }
function env(name: string): string { const value = Deno.env.get(name)?.trim(); if (!value) throw new Error(`Secret ausente: ${name}`); return value; }
function constantTimeEqual(expected: string, received: string | null): boolean {
  if (!received) return false;
  const expectedBytes = new TextEncoder().encode(expected);
  const receivedBytes = new TextEncoder().encode(received);
  const length = Math.max(expectedBytes.length, receivedBytes.length);
  let difference = expectedBytes.length ^ receivedBytes.length;
  for (let index = 0; index < length; index += 1) difference |= (expectedBytes[index] || 0) ^ (receivedBytes[index] || 0);
  return difference === 0;
}
function cents(value: unknown): number {
  const text = String(value ?? "").trim().replace(",", ".");
  if (!/^\d+(?:\.\d{1,2})?$/.test(text)) throw new Error("Valor invalido");
  const [whole, fraction = ""] = text.split(".");
  const result = Number(whole) * 100 + Number(fraction.padEnd(2, "0"));
  if (!Number.isSafeInteger(result) || result <= 0) throw new Error("Valor invalido");
  return result;
}

Deno.serve(async (request) => {
  if (request.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  if (request.method !== "POST") return json({ error: "Metodo nao permitido" }, 405);
  const expected = env("ASAAS_WEBHOOK_SECRET");
  if (!constantTimeEqual(expected, request.headers.get("asaas-access-token"))) return json({ error: "Nao autorizado" }, 401);
  try {
    const url = env("SUPABASE_URL");
    const serviceKey = env("SUPABASE_SERVICE_ROLE_KEY");
    const payload = await request.json();
    const payment = payload?.payment;
    if (!payload?.event || !payment?.id || !payment?.externalReference) return json({ error: "Webhook invalido" }, 400);
    const admin = createClient(url, serviceKey, { auth: { persistSession: false, autoRefreshToken: false } });
    const invoiceId = String(payment.externalReference);
    const { data: invoice } = await admin.from("invoices").select("id, tenant_id").eq("id", invoiceId).maybeSingle();
    if (!invoice) return json({ error: "Invoice nao encontrada" }, 422);
    const { data: intent, error: intentError } = await admin.from("payment_intents").select("id, provider_account_id").eq("tenant_id", invoice.tenant_id).eq("invoice_id", invoice.id).eq("provider", "asaas").eq("is_canonical", true).maybeSingle();
    if (intentError || !intent?.provider_account_id) return json({ error: "Payment intent nao encontrada" }, 422);
    const { data, error } = await admin.rpc("process_asaas_webhook_atomic", {
      p_provider: "asaas", p_provider_account_id: intent.provider_account_id, p_payment_intent_id: intent.id,
      p_invoice_id: invoice.id, p_provider_payment_id: String(payment.id), p_event_type: String(payload.event),
      p_amount_cents: cents(payment.value), p_currency: String(payment.currency || "BRL"), p_payload: payload,
    });
    if (error) throw error;
    return json({ ok: true, result: data });
  } catch (error) {
    console.error("asaas-webhook", error instanceof Error ? error.message : "erro");
    return json({ error: "Falha ao processar webhook" }, 500);
  }
});
