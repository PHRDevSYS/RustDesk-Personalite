# ============================================================================
# comum.sh — funções compartilhadas pelos scripts do servidor.
# Não executar diretamente; use `. "$(dirname "$0")/comum.sh"`.
# ============================================================================

# Raiz do repositório (este arquivo vive em servidor/scripts/).
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

# Ambiente alvo. Padrão intencionalmente homologação: errar para o lado seguro.
AMBIENTE="${AMBIENTE:-homologacao}"
case "$AMBIENTE" in
  homologacao|producao) ;;
  *) printf 'ERRO: AMBIENTE inválido "%s" (use homologacao ou producao)\n' "$AMBIENTE" >&2; exit 2 ;;
esac

ENVDIR="$ROOT/ambientes/$AMBIENTE"
ENVFILE="$ENVDIR/.env"
COMPOSEFILE="$ROOT/servidor/compose.yml"
MANIFESTO="$ROOT/release/manifest.json"

# Branch que este ambiente acompanha — o nome do ambiente É o nome da branch.
BRANCH="$AMBIENTE"

# docker compose sempre ancorado no diretório do ambiente: os caminhos relativos
# do compose.yml (./data-rustdesk, ./config) resolvem para dentro dele.
compose() {
  docker compose \
    --project-directory "$ENVDIR" \
    --env-file "$ENVFILE" \
    -f "$COMPOSEFILE" "$@"
}

# ID do container de um serviço; vazio se não estiver de pé.
cid() { compose ps -q "$1" 2>/dev/null | head -1; }

# Lê um campo do manifesto sem depender de jq.
manifesto_campo() {
  python3 - "$MANIFESTO" "$1" <<'PY' 2>/dev/null
import json, sys
d = json.load(open(sys.argv[1], encoding='utf-8-sig'))
for k in sys.argv[2].split('.'):
    d = d[k]
print(d)
PY
}

log() { printf '%s [%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "${2:-INFO}" "$1"; }
