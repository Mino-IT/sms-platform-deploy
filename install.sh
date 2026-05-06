#!/usr/bin/env bash
# install.sh — first-boot installer for SMS Platform on a client server.
#
# This is the tech-facing install path. It downloads the compose file +
# backup script from the public sms-platform-deploy mirror repo, auto-
# generates secrets, prompts for the public URL, then pulls the image
# from GHCR and brings the stack up.
#
# (The source repo is private; deployment artefacts are published to a
# separate public repo via CI on every release. This script lives in
# both repos — the deploy repo's copy is the canonical one for clients
# to download.)
#
# Usage on a fresh Ubuntu server:
#   curl -fsSL https://raw.githubusercontent.com/BrodieMinoIT/sms-platform-deploy/main/install.sh -o install.sh
#   chmod +x install.sh
#   sudo ./install.sh
#
# To pin to a specific release (recommended):
#   curl -fsSL https://raw.githubusercontent.com/BrodieMinoIT/sms-platform-deploy/v1.0.0/install.sh -o install.sh
#
# Re-running is safe — existing values in .env are preserved, only
# missing values are filled.

set -euo pipefail

# ── Config ───────────────────────────────────────────────────────────────────

# Defaults to "main"; override on the curl URL by pinning to a tag (above).
GITHUB_REF="${GITHUB_REF:-main}"
RAW_BASE="https://raw.githubusercontent.com/BrodieMinoIT/sms-platform-deploy/${GITHUB_REF}"
INSTALL_DIR="${INSTALL_DIR:-$(pwd)}"

# ── Helpers ──────────────────────────────────────────────────────────────────

red()    { printf '\033[31m%s\033[0m\n' "$*" >&2; }
green()  { printf '\033[32m%s\033[0m\n' "$*"; }
yellow() { printf '\033[33m%s\033[0m\n' "$*"; }
bold()   { printf '\033[1m%s\033[0m\n' "$*"; }

require() {
  if ! command -v "$1" >/dev/null 2>&1; then
    red "Missing prerequisite: $1"
    red "Install it and re-run."
    exit 1
  fi
}

generate_secret()   { openssl rand -base64 32 | tr -d '\n'; }
generate_password() { openssl rand -hex 24    | tr -d '\n'; }

get_env() {
  # tr -d '\r' is defensive — protects against .env files that picked up
  # Windows-style CRLF line endings somehow (heredocs pasted via the
  # Windows clipboard, files edited in Notepad on the deploy server,
  # rsync'd from a Windows box, etc). Without it, the value is returned
  # with a trailing \r that ends up embedded mid-line on the next write
  # and corrupts the file. install.sh on a real Linux client server
  # would never hit this — production .env stays \n-only end to end —
  # but the cost of the guard is negligible.
  [ -f .env ] && grep -E "^$1=" .env 2>/dev/null | head -1 | cut -d= -f2- \
    | sed 's/[[:space:]]*#.*//' | tr -d '"' | tr -d "'" | tr -d '\r' || true
}

set_env() {
  local key="$1" value
  # Strip CR from the incoming value too, so a `set_env KEY "$(get_env OTHER)"`
  # chain can never propagate a \r picked up upstream.
  value=$(printf '%s' "$2" | tr -d '\r')
  if grep -qE "^$key=" .env 2>/dev/null; then
    # Use a unique delimiter — values may contain /
    sed -i.bak "s|^$key=.*|$key=$value|" .env && rm -f .env.bak
  else
    echo "$key=$value" >> .env
  fi
}

# ── Prerequisite checks ──────────────────────────────────────────────────────

bold "SMS Platform installer"
echo "Ref: ${GITHUB_REF}"
echo "Install dir: ${INSTALL_DIR}"
echo

require docker
require curl
require openssl

if ! docker compose version >/dev/null 2>&1; then
  red "Docker Compose v2 not available (got: $(docker --version 2>/dev/null || echo 'docker not installed'))"
  red "Install docker compose plugin: apt-get install docker-compose-plugin"
  exit 1
fi

cd "${INSTALL_DIR}"

# ── Download compose + supporting files (atomic — temp + rename) ─────────────
#
# Using a tmpfile-and-rename pattern so a partial download (network drop,
# image not yet published) doesn't leave a half-written file that re-runs
# would treat as "already present".

green "Downloading deployment files..."
for file in docker-compose.yml backup.sh; do
  if [ ! -f "$file" ]; then
    if ! curl -fsSL "${RAW_BASE}/${file}" -o "${file}.tmp"; then
      red "Download failed: ${file}"
      red "Check your network connection and that the ref '${GITHUB_REF}' exists."
      rm -f "${file}.tmp"
      exit 1
    fi
    mv "${file}.tmp" "${file}"
    echo "  ✓ ${file}"
  else
    yellow "  ${file} already present — keeping local copy"
  fi
done
chmod +x backup.sh

# ── Initialise .env ──────────────────────────────────────────────────────────

if [ ! -f .env ]; then
  touch .env
  green "Created empty .env"
fi

GENERATED=()

