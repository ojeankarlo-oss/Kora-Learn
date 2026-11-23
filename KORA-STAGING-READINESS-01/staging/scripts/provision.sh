#!/usr/bin/env bash
# KORA-STAGING-READINESS-01 — provisiona stack Supabase DESCARTÁVEL (Docker) e aplica
# as migrations canônicas + fixtures sintéticas.
#
# Alvo: runner Linux efêmero (GitHub Actions ubuntu-latest) ou máquina Linux com >= 4 GB livres.
# NÃO executar no notebook de 8 GB (ver ARQUITETURA-STAGING.md §3).
# Exige autorização explícita: KORA_STG_CONFIRM=I_UNDERSTAND_DISPOSABLE
#
# Fases:
#   0. pré-checagens (confirmação, memória, ferramentas)
#   1. projeto Supabase temporário FORA do repositório; sobe stack mínimo SEM migrations
#      (gotrue, postgrest, storage, kong, db) para que Auth/Storage criem seus schemas
#   2. aplica supabase/migrations do repositório em ordem (mesma regra do CI atual)
#   3. cria usuários Auth sintéticos e o seed acadêmico; registra checksum
set -euo pipefail
export LC_ALL=C

: "${KORA_STG_CONFIRM:?Defina KORA_STG_CONFIRM=I_UNDERSTAND_DISPOSABLE para provisionar}"
if [[ "$KORA_STG_CONFIRM" != "I_UNDERSTAND_DISPOSABLE" ]]; then
  echo "KORA-STG PROVISION ABORT: confirmação inválida"; exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STG_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
REPO_ROOT="${KORA_STG_REPO_ROOT:-$(git -C "$STG_DIR" rev-parse --show-toplevel)}"
WORK="${KORA_STG_WORKDIR:-${RUNNER_TEMP:-/tmp}/kora-stg}"
SUPABASE_CLI_VERSION="${KORA_STG_SUPABASE_CLI_VERSION:-2.122.1}"
SB=(npx --yes "supabase@${SUPABASE_CLI_VERSION}")
EXCLUDE="${KORA_STG_EXCLUDE:-realtime,studio,imgproxy,edge-runtime,logflare,vector,supavisor,postgres-meta,mailpit}"
MIN_MEM_MB="${KORA_STG_MIN_MEM_MB:-4096}"

# ---- Fase 0 ---------------------------------------------------------------
for tool in docker psql node npx openssl git; do
  command -v "$tool" >/dev/null || { echo "KORA-STG PROVISION ABORT: ferramenta ausente: $tool"; exit 1; }
done
if [[ -r /proc/meminfo ]]; then
  avail_mb=$(awk '/MemAvailable/ {print int($2/1024)}' /proc/meminfo)
  echo "KORA-STG: memória disponível ${avail_mb} MB (mínimo ${MIN_MEM_MB} MB)"
  if (( avail_mb < MIN_MEM_MB )); then
    echo "KORA-STG PROVISION ABORT: memória insuficiente para o stack"; exit 1
  fi
fi
echo "KORA-STG: repo SHA $(git -C "$REPO_ROOT" rev-parse HEAD)"

# ---- Fase 1 ---------------------------------------------------------------
mkdir -p "$WORK"
cd "$WORK"
if [[ ! -f supabase/config.toml ]]; then
  "${SB[@]}" init --workdir "$WORK" >/dev/null
fi
CFG="$WORK/supabase/config.toml"
sed -i -E 's/^project_id = .*/project_id = "kora-stg"/' "$CFG"
# Volume de testes > limites padrão do GoTrue local; só afeta o stack descartável.
sed -i -E 's/^(sign_in_sign_ups|token_refresh|token_verifications) = .*/\1 = 1000/' "$CFG"
sed -i -E 's/^(enable_confirmations) = .*/\1 = false/' "$CFG"
rm -rf "$WORK/supabase/migrations" && mkdir -p "$WORK/supabase/migrations"
rm -f "$WORK/supabase/seed.sql"

umask 077
# PROVISIONING-03-FIX: `supabase start` imprime as chaves LOCAIS do stack (run 45041095243).
# A saída bruta vai para um arquivo privado no WORK (nunca em reports/, nunca no log);
# o log público recebe apenas a versão redigida, depois que todas as chaves foram mascaradas.
START_LOG="$WORK/.supabase-start.log"
if ! "${SB[@]}" start --workdir "$WORK" -x "$EXCLUDE" > "$START_LOG" 2>&1; then
  echo "KORA-STG PROVISION ABORT: supabase start falhou (saída redigida abaixo)"
  node "$SCRIPT_DIR/redact-log.mjs" "$START_LOG" | tail -n 120
  exit 1
fi

