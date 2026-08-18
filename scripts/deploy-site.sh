#!/bin/zsh
# Pushes site/ to the nus server (/srv/static/finedisplay). Never uses --delete.
# Usage: scripts/deploy-site.sh            # rsync site files
#        scripts/deploy-site.sh --caddy    # also install deploy/finedisplay.caddy (only if absent)
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
HOST="${DEPLOY_HOST:-nus}"
DEST="/srv/static/finedisplay"

ls site/dl/FineDisplay-*.zip >/dev/null 2>&1 || { echo "site/dl is empty — run scripts/build-app.sh && scripts/build-site.sh first"; exit 1; }

echo "▸ rsync site/ → $HOST:$DEST"
ssh "$HOST" "mkdir -p $DEST"
rsync -avz --no-perms --omit-dir-times site/ "$HOST:$DEST/"

if [[ "${1:-}" == "--caddy" ]]; then
  echo "▸ caddy block"
  if ssh "$HOST" "test -f /srv/edge/siteler/finedisplay.caddy"; then
    echo "  /srv/edge/siteler/finedisplay.caddy already exists on server — not touching it (multi-agent rule)."
  else
    scp deploy/finedisplay.caddy "$HOST:/srv/edge/siteler/finedisplay.caddy"
    echo "  installed (commented with #LIVE#). After the DNS A record resolves:"
    echo "    ssh $HOST 'sed -i \"s/^#LIVE#//\" /srv/edge/siteler/finedisplay.caddy && cd /srv/edge && docker compose exec caddy caddy validate --config /etc/caddy/Caddyfile && docker compose exec caddy caddy reload --config /etc/caddy/Caddyfile'"
  fi
fi
echo "✓ done"
