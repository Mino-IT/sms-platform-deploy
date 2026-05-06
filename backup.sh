#!/bin/sh
# SMS Platform — daily backup service
#
# Runs inside the `backup` Docker Compose service.
# Dumps the database and uploads volume daily at BACKUP_HOUR (local time).
# Keeps BACKUP_RETENTION_DAYS of local copies, then deletes older ones.
# If BACKUP_AZURE_SAS_URL is set, also uploads each file to Azure Blob Storage.
#
# Required env:  PGPASSWORD
# Optional env:  BACKUP_HOUR (default 2), BACKUP_RETENTION_DAYS (default 30),
#                TZ (default Australia/Sydney), BACKUP_AZURE_SAS_URL

BACKUP_HOUR=${BACKUP_HOUR:-2}
RETENTION_DAYS=${BACKUP_RETENTION_DAYS:-30}
BACKUP_DIR=/backups

log() { echo "[backup] $(date '+%Y-%m-%d %H:%M:%S %Z') $*"; }

sleep_until_hour() {
  target=$1
  h=$(date +%H | awk '{print int($1)}')
  m=$(date +%M | awk '{print int($1)}')
  s=$(date +%S | awk '{print int($1)}')
  now_secs=$(( h * 3600 + m * 60 + s ))
  target_secs=$(( target * 3600 ))
  if [ "$now_secs" -lt "$target_secs" ]; then
    delay=$(( target_secs - now_secs ))
  else
    delay=$(( 86400 - now_secs + target_secs ))
  fi
  log "Next backup in ${delay}s (at $(printf '%02d:00' "$target"))"
  sleep "$delay"
}

run_backup() {
  stamp=$(date +%Y%m%d_%H%M%S)
  db_file="${BACKUP_DIR}/db_${stamp}.sql.gz"
  uploads_file="${BACKUP_DIR}/uploads_${stamp}.tar.gz"

  log "--- backup start ---"

  # Database dump
  if pg_dump -h postgres -U sms -d smsdb | gzip > "$db_file"; then
    log "db dump:      $(du -sh "$db_file" | cut -f1)  ($db_file)"
  else
    log "ERROR: pg_dump failed"
    rm -f "$db_file"
  fi

  # Uploads volume
  if tar -czf "$uploads_file" -C /uploads . 2>/dev/null; then
    log "uploads tar:  $(du -sh "$uploads_file" | cut -f1)  ($uploads_file)"
  else
    log "WARN: uploads tar failed (volume may be empty)"
    rm -f "$uploads_file"
  fi

  # Azure upload (optional)
  if [ -n "$BACKUP_AZURE_SAS_URL" ]; then
    for f in "$db_file" "$uploads_file"; do
      [ -f "$f" ] || continue
      fname=$(basename "$f")
      log "Azure upload: $fname"
      http_status=$(curl -s -o /dev/null -w "%{http_code}" -X PUT \
        -H "x-ms-blob-type: BlockBlob" \
        -H "x-ms-version: 2020-04-08" \
        -H "Content-Type: application/octet-stream" \
        --data-binary @"$f" \
        "${BACKUP_AZURE_SAS_URL%/}/${fname}")
      if [ "$http_status" = "201" ]; then
        log "Azure upload: $fname OK"
      else
        log "ERROR: Azure upload failed for $fname (HTTP $http_status)"
      fi
    done
  fi

  # Clean up local backups older than RETENTION_DAYS
  find "$BACKUP_DIR" \( -name "db_*.sql.gz" -o -name "uploads_*.tar.gz" \) \
    -mtime "+${RETENTION_DAYS}" -delete -print | while read -r f; do
    log "deleted old:  $(basename "$f")"
  done

  log "--- backup end ---"
}

# ── Startup ───────────────────────────────────────────────────────────────────

log "Backup service starting."
log "Schedule:  daily at ${BACKUP_HOUR}:00 ${TZ:-UTC}"
log "Retention: ${RETENTION_DAYS} days local"
if [ -n "$BACKUP_AZURE_SAS_URL" ]; then
  log "Azure:     enabled"
else
  log "Azure:     disabled (set BACKUP_AZURE_SAS_URL to enable)"
fi

sleep_until_hour "$BACKUP_HOUR"
while true; do
  run_backup
  sleep_until_hour "$BACKUP_HOUR"
done
