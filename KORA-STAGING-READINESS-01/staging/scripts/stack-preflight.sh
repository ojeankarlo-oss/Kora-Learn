#!/usr/bin/env bash
# KORA-STAGING — pré-voo e diagnóstico do stack Docker local (PROVISIONING-04-DIAGNOSTIC).
#
# Contexto (run 45187500465): o `supabase start` falhou com
#   failed to bind host port 0.0.0.0:54322/tcp: address already in use
# Essa mensagem vem do bind() do próprio dockerd (EADDRINUSE do kernel), não do alocador
# de portas do Docker ("port is already allocated"). 54320-54329 ficam dentro da faixa
# efêmera padrão do Linux (32768-60999), usada como porta de ORIGEM de conexões de saída
# (ex.: pulls de imagem). Ver relatório PROVISIONING-04 (hipótese, não causa confirmada).
#
# Modos:
#   reserve     SOMENTE no GitHub Actions: inclui KORA_STG_STACK_PORTS em
#               net.ipv4.ip_local_reserved_ports, para que o kernel não as atribua
#               automaticamente a conexões de saída. bind() explícito (Docker) continua
#               funcionando. Idempotente. Fora do Actions não altera o host.
#   check       antes do `supabase start`: diagnóstico não sensível + FALHA FECHADA se
#               houver contêiner/volume remanescente do projeto, socket LISTEN nas portas,
#               ocupação que não se dissolva em KORA_STG_PORT_WAIT_SECS ou, no Actions,
#               reserva ausente.
#   postmortem  depois de falha do start: diagnóstico não sensível.
#
# Nunca mata processos, nunca remove contêineres/volumes (limpeza = cleanup.sh), nunca
# executa o start. Não imprime env nem logs de contêiner (docker inspect/logs expõem
# POSTGRES_PASSWORD/JWT_SECRET). Toda saída de diagnóstico passa pelo redact-log.mjs.
set -euo pipefail
export LC_ALL=C

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK="${KORA_STG_WORKDIR:-${RUNNER_TEMP:-/tmp}/kora-stg}"
PROJECT="${KORA_STG_PROJECT_ID:-kora-stg}"
PORTS="${KORA_STG_STACK_PORTS:-54320-54329}"
WAIT_SECS="${KORA_STG_PORT_WAIT_SECS:-120}"
RESERVED_FILE="/proc/sys/net/ipv4/ip_local_reserved_ports"
MODE="${1:-}"

if [[ ! "$PORTS" =~ ^([0-9]{4,5})-([0-9]{4,5})$ ]]; then
  echo "KORA-STG PREFLIGHT ABORT: KORA_STG_STACK_PORTS inválido (esperado N-M)"; exit 2