# NEXTAUTH_URL — auto-set to local access for first-run setup.
# The tech updates this to the production URL via
# Settings → Environment Variables AFTER the Cloudflare tunnel is up
# and the public domain actually resolves. Setting it to the public
# URL upfront causes login redirects to a not-yet-reachable domain.
NEXTAUTH_URL=$(get_env NEXTAUTH_URL)
if [ -z "$NEXTAUTH_URL" ]; then
  # Prefer the server's LAN IP so the tech can browse from another
  # machine on the same network. Fall back to localhost if hostname -I
  # returns nothing (e.g. on Windows running this in WSL).
  LAN_IP=""
  if command -v hostname >/dev/null 2>&1; then
    LAN_IP=$(hostname -I 2>/dev/null | awk '{print $1}' || true)
  fi
  if [ -n "$LAN_IP" ] && [ "$LAN_IP" != "127.0.0.1" ]; then
    NEXTAUTH_URL="http://${LAN_IP}:3000"
  else
    NEXTAUTH_URL="http://localhost:3000"
  fi
  set_env NEXTAUTH_URL "$NEXTAUTH_URL"
  GENERATED+=("NEXTAUTH_URL = ${NEXTAUTH_URL}  (update to public URL via Settings once Cloudflare tunnel is up)")
fi

# NEXTAUTH_SECRET — auto-generated
if [ -z "$(get_env NEXTAUTH_SECRET)" ]; then
  SECRET=$(generate_secret)
  set_env NEXTAUTH_SECRET "$SECRET"
  GENERATED+=("NEXTAUTH_SECRET")
fi

# DB_PASSWORD + DATABASE_URL — auto-generated
if [ -z "$(get_env DB_PASSWORD)" ]; then
  PW=$(generate_password)
  set_env DB_PASSWORD "$PW"
  set_env DATABASE_URL "postgresql://sms:${PW}@postgres:5432/smsdb"
  GENERATED+=("DB_PASSWORD" "DATABASE_URL")
fi

# Defaults — set if not already present
[ -z "$(get_env IMAGE_TAG)" ] && set_env IMAGE_TAG "1"
[ -z "$(get_env TZ)" ]                    && set_env TZ "Australia/Brisbane"
[ -z "$(get_env BACKUP_HOUR)" ]           && set_env BACKUP_HOUR "2"
[ -z "$(get_env BACKUP_RETENTION_DAYS)" ] && set_env BACKUP_RETENTION_DAYS "30"

# Empty placeholders for optional vars (set later via Settings UI)
for key in SETUP_APP_CLIENT_SECRET ENFONICA_SERVICE_ACCOUNT ENFONICA_NUMBER \
           ENFONICA_WEBHOOK_SECRET AZURE_AD_TENANT_ID AZURE_AD_CLIENT_ID \
           AZURE_AD_CLIENT_SECRET AZURE_AD_ADMIN_GROUP_ID AZURE_AD_MANAGER_GROUP_ID \
           AZURE_AD_AGENT_GROUP_ID CF_TUNNEL_TOKEN BACKUP_AZURE_SAS_URL; do
  if ! grep -qE "^${key}=" .env 2>/dev/null; then
    echo "${key}=" >> .env
  fi
done

chmod 600 .env

# ── Pull + start ─────────────────────────────────────────────────────────────

green "Pulling images from GHCR..."
docker compose pull

green "Starting stack..."
docker compose up -d

# ── Print result ─────────────────────────────────────────────────────────────

echo
bold "Installation complete."
echo

if [ ${#GENERATED[@]} -gt 0 ]; then
  yellow "Auto-generated values written to .env (full values are in the file):"
  for k in "${GENERATED[@]}"; do
    echo "  • ${k}"
  done
  echo
fi

bold "Next steps"
echo

echo "1. Wait ~30 seconds for the app container to finish starting."
echo "   Watch progress: docker compose logs -f app"
echo
echo "2. Open the first-run setup page in a browser:"
echo "      ${NEXTAUTH_URL}/setup"
echo "   Create the admin account (12+ chars, mixed case, number, symbol)."
echo
echo "3. Sign in. Everything else is configured via Settings → Platform:"
echo "      • Site URL          — set the public URL (e.g. https://sms.client.com.au)"
echo "      • Cloudflare Tunnel — paste the tunnel token from the Cloudflare dashboard"
echo "      • Mino IT Setup     — paste the setup secret (Mino IT provides at handover)"
echo "      • Backups           — schedule, retention, optional Azure SAS URL"
echo "      • Enfonica          — SMS provider credentials"
echo
echo "   The Settings UI walks through each section's setup steps."
echo
echo "4. After Site URL + Cloudflare tunnel are configured + saved,"
echo "   apply on this server so the new values take effect:"
echo "      docker compose up -d"
echo "   (NOT 'docker compose restart' — restart alone doesn't re-read .env.)"
echo

bold "Reference"
echo "  Logs:        docker compose logs -f app"
echo "  Status:      docker compose ps"
echo "  Apply env:   docker compose up -d         (re-reads .env, recreates containers if config changed)"
echo "  Bounce only: docker compose restart       (process kill+start, does NOT re-read .env)"
echo "  Upgrade:     docker compose pull && docker compose up -d"
echo "  Stop:        docker compose down"
echo
