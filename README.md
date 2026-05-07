# SMS Platform — deployment artefacts

Auto-generated mirror of the deployment files for the SMS Platform
product. This repo contains **no source code** — only orchestration
files for installing and running the published Docker image from
GitHub Container Registry.

## Install

```bash
curl -fsSL https://raw.githubusercontent.com/Mino-IT/sms-platform-deploy/v1.0.1/install.sh -o install.sh
chmod +x install.sh
./install.sh
```

See the SMS Platform product documentation (provided by Mino IT at
handover) for full setup, upgrade, and operational guidance.

## What's in this repo

| File | Purpose |
|---|---|
| `install.sh` | Tech-facing first-boot installer. Prompts for URL, generates secrets, pulls the image, brings the stack up. |
| `docker-compose.yml` | Production stack definition. References the published image at `ghcr.io/mino-it/sms-platform`. |
| `backup.sh` | Daily `pg_dump` + uploads tar + retention pruning, with optional Azure Blob upload. |

All three files are auto-synced from the source repo on every
tagged release (`v*.*.*`) and on every push to `main`. Manual
edits in this repo will be overwritten on the next sync.