STACK_ENV="$WORK/.stack.env"
"${SB[@]}" status --workdir "$WORK" -o env > "$STACK_ENV"
if [[ -n "${GITHUB_ACTIONS:-}" ]]; then
  # Máscara de TODO valor sensível do stack (ANON/SERVICE_ROLE JWT, PUBLISHABLE/SECRET,
  # JWT_SECRET, S3_*), não só os que o harness usa.
  sed -n -E 's/^[A-Z0-9_]*(KEY|SECRET|PASSWORD|TOKEN)[A-Z0-9_]*="?([^"]+)"?$/\2/p' "$STACK_ENV" \
    | while IFS= read -r secretish; do if [[ -n "$secretish" ]]; then echo "::add-mask::$secretish"; fi; done
fi
node "$SCRIPT_DIR/redact-log.mjs" --secrets-env "$STACK_ENV" "$START_LOG"
read_var() { sed -n -E "s/^$1=\"?([^\"]*)\"?$/\1/p" "$STACK_ENV" | head -1; }
API_URL="$(read_var API_URL)"; DB_URL="$(read_var DB_URL)"
ANON_KEY="$(read_var ANON_KEY)"; SERVICE_ROLE_KEY="$(read_var SERVICE_ROLE_KEY)"
for v in API_URL DB_URL ANON_KEY SERVICE_ROLE_KEY; do
  [[ -n "${!v}" ]] || { echo "KORA-STG PROVISION ABORT: '$v' ausente em supabase status"; exit 1; }
done

FIXTURE_PASSWORD="${KORA_STG_FIXTURE_PASSWORD:-$(openssl rand -base64 24 | tr -d '/+=' )Aa1!}"
RUN_ID="${KORA_STG_RUN_ID:-$(date -u +%Y%m%d%H%M%S)-$RANDOM}"

STATE="$WORK/kora-stg.env"
cat > "$STATE" <<EOF
export KORA_STG_MODE=local
export KORA_STG_API_URL='$API_URL'
export KORA_STG_DB_URL='$DB_URL'
export KORA_STG_ANON_KEY='$ANON_KEY'
export KORA_STG_SERVICE_ROLE_KEY='$SERVICE_ROLE_KEY'
export KORA_STG_FIXTURE_PASSWORD='$FIXTURE_PASSWORD'
export KORA_STG_RUN_ID='$RUN_ID'
export KORA_STG_WORKDIR='$WORK'
EOF
if [[ -n "${GITHUB_ENV:-}" ]]; then
  for secretish in "$ANON_KEY" "$SERVICE_ROLE_KEY" "$FIXTURE_PASSWORD"; do echo "::add-mask::$secretish"; done
  sed -E 's/^export //; s/'"'"'//g' "$STATE" >> "$GITHUB_ENV"
fi
# shellcheck disable=SC1090
source "$STATE"
node "$SCRIPT_DIR/guard.mjs"

# ---- Fase 2 ---------------------------------------------------------------
bash "$SCRIPT_DIR/apply-migrations.sh" "$REPO_ROOT/supabase/migrations"

# ---- Fase 2b: regressão da trava do seed no banco REAL recém-migrado -------
# 12 cenários em subtransações desfeitas + ROLLBACK final; não deixa dados.
psql "$KORA_STG_DB_URL" -v ON_ERROR_STOP=1 -At -f "$STG_DIR/fixtures/seed_guard_regression.sql" \
  | tee "$WORK/seed-guard-regression.txt"
grep -q '^KORA_STG_SEED_GUARD|' "$WORK/seed-guard-regression.txt" \
  || { echo "KORA-STG PROVISION ABORT: regressão da trava do seed não produziu resultados"; exit 1; }
if grep -q '^KORA_STG_SEED_GUARD|FAIL' "$WORK/seed-guard-regression.txt"; then
  echo "KORA-STG PROVISION ABORT: regressão da trava do seed falhou"; exit 1
fi
if [[ -n "${KORA_STG_REPORT_DIR:-}" ]]; then
  mkdir -p "$KORA_STG_REPORT_DIR"
  cp "$WORK/seed-guard-regression.txt" "$KORA_STG_REPORT_DIR/seed-guard-regression.txt"
fi

# ---- Fase 3 ---------------------------------------------------------------
node "$SCRIPT_DIR/seed-auth.mjs"
psql "$KORA_STG_DB_URL" -v ON_ERROR_STOP=1 -At -f "$STG_DIR/fixtures/academic_seed.sql" \
  | tee "$WORK/seed-output.txt" | grep -E '^KORA_STG_FIXTURE_CHECKSUM\|' > "$WORK/checksum.txt"
echo "KORA-STG PROVISION: OK ($(cat "$WORK/checksum.txt"))"
echo "Estado local (contém chaves LOCAIS do stack; não publicar): $STATE"