fi
P_LO=$((10#${BASH_REMATCH[1]})); P_HI=$((10#${BASH_REMATCH[2]}))
if (( P_LO < 1024 || P_HI > 65535 || P_LO > P_HI || P_HI - P_LO > 64 )); then
  echo "KORA-STG PREFLIGHT ABORT: faixa de portas fora dos limites (1024-65535, até 65 portas)"; exit 2
fi
if [[ ! "$WAIT_SECS" =~ ^[0-9]{1,4}$ ]]; then
  echo "KORA-STG PREFLIGHT ABORT: KORA_STG_PORT_WAIT_SECS inválido"; exit 2
fi

in_ci() { [[ "${GITHUB_ACTIONS:-}" == "true" ]]; }

# 0 se todas as portas P_LO..P_HI estão cobertas pela especificação "a,b-c,..." em $1.
spec_covers() {
  local spec="${1// /}" p a b part covered
  local -a parts=()
  IFS=',' read -ra parts <<< "$spec"
  for ((p = P_LO; p <= P_HI; p++)); do
    covered=0
    for part in "${parts[@]}"; do
      [[ -z "$part" ]] && continue
      [[ "$part" =~ ^[0-9]+(-[0-9]+)?$ ]] || continue
      if [[ "$part" == *-* ]]; then a=$((10#${part%-*})); b=$((10#${part#*-})); else a=$((10#$part)); b=$a; fi
      if (( p >= a && p <= b )); then covered=1; break; fi
    done
    (( covered )) || return 1
  done
  return 0
}

reserved_spec() { if [[ -r "$RESERVED_FILE" ]]; then tr -d '\n' < "$RESERVED_FILE"; fi; }

# Sockets TCP (qualquer estado, inclusive TIME-WAIT) com porta local na faixa.
# Falha do ss => return != 0 (o chamador aborta; saída vazia por erro nunca vale como "livre").
port_sockets() {
  local filter="( sport >= :$P_LO and sport <= :$P_HI )"
  if in_ci && sudo -n true 2>/dev/null; then
    sudo -n ss -Hantp "$filter"
  else
    ss -Hant "$filter"
  fi
}

# Falha de listagem => return 1 (o chamador aborta explicitamente; nunca conta como "zero").
project_containers() {
  local a b
  a="$(docker ps -aq --filter "label=com.supabase.cli.project=$PROJECT")" || return 1
  b="$(docker ps -aq --filter "name=_$PROJECT")" || return 1
  printf '%s\n%s\n' "$a" "$b" | sort -u | sed '/^$/d'
}
project_volumes() {
  local a b
  a="$(docker volume ls -q --filter "label=com.supabase.cli.project=$PROJECT")" || return 1
  b="$(docker volume ls -q --filter "name=_$PROJECT")" || return 1
  printf '%s\n%s\n' "$a" "$b" | sort -u | sed '/^$/d'
}

# Diagnóstico não sensível -> arquivo privado -> redigido -> stdout.
diag() {
  local title="$1" f
  mkdir -p "$WORK"
  f="$(umask 077 && mktemp "$WORK/.preflight-diag.XXXXXX")"
  {
    echo "== KORA-STG DIAG [$title]"
    echo "kernel: $(uname -r 2>/dev/null || echo '?')"
    echo "ip_local_port_range: $(tr -s '\t' ' ' 2>/dev/null < /proc/sys/net/ipv4/ip_local_port_range || echo '?')"
    echo "ip_local_reserved_ports: '$(reserved_spec)'"
    echo "faixa do stack: $P_LO-$P_HI"
    echo "docker: $(docker version --format 'client={{.Client.Version}} server={{.Server.Version}}' 2>/dev/null || echo 'indisponível')"
    echo "-- contêineres no host (nome | estado | status | portas)"
    docker ps -a --format '{{.Names}} | {{.State}} | {{.Status}} | {{.Ports}}' 2>/dev/null || true
    echo "-- volumes do projeto $PROJECT"
    project_volumes || true
    echo "-- redes do projeto $PROJECT"
    docker network ls --filter "name=$PROJECT" --format '{{.Name}}' 2>/dev/null || true
    echo "-- sockets TCP com porta local em $P_LO-$P_HI (estado | local | remoto | processo)"
    port_sockets || echo "(ss falhou)"
    echo "== fim do diagnóstico"
  } > "$f" 2>&1
  # Redator falhou => nada é impresso (nunca a versão bruta) e o arquivo é removido mesmo assim.
  node "$SCRIPT_DIR/redact-log.mjs" "$f" || echo "KORA-STG DIAG: redator falhou; diagnóstico suprimido"
  rm -f "$f"
}

case "$MODE" in
  reserve)
    if ! in_ci; then
      echo "KORA-STG PREFLIGHT: reserve ignorado fora do GitHub Actions (o host local não é alterado)"
      exit 0
    fi
    current="$(reserved_spec)"
    if spec_covers "$current"; then
      echo "KORA-STG PREFLIGHT: portas $P_LO-$P_HI já reservadas ('$current')"; exit 0
    fi
    new="${current:+$current,}$P_LO-$P_HI"
    sudo -n sysctl -q -w "net.ipv4.ip_local_reserved_ports=$new" >/dev/null
    after="$(reserved_spec)"
    if ! spec_covers "$after"; then
      echo "KORA-STG PREFLIGHT ABORT: reserva de $P_LO-$P_HI não aplicada ('$after')"; exit 1
    fi
    echo "KORA-STG PREFLIGHT: portas $P_LO-$P_HI reservadas contra atribuição efêmera ('$after')"
    ;;

  check)
    # Sem as ferramentas de observação a checagem seria vazia => falha fechada.
    command -v ss >/dev/null || { echo "KORA-STG PREFLIGHT ABORT: 'ss' ausente; ocupação de portas não verificável"; exit 1; }
    docker info >/dev/null 2>&1 || { echo "KORA-STG PREFLIGHT ABORT: daemon Docker inacessível"; exit 1; }
    diag "pré-start"
    if in_ci; then
      bash "$0" reserve
      spec_covers "$(reserved_spec)" || { echo "KORA-STG PREFLIGHT ABORT: reserva de portas ausente no Actions"; exit 1; }
    else
      echo "KORA-STG PREFLIGHT: fora do Actions a reserva de portas não é aplicada; apenas verificação"
    fi
    if ! cont="$(project_containers)" || ! vols="$(project_volumes)"; then
      echo "KORA-STG PREFLIGHT ABORT: falha ao listar contêineres/volumes do Docker"; exit 1
    fi
    n_c=$(grep -c . <<< "$cont" || true); n_v=$(grep -c . <<< "$vols" || true)
    if (( n_c > 0 || n_v > 0 )); then
      echo "KORA-STG PREFLIGHT ABORT: remanescentes do projeto $PROJECT (contêineres=$n_c volumes=$n_v); rode cleanup.sh antes"
      exit 1
    fi
    # Captura antes do grep: `cmd | grep -q` + pipefail pode mascarar o match via SIGPIPE.
    socks="$(port_sockets)" || { echo "KORA-STG PREFLIGHT ABORT: ss falhou; ocupação de portas não verificável"; exit 1; }
    # Casa LISTEN em qualquer coluna (robusto a uma coluna Netid em versões futuras do ss).
    if grep -Eq '(^|[[:space:]])LISTEN([[:space:]]|$)' <<< "$socks"; then
      echo "KORA-STG PREFLIGHT ABORT: há socket LISTEN em $P_LO-$P_HI (processo não é encerrado pelo harness)"
      exit 1
    fi
    waited=0
    while [[ -n "$socks" ]]; do
      if (( waited >= WAIT_SECS )); then
        echo "KORA-STG PREFLIGHT ABORT: portas $P_LO-$P_HI seguem ocupadas após ${WAIT_SECS}s"
        diag "ocupação persistente"
        exit 1
      fi
      if (( waited == 0 )); then echo "KORA-STG PREFLIGHT: sockets transitórios em $P_LO-$P_HI; aguardando liberação (máx. ${WAIT_SECS}s)"; fi
      sleep 2; waited=$((waited + 2))
      socks="$(port_sockets)" || { echo "KORA-STG PREFLIGHT ABORT: ss falhou; ocupação de portas não verificável"; exit 1; }
    done
    echo "KORA-STG PREFLIGHT: PASS (portas $P_LO-$P_HI livres após ${waited}s; remanescentes=0)"
    ;;

  postmortem)
    diag "pós-falha do start"
    ;;

  _test-covers)
    # Uso interno do static-selfcheck: _test-covers "<spec>" -> exit 0/1.
    spec_covers "${2:-}"
    ;;

  *)
    echo "uso: stack-preflight.sh reserve|check|postmortem"; exit 2
    ;;
esac
