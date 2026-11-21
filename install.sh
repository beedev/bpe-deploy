#!/usr/bin/env bash
# PromoEngine POC: install or upgrade on a Mac or a Linux server, with Docker.
#
#   curl -fsSLo install.sh https://raw.githubusercontent.com/beedev/bpe-deploy/main/install.sh
#   bash install.sh                                 # this computer: http://localhost:8380/bpe
#   bash install.sh https://idea.htcindia.com/bpe   # a server, behind its HTTPS web proxy (nginx)
#
# What it does, every run (running it again is how you upgrade; the demo data is kept):
#   1. Checks Docker and Docker Compose v2 are installed and running.
#   2. Downloads the configuration (this repository) into ~/bpe, keeping your .env there.
#   3. Works out the addresses from the one address you give and writes them to .env.
#   4. Makes the secrets this installation needs (database, sign-in, the demo people's password), once, into .env.
#   5. Chooses a free port for the stack, on 127.0.0.1 only.
#   6. Pulls the images and starts the stack, then waits until every part is healthy and the demo data is in.
#   7. Prints the addresses and where to read the password; for a server, the nginx lines to add.
#
# Settings (all optional, as environment variables):
#   BPE_HOME=~/bpe            where it installs
#   BPE_PORT=8380             the one port the stack listens on (127.0.0.1). A port set once is kept in .env for upgrades;
#                             on a first install a taken port moves to the next free one, unless you set BPE_PORT yourself.
#   BPE_TAG=latest            which image version to run (for example 2026.11.21-694f284)
#   REPO=beedev/bpe-deploy  BRANCH=main      where the configuration comes from
#   NO_DOWNLOAD=1             use the files already in BPE_HOME (testing a local copy)
#   NO_PULL=1                 use images already on this machine (a rehearsal with BPE_TAG=local; see the README)
#   NO_OPEN=1                 do not open the browser at the end (Mac)
set -euo pipefail

ARG="${1:-${BPE_ADDRESS:-}}"
HOME_DIR="${BPE_HOME:-$HOME/bpe}"
REPO="${REPO:-beedev/bpe-deploy}"
BRANCH="${BRANCH:-main}"
DEFAULT_PORT=8380
APP_PATH=/bpe

if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then B=$'\033[1m'; G=$'\033[32m'; R=$'\033[31m'; Y=$'\033[33m'; N=$'\033[0m'; else B=''; G=''; R=''; Y=''; N=''; fi
step() { printf '\n%s[%s]%s %s\n' "$B" "$1" "$N" "$2"; }
ok()   { printf '  %s✓%s %s\n' "$G" "$N" "$1"; }
warn() { printf '  %s!%s %s\n' "$Y" "$N" "$1"; }
die()  { printf '\n%s✗ %s%s\n' "$R" "$1" "$N" >&2; exit 1; }

envf="$HOME_DIR/.env"
# A value an earlier install wrote to .env.
kept() { grep -E "^$1=" "$envf" 2>/dev/null | tail -1 | cut -d= -f2- || true; }
# One line per setting in .env; anything else you put there is kept.
set_env() {
  local key="$1" value="$2"
  { grep -v -E "^$key=" "$envf" || true; } > "$envf.tmp"
  printf '%s=%s\n' "$key" "$value" >> "$envf.tmp"
  mv "$envf.tmp" "$envf"
}
# 24 random letters and digits (about 140 bits), the same shape scripts/gen_local_files.py makes.
secret() { LC_ALL=C tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 24 || true; }
in_use() { (exec 3<>"/dev/tcp/127.0.0.1/$1") 2>/dev/null; }

# ---- 1. Docker -------------------------------------------------------------------------------------------------------------
step 1/7 "Docker"
os="$(uname -s)"
if ! command -v docker >/dev/null 2>&1; then
  if [ "$os" = Darwin ]; then die "Docker is not installed. Install Docker Desktop from https://www.docker.com/products/docker-desktop/, start it, then run this again."; fi
  die "Docker is not installed. Install Docker Engine and the Compose plugin (https://docs.docker.com/engine/install/), then run this again."
fi
docker info >/dev/null 2>&1 || die "Docker is installed but not running, or this user may not use it. Start Docker$([ "$os" = Darwin ] && echo ' Desktop'), or add yourself to the docker group, then run this again."
docker compose version >/dev/null 2>&1 || die "Docker Compose v2 is missing (the 'docker compose' command). Install the Compose plugin, then run this again."
mem=$(docker info --format '{{.MemTotal}}' 2>/dev/null || echo 0)
if [ "$mem" -gt 0 ] && [ "$mem" -lt 5500000000 ]; then
  warn "Docker has $((mem / 1000000000)) GB of memory; the stack (five Java services, Keycloak, PostgreSQL, two web apps) needs about 6 GB.$([ "$os" = Darwin ] && echo ' Raise it in Docker Desktop, Settings, Resources.')"
fi
ok "Docker $(docker version --format '{{.Server.Version}}' 2>/dev/null), $(docker compose version --short 2>/dev/null)"

