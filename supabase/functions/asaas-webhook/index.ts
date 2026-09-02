import { createClient } from "npm:@supabase/supabase-js@2.52.0";

const corsHeaders = { "Access-Control-Allow-Origin": "*", "Access-Control-Allow-Headers": "content-type, asaas-access-token", "Access-Control-Allow-Methods": "POST, OPTIONS" };
function json(body: unknown, status = 200): Response { return new Response(JSON.stringify(body), { status, headers: { ...corsHeaders, "Content-Type": "application/json" } }); }
function env(name: string): string { const value = Deno.env.get(name)?.trim(); if (!value) throw new Error(`Secret ausente: ${name}`); return value; }
function cents(value: unknown): number { const result = Math.round(Number(value) * 100); if (!Number.isSafeInteger(result) || result <= 0) throw new Error("Valor invalido"); return result; }

Deno.serve(async (request) => {
  if (request.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  if (request.method !== "POST") return json({ error: "Metodo nao permitido" }, 405);
  const expected = env("ASAAS_WEBHOOK_SECRET");
  if (request.headers.get("asaas-access-token") !== expected) return json({ error: "Nao autorizado" }, 401);
  try {
    const url = env("SUPABASE_URL");
    const serviceKey = env("SUPABASE_SERVICE_ROLE_KEY");
    const payload = await request.json();
    const payment = payload?.payment;
    if (!payload?.event || !payment?.id || !payment?.externalReference) return json({ error: "Webhook invalido" }, 400);
    const admin = createClient(url, serviceKey, { auth: { persistSession: false, autoRefreshToken: false } });
    const eventId = `${String(payment.id)}:${String(payload.event)}`;
    const { data: event, error: eventError } = await admin.from("webhook_events").insert({ provider: "asaas", provider_event_id: eventId, event_type: payload.event, payload }).select("id").maybeSingle();
    if (eventError?.code === "23505") return json({ ok: true, duplicate: true });
    if (eventError || !event) throw eventError || new Error("Evento nao registrado");
    const invoiceId = String(payment.externalReference);
    const { data: invoice } = await admin.from("invoices").select("id, tenant_id, billing_account_id, amount_cents, status").eq("id", invoiceId).maybeSingle();
    if (!invoice || cents(payment.value) !== Number(invoice.amount_cents)) return json({ error: "Invoice ou valor nao corresponde" }, 422);
    if (["PAYMENT_RECEIVED", "PAYMENT_CONFIRMED"].includes(String(payload.event)) && invoice.status === "open") {
      const { error } = await admin.from("payments").insert({ billing_account_id: invoice.billing_account_id, tenant_id: invoice.tenant_id, invoice_id: invoice.id, provider: "asaas", provider_payment_id: payment.id, amount_cents: invoice.amount_cents });
      if (error?.code !== "23505" && error) throw error;
      const { error: updateError } = await admin.from("invoices").update({ status: "paid", paid_at: new Date().toISOString() }).eq("id", invoice.id).eq("status", "open");
      if (updateError) throw updateError;
    }
    await admin.from("webhook_events").update({ processed_at: new Date().toISOString() }).eq("id", event.id);
    return json({ ok: true });
  } catch (error) {
    console.error("asaas-webhook", error instanceof Error ? error.message : "erro");
    return json({ error: "Falha ao processar webhook" }, 500);
  }
});