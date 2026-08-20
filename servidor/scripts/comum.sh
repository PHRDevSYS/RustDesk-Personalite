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

# ---------------------------------------------------------------------------
# Dependencias do host. Falhar aqui e muito melhor que falhar no meio de um
# deploy. `ss` entra na lista porque o healthcheck decide o rollback a partir
# dele: sem `ss`, todas as portas seriam reportadas como fechadas e uma
# atualizacao boa seria revertida.
for _dep in docker git curl python3 ss; do
  if ! command -v "$_dep" >/dev/null 2>&1; then
    printf 'ERRO: "%s" nao encontrado no PATH. Instale antes de continuar.
' "$_dep" >&2
    exit 2
  fi
done
unset _dep

ENVDIR="$ROOT/ambientes/$AMBIENTE"
ENVFILE="$ENVDIR/.env"
COMPOSEFILE="$ROOT/servidor/compose.yml"
MANIFESTO="$ROOT/release/manifest.json"

# Branch que este ambiente acompanha — o nome do ambiente É o nome da branch.
BRANCH="$AMBIENTE"

# ---------------------------------------------------------------------------
# Provisionamento do ambiente. O teste de server.yaml usa -f (arquivo comum) de
# proposito: se o arquivo nao existir quando o compose subir, o Docker cria um
# DIRETORIO com esse nome, e o console falha depois com erro de parse sem
# nenhuma pista da causa.
if [ ! -f "$ENVFILE" ]; then
  printf 'ERRO: %s nao existe.
' "$ENVFILE" >&2
  printf '      cp %s/.env.example %s
' "$ENVDIR" "$ENVFILE" >&2
  exit 2
fi
if [ ! -f "$ENVDIR/config/server.yaml" ]; then
  if [ -d "$ENVDIR/config/server.yaml" ]; then
    printf 'ERRO: %s/config/server.yaml e um DIRETORIO.
' "$ENVDIR" >&2
    printf '      O Docker criou isso porque o compose subiu antes do arquivo existir.
' >&2
    printf '      Remova o diretorio e copie o .example antes de subir de novo.
' >&2
  else
    printf 'ERRO: %s/config/server.yaml nao existe.
' "$ENVDIR" >&2
    printf '      cp %s/config/server.yaml.example %s/config/server.yaml
' "$ENVDIR" "$ENVDIR" >&2
  fi
  exit 2
fi

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