# ---- 2. The configuration --------------------------------------------------------------------------------------------------
step 2/7 "Configuration in $HOME_DIR"
mkdir -p "$HOME_DIR"
if [ -z "${NO_DOWNLOAD:-}" ]; then
  command -v curl >/dev/null 2>&1 || die "curl is needed to download the configuration."
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' EXIT
  curl -fsSL "https://codeload.github.com/$REPO/tar.gz/refs/heads/$BRANCH" | tar -xz -C "$tmp" --strip-components=1 \
    || die "Could not download https://github.com/$REPO ($BRANCH)."
  # Everything is replaced except your .env.
  rm -rf "$HOME_DIR/config"
  for item in config docker-compose.yml README.md install.sh; do cp -R "$tmp/$item" "$HOME_DIR/"; done
fi
[ -f "$HOME_DIR/docker-compose.yml" ] || die "$HOME_DIR has no docker-compose.yml."
# The containers run as other users and must be able to read these files.
chmod -R go+rX "$HOME_DIR/config"
touch "$envf"
chmod 600 "$envf"
ok "configuration from github.com/$REPO ($BRANCH)"

# ---- 3. The address --------------------------------------------------------------------------------------------------------
step 3/7 "Address"
port_pinned=false
[ -n "${BPE_PORT:-}" ] && port_pinned=true
BPE_PORT="${BPE_PORT:-$(kept BPE_PORT)}"
if [ -z "$ARG" ]; then ARG="http://localhost:${BPE_PORT:-$DEFAULT_PORT}$APP_PATH"; fi
ARG="${ARG%/}"
case "$ARG" in http://*|https://*) ;; *) die "The address must start with http:// or https://, for example https://idea.htcindia.com/bpe" ;; esac
rest="${ARG#*://}"
host="${rest%%/*}"
path=""; [ "$rest" != "$host" ] && path="/${rest#*/}"
case "$path" in ""|"$APP_PATH") ;; *) die "The app is built for the path $APP_PATH (the images fix it). Give the address without a path or ending in $APP_PATH, for example https://${host}$APP_PATH" ;; esac
local_run=false
case "$host" in localhost|localhost:*) local_run=true ;; esac
if $local_run; then
  if [ "$host" != localhost ]; then BPE_PORT="${host#localhost:}"; port_pinned=true; fi
else
  [ "${ARG%%://*}" = https ] || die "A server address must be https:// (the sign-in cookie is sent only over HTTPS)."
  case "$host" in *:*) die "Give the server's address without a port; its nginx answers on 443 and passes the paths to this stack." ;; esac
fi
BPE_PORT="${BPE_PORT:-$DEFAULT_PORT}"
case "$BPE_PORT" in ''|*[!0-9]*) die "BPE_PORT must be a number, not '$BPE_PORT'." ;; esac

cd "$HOME_DIR"
# On a first install .env is not complete yet and compose refuses to read the file: that counts as nothing running.
running="$( (docker compose ps -q 2>/dev/null || true) | wc -l | tr -d ' ')"

# The port is chosen here, before the addresses are written, because a computer's address contains it. It is chosen only
# when the stack is not running (or starts fresh); a running stack keeps its port.
pick_port() {
  local p="$BPE_PORT"
  if ! in_use "$p"; then echo "$p"; return; fi
  $port_pinned && die "Port $p is in use by another program. Stop it, or run with another one, for example: BPE_PORT=$((p + 1)) bash install.sh ${1:-}"
  local i
  for i in $(seq 1 100); do
    if ! in_use "$((p + i))"; then echo "$((p + i))"; return; fi
  done
  die "No free port between $p and $((p + 100)). Choose one: BPE_PORT=<port> bash install.sh ${1:-}"
}
before="$(kept BPE_ORIGIN)"
if $local_run; then origin_guess="http://localhost:$BPE_PORT"; else origin_guess="https://$host"; fi
fresh=false
if [ -n "$before" ] && [ "$before" != "$origin_guess" ] && ! $local_run; then fresh=true; fi
if [ "$running" = 0 ] || $fresh; then
  chosen="$(pick_port "$ARG")"
  [ "$chosen" = "$BPE_PORT" ] || warn "port $BPE_PORT is taken; using $chosen"
  BPE_PORT="$chosen"
fi
if $local_run; then ORIGIN="http://localhost:$BPE_PORT"; else ORIGIN="https://$host"; fi
if [ -n "$before" ] && [ "$before" != "$ORIGIN" ]; then
  # Keycloak reads the allowed sign-in return address only at its first import, so a new address needs fresh volumes.
  warn "The address changed from $before to $ORIGIN; the stack starts fresh and the demo data is made again."
  fresh=true
fi

