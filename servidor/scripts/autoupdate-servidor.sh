#!/usr/bin/env bash
# ============================================================================
# autoupdate-servidor.sh — AzureControlDesk
#
# Aplica no servidor a versão publicada na branch do ambiente. Roda no boot
# (systemd) e periodicamente (timer). Fluxo:
#
#   fetch -> há novidade? -> guarda estado de rollback -> reset --hard
#   -> lê release/manifest.json -> compose pull/up -d -> healthcheck
#   -> PASS: confirma  |  FAIL: rollback para o commit anterior
#
# O rollback é o ponto central: uma atualização que quebra o healthcheck
# NÃO fica de pé. Sem ele, o auto-update seria um jeito automatizado de
# derrubar o ambiente.
#
# Uso:   AMBIENTE=producao ./servidor/scripts/autoupdate-servidor.sh [--forcar]
# Saída: 0 = nada a fazer ou atualizado com sucesso
#        1 = falhou e voltou ao estado anterior (rollback OK)
#        2 = erro de configuração
#        9 = FALHA CRÍTICA: rollback também falhou (exige intervenção)
# ============================================================================
set -uo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/comum.sh"

FORCAR=0
[ "${1:-}" = "--forcar" ] && FORCAR=1

LOCK="/tmp/azuredesk-autoupdate-$AMBIENTE.lock"
exec 9>"$LOCK" || exit 2
if ! flock -n 9; then
  log "outra execução do auto-update já está em andamento — saindo" WARN
  exit 0
fi

[ -f "$ENVFILE" ] || { log "ambientes/$AMBIENTE/.env não existe — servidor não provisionado" ERRO; exit 2; }

log "=== auto-update iniciado (ambiente: $AMBIENTE, branch: $BRANCH) ==="

# --------------------------------------------------------------- há novidade?
if ! git -C "$ROOT" fetch --quiet --prune origin "$BRANCH"; then
  log "git fetch falhou — sem rede ou sem acesso ao remoto. Nada alterado." ERRO
  exit 1
fi

ATUAL="$(git -C "$ROOT" rev-parse HEAD)"
NOVO="$(git -C "$ROOT" rev-parse "origin/$BRANCH")"

if [ "$ATUAL" = "$NOVO" ] && [ "$FORCAR" -eq 0 ]; then
  log "já em $(git -C "$ROOT" rev-parse --short HEAD) — nada a fazer"
  exit 0
fi

# ------------------------------------------------- estado de rollback (antes)
IMG_SERVER_ANTES="$(manifesto_campo servidor.rustdesk_server_image)"
IMG_CONSOLE_ANTES="$(manifesto_campo servidor.console_image)"
VER_ANTES="$(manifesto_campo versao)"
log "estado atual: versão ${VER_ANTES:-?} em ${ATUAL:0:7}"

# ------------------------------------------------------------------ aplicar
log "aplicando ${NOVO:0:7} da branch $BRANCH"
if ! git -C "$ROOT" reset --hard --quiet "$NOVO"; then
  log "git reset falhou — nada alterado" ERRO
  exit 1
fi

VER_DEPOIS="$(manifesto_campo versao)"

export RUSTDESK_SERVER_IMAGE="$(manifesto_campo servidor.rustdesk_server_image)"
export CONSOLE_IMAGE="$(manifesto_campo servidor.console_image)"

if [ -z "$RUSTDESK_SERVER_IMAGE" ] || [ -z "$CONSOLE_IMAGE" ]; then
  log "manifesto sem imagens definidas — abortando" ERRO
  git -C "$ROOT" reset --hard --quiet "$ATUAL"
  exit 2
fi

log "versão ${VER_DEPOIS:-?} | hbbs/hbbr: $RUSTDESK_SERVER_IMAGE | console: $CONSOLE_IMAGE"

subir() {
  compose pull --quiet 2>&1 | sed 's/^/    /'
  compose up -d --remove-orphans 2>&1 | sed 's/^/    /'
}

validar() {
  # O console leva alguns segundos para abrir a porta; tenta por até ~60s.
  local tentativa
  for tentativa in 1 2 3 4 5 6; do
    sleep 10
    if AMBIENTE="$AMBIENTE" bash "$ROOT/servidor/scripts/healthcheck.sh" >/tmp/azuredesk-hc-$AMBIENTE.log 2>&1; then
      return 0
    fi
  done
  sed 's/^/    /' /tmp/azuredesk-hc-$AMBIENTE.log
  return 1
}

subir
if validar; then
  printf '%s\n' "$VER_DEPOIS" > "$ENVDIR/.versao-aplicada"
  log "=== atualizado para ${VER_DEPOIS:-?} (${NOVO:0:7}) — healthcheck PASS ==="
  exit 0
fi

# ------------------------------------------------------------------ rollback
log "healthcheck FALHOU após a atualização — revertendo para ${ATUAL:0:7}" ERRO
git -C "$ROOT" reset --hard --quiet "$ATUAL"
export RUSTDESK_SERVER_IMAGE="$IMG_SERVER_ANTES"
export CONSOLE_IMAGE="$IMG_CONSOLE_ANTES"
subir

if validar; then
  log "=== rollback concluído: de volta em ${VER_ANTES:-?}. A versão ${VER_DEPOIS:-?} NÃO foi aplicada. ===" WARN
  exit 1
fi

log "=== FALHA CRÍTICA: rollback também não passou no healthcheck. Ambiente $AMBIENTE precisa de intervenção manual. ===" ERRO
exit 9
