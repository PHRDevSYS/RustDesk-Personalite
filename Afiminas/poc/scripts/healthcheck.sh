#!/usr/bin/env bash
# ============================================================================
# healthcheck.sh — PoC Acesso Remoto Afiminas
# Retorno:  0 = OK   |   != 0 = ERROR (nº de falhas)
# Uso:      ./scripts/healthcheck.sh [-v]
# ============================================================================
set -uo pipefail

cd "$(dirname "$0")/.." || exit 99

VERBOSE=0
[ "${1:-}" = "-v" ] && VERBOSE=1

FAILURES=0
ok()   { printf '  [ OK ] %s\n' "$1"; }
fail() { printf '  [FAIL] %s\n' "$1"; FAILURES=$((FAILURES + 1)); }
warn() { printf '  [WARN] %s\n' "$1"; }
head_() { printf '\n== %s\n' "$1"; }

# ---------------------------------------------------------------------------
head_ "Containers"
for c in hbbs hbbr rustdesk-console; do
  status="$(docker inspect -f '{{.State.Status}}' "$c" 2>/dev/null)" || status="ausente"
  if [ "$status" = "running" ]; then
    restarts="$(docker inspect -f '{{.RestartCount}}' "$c" 2>/dev/null || echo 0)"
    if [ "${restarts:-0}" -gt 5 ]; then
      warn "$c running, mas com $restarts restarts (possível crash loop)"
    else
      ok "$c running"
    fi
  else
    fail "$c: $status"
  fi
done

# ---------------------------------------------------------------------------
head_ "Chaves do servidor"
if [ -f data-rustdesk/id_ed25519.pub ]; then
  ok "id_ed25519.pub presente"
  [ "$VERBOSE" -eq 1 ] && printf '         Key: %s\n' "$(cat data-rustdesk/id_ed25519.pub)"
else
  fail "data-rustdesk/id_ed25519.pub ausente — hbbs não inicializou"
fi
if [ -f data-rustdesk/id_ed25519 ]; then
  perm="$(stat -c '%a' data-rustdesk/id_ed25519 2>/dev/null || echo '?')"
  [ "$perm" = "600" ] || warn "id_ed25519 com permissão $perm (esperado 600)"
  ok "id_ed25519 presente (ATIVO CRÍTICO — garantir backup)"
else
  fail "data-rustdesk/id_ed25519 ausente"
fi

# ---------------------------------------------------------------------------
head_ "Portas em escuta"
listening_tcp() { ss -lnt 2>/dev/null | grep -q ":$1 "; }
listening_udp() { ss -lnu 2>/dev/null | grep -q ":$1 "; }

for p in 21115 21116 21117 21114; do
  if listening_tcp "$p"; then ok "TCP $p"; else fail "TCP $p não está em escuta"; fi
done
if listening_udp 21116; then ok "UDP 21116"; else fail "UDP 21116 não está em escuta"; fi

# Estas DEVEM estar fechadas no escopo enxuto (ver memoria.md §4)
for p in 21118 21119; do
  if listening_tcp "$p"; then
    warn "TCP $p em escuta — deveria estar fechada (risco de spoofing de X-Real-IP)"
  else
    ok "TCP $p fechada (esperado)"
  fi
done

# ---------------------------------------------------------------------------
head_ "Console HTTP"
code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 http://127.0.0.1:21114/ 2>/dev/null)" || code="000"
case "$code" in
  200|301|302|304) ok "console responde em :21114 (HTTP $code)" ;;
  000)             fail "console não respondeu em :21114 (timeout/conexão recusada)" ;;
  404)             fail "console respondeu HTTP 404 — provável staticdir errado (memoria.md §6, achado 2)" ;;
  *)               warn "console respondeu HTTP $code" ;;
esac

# ---------------------------------------------------------------------------
head_ "Banco do console"
if [ -f data-console/server.db ]; then
  ok "data-console/server.db presente (persistência funcionando)"
else
  fail "data-console/server.db ausente — volume /app/data não persistiu (memoria.md §6, achado 3)"
fi

# ---------------------------------------------------------------------------
head_ "Recursos do host"
disk="$(df -P . | awk 'NR==2{print $5}' | tr -d '%')"
if [ "${disk:-0}" -ge 90 ]; then fail "disco em ${disk}%"; else ok "disco em ${disk}%"; fi

if command -v free >/dev/null 2>&1; then
  memfree="$(free -m | awk '/^Mem:/{printf "%d", $7}')"
  if [ "${memfree:-0}" -lt 128 ]; then warn "memória disponível ${memfree}MB"; else ok "memória disponível ${memfree}MB"; fi
fi

# ---------------------------------------------------------------------------
printf '\n'
if [ "$FAILURES" -eq 0 ]; then
  printf 'RESULTADO: PASS\n'
  exit 0
else
  printf 'RESULTADO: FAIL (%d falha[s])\n' "$FAILURES"
  exit "$FAILURES"
fi
