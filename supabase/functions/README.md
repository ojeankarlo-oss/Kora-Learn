# Edge Functions do Kora Learn

## Pix Banco Inter

As funções `pix-create` e `pix-webhook` implementam a Fase 7-B sem expor credenciais no navegador ou no GitHub.

Configure os secrets no projeto Supabase (Dashboard ou CLI), nunca em `.env` versionado:

| Secret | Uso |
|---|---|
| `INTER_CLIENT_ID` | Client ID da integração PJ do Inter |
| `INTER_CLIENT_SECRET` | Client Secret da integração PJ do Inter |
| `INTER_CERT_PEM` | Conteúdo PEM do certificado mTLS |
| `INTER_KEY_PEM` | Conteúdo PEM da chave privada mTLS |
| `INTER_PIX_KEY` | Chave Pix do recebedor cadastrada no Inter |
| `INTER_ACCOUNT` | Conta corrente, quando a integração tiver mais de uma |
| `INTER_ENV` | `sandbox` por padrão; use `producao` somente após homologação |
| `PIX_WEBHOOK_TOKEN` | Token aleatório para proteger a URL pública do callback |

A integração do Inter também precisa dos escopos `cob.write`, `cob.read`, `webhook.write`, `webhook.read` e `payloadlocation.read`.

## Deploy

A URL do callback deve ser HTTPS e pode ser cadastrada no Inter como:

```text
https://<PROJECT_REF>.supabase.co/functions/v1/pix-webhook?token=<PIX_WEBHOOK_TOKEN>
```

Depois de publicar a função, valide a URL no portal do desenvolvedor do Inter com um payload de exemplo antes de cadastrar o webhook definitivo. A chave Pix cadastrada no webhook deve ser a mesma de `INTER_PIX_KEY`.

O frontend chama `pix-create` autenticado. A função verifica a sessão, o tenant e se o usuário é o dono do título ou staff. O callback grava cada evento em `pix_eventos` e a baixa só ocorre quando o valor recebido coincide exatamente com `titulos.valor_centavos`.

## Validação local

Sem credenciais, é possível verificar a sintaxe com:

```bash
npx --yes deno check --node-modules-dir=auto \
  supabase/functions/_shared/inter.ts \
  supabase/functions/pix-create/index.ts \
  supabase/functions/pix-webhook/index.ts
```

O fluxo contra o Banco Inter deve ser homologado primeiro no Sandbox e somente depois configurado em produção. Certificados mTLS têm validade limitada e devem ser renovados antes da expiração.