set_env BPE_ORIGIN "$ORIGIN"
set_env BPE_URL "$ORIGIN$APP_PATH"
set_env BPE_SHOP_URL "$ORIGIN/bpe-shop"
set_env BPE_KEYCLOAK_URL "$ORIGIN/bpe-keycloak"
set_env BPE_API_URL "$ORIGIN/bpe-api"
set_env BPE_PORT "$BPE_PORT"
[ -n "${BPE_TAG:-}" ] && set_env BPE_TAG "$BPE_TAG"
ok "admin web $ORIGIN$APP_PATH, shop $ORIGIN/bpe-shop, sign-in $ORIGIN/bpe-keycloak"

# ---- 4. Secrets: made once on this machine, kept in .env (mode 600), never printed. ------------------------------------------
step 4/7 "Secrets"
made=0
for key in DB_OWNER_PASSWORD KEYCLOAK_ADMIN_PASSWORD TEST_USER_PASSWORD PROMO_ADMINISTRATION_CLIENT_SECRET PROMO_SEED_CLIENT_SECRET \
           SVC_PRICING_ENGINE_PASSWORD SVC_PROMOTION_AUTHORING_PASSWORD SVC_CATALOG_PASSWORD SVC_ADMINISTRATION_PASSWORD SVC_AI_ASSIST_PASSWORD; do
  if [ -z "$(kept "$key")" ]; then
    value="$(secret)"
    [ "${#value}" -eq 24 ] || die "Could not make a random secret (no /dev/urandom?)."
    set_env "$key" "$value"
    made=$((made + 1))
  fi
done
[ -n "$(kept DB_OWNER_USER)" ] || set_env DB_OWNER_USER postgres
[ -n "$(kept KEYCLOAK_ADMIN)" ] || set_env KEYCLOAK_ADMIN admin
# A local test value, as in scripts/gen_local_files.py: the planning documents give no connection budget.
[ -n "$(kept DB_CONNECTION_LIMIT)" ] || set_env DB_CONNECTION_LIMIT 10
# The assistant answers from the live model when a key is here, from recorded answers otherwise (the owner's decision).
if [ -n "$(kept OPENAI_API_KEY)" ]; then set_env PROMO_AI_MODE live; ai="live (OPENAI_API_KEY is in .env)"; else set_env PROMO_AI_MODE stub; ai="stub: recorded answers (no OPENAI_API_KEY in .env)"; fi
chmod 600 "$envf"
ok "$made new, the rest kept, in $envf (readable by you only)"
ok "assistant: $ai"

# ---- 5. Ports --------------------------------------------------------------------------------------------------------------
step 5/7 "Port"
if [ "$running" = 0 ] || $fresh; then
  if $fresh; then docker compose down -v --remove-orphans >/dev/null 2>&1 || true; fi
  ok "$BPE_PORT is free; the stack listens on 127.0.0.1:$BPE_PORT only"
else
  ok "the stack is already running on 127.0.0.1:$BPE_PORT; it is upgraded in place"
fi

# ---- 6. Start --------------------------------------------------------------------------------------------------------------
step 6/7 "Images and start (the first time takes several minutes: the demo data is made through the real workflow)"
if [ -z "${NO_PULL:-}" ]; then docker compose pull --quiet || die "Could not pull the images from ghcr.io."; fi
docker compose up -d --wait --wait-timeout 900 || {
  docker compose ps -a
  die "Not every part became healthy. See which with 'docker compose ps -a' and why with 'docker compose logs <name>' (in $HOME_DIR); the demo data job is 'seed'."
}
ok "all parts healthy, demo data in"

# ---- 7. Done ---------------------------------------------------------------------------------------------------------------
step 7/7 "Ready"
printf '\n  Admin web   %s%s%s%s\n  Storefront  %s/bpe-shop\n  Sign-in     %s/bpe-keycloak\n' "$B" "$ORIGIN" "$APP_PATH" "$N" "$ORIGIN" "$ORIGIN"
printf '\n  Sign in as mortiz (merchandiser), dpatel (approver), rgomez (site admin), areed (super admin) or au1 (auditor).\n'
printf '  The password is made for this installation only. Read it with:\n    grep ^TEST_USER_PASSWORD= %s | cut -d= -f2\n' "$envf"
printf '  Stop: cd %s && docker compose down    (add -v to wipe the demo data)\n' "$HOME_DIR"
if ! $local_run; then
  cat <<NGINX

  This server's HTTPS web proxy (nginx) must pass the /bpe paths to the stack. Inside the server block for $host,
  before any other regular-expression location that could match /bpe:

    location ~ ^/bpe(-shop|-keycloak|-api)?(/|\$) {
        proxy_pass http://127.0.0.1:$BPE_PORT;
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Forwarded-Proto https;
        proxy_set_header X-Forwarded-Host \$host;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection \$http_connection;
        proxy_buffer_size 128k;
        proxy_buffers 4 256k;
        proxy_busy_buffers_size 256k;
        proxy_read_timeout 300s;
        client_max_body_size 64m;
    }

  Then: sudo nginx -t && sudo systemctl reload nginx
NGINX
elif [ "$os" = Darwin ] && [ -z "${NO_OPEN:-}" ]; then
  open "$ORIGIN$APP_PATH" 2>/dev/null || true
fi
