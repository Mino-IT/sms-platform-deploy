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
  [ -f .env ] && grep -E "^$1=" .env 2>/dev/null | head -1 | cut -d= -f2- \
    | sed 's/[[:space:]]*#.*//' | tr -d '"' | tr -d "'" || true
}

set_env() {
  local key="$1" value="$2"
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

# NEXTAUTH_URL — prompt the tech (the only thing they have to enter)
NEXTAUTH_URL=$(get_env NEXTAUTH_URL)
if [ -z "$NEXTAUTH_URL" ]; then
  echo
  bold "What's the public URL for this deployment?"
  echo "Examples: https://sms.niagaratherapy.com.au  or  http://192.168.1.50:3000"
  read -r -p "URL: " NEXTAUTH_URL
  if [ -z "$NEXTAUTH_URL" ]; then
    red "URL is required. Re-run when you have one."
    exit 1
  fi
  # Reject obviously-bad input early so we don't write garbage to .env.
  # Full URL validation is out of scope for a shell script — Docker /
  # NextAuth will fail later if the URL is malformed.
  if ! printf '%s' "$NEXTAUTH_URL" | grep -qE '^https?://[^[:space:]]+$'; then
    red "URL must start with http:// or https:// and contain no spaces."
    red "Got: ${NEXTAUTH_URL}"
    exit 1
  fi
  set_env NEXTAUTH_URL "$NEXTAUTH_URL"
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

echo "Next steps:"
echo "  1. Wait ~30 seconds for the app container to finish starting"
echo "  2. Visit: ${NEXTAUTH_URL}/setup"
echo "  3. Create the admin account"
echo "  4. Configure Mino IT setup secret + Enfonica credentials in Settings"
echo
echo "Logs:    docker compose logs -f app"
echo "Status:  docker compose ps"
echo "Update:  docker compose pull && docker compose up -d"
echo
