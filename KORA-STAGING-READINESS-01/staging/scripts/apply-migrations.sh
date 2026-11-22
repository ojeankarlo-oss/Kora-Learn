#!/usr/bin/env bash
# Aplica migrations canônicas, em ordem, no banco DESCARTÁVEL apontado por KORA_STG_DB_URL.
# Mesma validação de nomes e prefixos de .github/workflows/kora-payments-ci.yml.
# Nunca edita migrations; somente lê. Recusa alvo não-local (guard.mjs).
set -euo pipefail
export LC_ALL=C
MIGRATIONS_DIR="${1:?uso: apply-migrations.sh <dir-migrations>}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
: "${KORA_STG_DB_URL:?KORA_STG_DB_URL ausente}"
node "$SCRIPT_DIR/guard.mjs"

already=$(psql "$KORA_STG_DB_URL" -At -c "select to_regclass('public.tenants') is not null")
if [[ "$already" == "t" ]]; then
  echo "KORA-STG MIGRATIONS ABORT: schema público já possui tenants; alvo não está limpo"; exit 1
fi

mapfile -t migrations < <(find "$MIGRATIONS_DIR" -maxdepth 1 -type f -name '*.sql' -print | sort)
(( ${#migrations[@]} > 0 )) || { echo "KORA-STG MIGRATIONS: nenhuma migration"; exit 1; }
declare -A seen=()
for m in "${migrations[@]}"; do
  name=$(basename "$m")
  [[ "$name" =~ ^([0-9]{3})_[a-z0-9][a-z0-9_]*\.sql$ ]] || { echo "nome inválido: $name"; exit 1; }
  p=${BASH_REMATCH[1]}
  [[ -z "${seen[$p]:-}" ]] || { echo "prefixo duplicado $p"; exit 1; }
  seen[$p]=$name
done

# KORA-STAGING-PROVISIONING-02: identidade da execução (baseline x candidato).
# KORA_STG_EXPECT_LAST_MIGRATION fixa o último prefixo canônico esperado (baseline = 040).
# Divergência aborta: um baseline nunca pode incluir a 041 por acidente.
last_name=$(basename "${migrations[-1]}"); last_prefix=${last_name:0:3}
if [[ -n "${KORA_STG_EXPECT_LAST_MIGRATION:-}" && "$last_prefix" != "$KORA_STG_EXPECT_LAST_MIGRATION" ]]; then
  echo "KORA-STG MIGRATIONS ABORT: última migration canônica $last_name != esperado ${KORA_STG_EXPECT_LAST_MIGRATION}"; exit 1
fi
# Candidato (fase 4): UM arquivo fora de supabase/migrations, com SHA-256 fixado, prefixo
# imediatamente seguinte ao último canônico. Sem SHA fixado => aborta (nunca aplica às cegas).
if [[ -n "${KORA_STG_CANDIDATE_MIGRATION:-}" ]]; then
  : "${KORA_STG_CANDIDATE_SHA256:?KORA_STG_CANDIDATE_SHA256 obrigatório para candidato}"
  cand="$KORA_STG_CANDIDATE_MIGRATION"
  [[ -f "$cand" ]] || { echo "KORA-STG MIGRATIONS ABORT: candidato ausente: $cand"; exit 1; }
  cname=$(basename "$cand")
  [[ "$cname" =~ ^([0-9]{3})_[a-z0-9][a-z0-9_]*\.sql$ ]] || { echo "nome inválido (candidato): $cname"; exit 1; }
  want=$(printf '%03d' $((10#$last_prefix + 1)))
  [[ "${BASH_REMATCH[1]}" == "$want" ]] || { echo "KORA-STG MIGRATIONS ABORT: candidato $cname não é o prefixo $want"; exit 1; }
  got=$(sha256sum "$cand" | cut -d' ' -f1)
  [[ "$got" == "$KORA_STG_CANDIDATE_SHA256" ]] || { echo "KORA-STG MIGRATIONS ABORT: SHA-256 do candidato diverge ($got)"; exit 1; }
  echo "KORA-STG MIGRATIONS: candidato $cname sha256=$got (fora do diretório canônico)"
  migrations+=("$cand")
else
  echo "KORA-STG MIGRATIONS: baseline sem candidato (último canônico $last_name)"
fi

for m in "${migrations[@]}"; do
  echo "Applying $(basename "$m")"
  psql "$KORA_STG_DB_URL" -v ON_ERROR_STOP=1 -q -f "$m" >/dev/null
done
# PostgREST precisa recarregar o cache de schema após DDL fora do CLI.
psql "$KORA_STG_DB_URL" -v ON_ERROR_STOP=1 -q -c "notify pgrst, 'reload schema';"
sha=$(cat "${migrations[@]}" | sha256sum | cut -d' ' -f1)
echo "KORA-STG MIGRATIONS: PASS (${#migrations[@]} migrations, sha256(concat)=$sha)"
