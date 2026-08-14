import { createClient } from "npm:@supabase/supabase-js@2.52.0";

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json" },
  });
}

function valorEmCentavos(valor: unknown): number | null {
  const numero = Number(valor);
  return Number.isFinite(numero) && numero > 0 ? Math.round(numero * 100) : null;
}

function dataPagamento(horario: unknown): string {
  const data = horario ? new Date(String(horario)) : new Date();
  return Number.isNaN(data.getTime()) ? new Date().toISOString().slice(0, 10) : data.toISOString().slice(0, 10);
}

Deno.serve(async (req) => {
  if (req.method !== "POST") return json({ erro: "Método não permitido" }, 405);
  const tokenEsperado = Deno.env.get("PIX_WEBHOOK_TOKEN");
  const tokenRecebido = new URL(req.url).searchParams.get("token");
  if (!tokenEsperado || !tokenRecebido || tokenRecebido !== tokenEsperado) {
    return json({ erro: "Não autorizado" }, 401);
  }

  try {
    const supabaseUrl = Deno.env.get("SUPABASE_URL");
    const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
    if (!supabaseUrl || !serviceRoleKey) throw new Error("Secrets do Supabase ausentes");
    const admin = createClient(supabaseUrl, serviceRoleKey, {
      auth: { persistSession: false, autoRefreshToken: false },
    });

    const payload = await req.json();
    const eventos = Array.isArray(payload) ? payload : [payload];
    let processados = 0;
    let ignorados = 0;

    for (const evento of eventos) {
      const txid = String(evento?.txid || "").trim();
      const e2eidReal = String(evento?.endToEndId || "").trim();
      const valor = valorEmCentavos(evento?.valor ?? evento?.componentesValor?.original?.valor);
      const horario = evento?.horario || null;
      const chaveIdempotencia = e2eidReal || `${txid}:${String(horario || "")}:${String(evento?.valor || "")}`;
      if (!txid || !valor) {
        ignorados += 1;
        continue;
      }

      const { data: cobranca } = await admin
        .from("pix_cobrancas")
        .select("id, tenant_id, titulo_id, valor_centavos, situacao")
        .eq("txid", txid)
        .maybeSingle();
      if (!cobranca) {
        await admin.from("pix_eventos").insert({
          txid,
          end_to_end_id: chaveIdempotencia,
          valor_centavos: valor,
          payload: evento,
          erro: "Cobrança não encontrada para o txid",
          processado_em: new Date().toISOString(),
        });
        ignorados += 1;
        continue;
      }

      const { error: eventoError } = await admin.from("pix_eventos").insert({
        tenant_id: cobranca.tenant_id,
        txid,
        end_to_end_id: chaveIdempotencia,
        valor_centavos: valor,
        payload: evento,
      });
      if (eventoError?.code === "23505") {
        ignorados += 1;
        continue;
      }
      if (eventoError) throw eventoError;

      if (valor !== Number(cobranca.valor_centavos)) {
        await admin.from("pix_cobrancas").update({
          situacao: "erro",
          erro: `Valor recebido (${valor}) diferente do título (${cobranca.valor_centavos})`,
          updated_at: new Date().toISOString(),
        }).eq("id", cobranca.id);
        await admin.from("pix_eventos").update({
          erro: "Valor recebido diferente do título",
          processado_em: new Date().toISOString(),
        }).eq("txid", txid).eq("end_to_end_id", chaveIdempotencia);
        ignorados += 1;
        continue;
      }

      const { data: titulo } = await admin
        .from("titulos")
        .select("id, situacao")
        .eq("id", cobranca.titulo_id)
        .single();
      if (!titulo) throw new Error("Título associado não encontrado");

      if (titulo.situacao === "aberto") {
        const { error: baixaError } = await admin.from("titulos").update({
          situacao: "pago",
          data_pagamento: dataPagamento(horario),
          forma_pagamento: "pix",
          observacao: "Baixa automática confirmada pelo Banco Inter.",
        }).eq("id", titulo.id).eq("situacao", "aberto");
        if (baixaError) throw baixaError;
      }

      await admin.from("pix_cobrancas").update({
        situacao: "paga",
        status_banco: "CONCLUIDA",
        paga_em: horario ? new Date(String(horario)).toISOString() : new Date().toISOString(),
        end_to_end_id: e2eidReal || chaveIdempotencia,
        erro: null,
        updated_at: new Date().toISOString(),
      }).eq("id", cobranca.id);
      await admin.from("pix_eventos").update({
        processado_em: new Date().toISOString(),
      }).eq("txid", txid).eq("end_to_end_id", chaveIdempotencia);
      processados += 1;
    }

    return json({ ok: true, processados, ignorados });
  } catch (error) {
    console.error("pix-webhook", error);
    return json({ erro: "Falha ao processar callback" }, 500);
  }
});
