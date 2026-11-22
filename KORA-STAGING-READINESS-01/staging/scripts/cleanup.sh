#!/usr/bin/env bash
# Limpeza do stack DESCARTÁVEL: para os contêineres e APAGA volumes (sem backup).
# Não toca em nenhum recurso remoto. Para staging remoto, ver cleanup-remote.sql e
# PLANO-ROLLBACK.md (a limpeza preferida é excluir o projeto descartável inteiro).
set -euo pipefail
WORK="${KORA_STG_WORKDIR:-${RUNNER_TEMP:-/tmp}/kora-stg}"
SUPABASE_CLI_VERSION="${KORA_STG_SUPABASE_CLI_VERSION:-2.122.1}"
if [[ -f "$WORK/supabase/config.toml" ]]; then
  npx --yes "supabase@${SUPABASE_CLI_VERSION}" stop --workdir "$WORK" --no-backup || true
fi
# Contêineres/volumes remanescentes do projeto kora-stg (nomes supabase_<svc>_kora-stg).
docker ps -aq --filter "name=_kora-stg" | xargs -r docker rm -f >/dev/null || true
docker volume ls -q --filter "name=_kora-stg" | xargs -r docker volume rm >/dev/null || true
rm -f "$WORK/.stack.env" "$WORK/kora-stg.env" "$WORK/.state-"*.json
left_c=$(docker ps -aq --filter "name=_kora-stg" | wc -l)
left_v=$(docker volume ls -q --filter "name=_kora-stg" | wc -l)
echo "KORA-STG CLEANUP: contêineres remanescentes=$left_c volumes remanescentes=$left_v"
[[ "$left_c" == "0" && "$left_v" == "0" ]]
