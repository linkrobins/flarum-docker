#!/usr/bin/env bash
# ==========================================================================
# Create a restorable backup: a database dump + the uploaded files, in the
# format the entrypoint's restore-on-deploy understands.
#
# Run it INSIDE the running container, e.g.:
#   docker compose exec flarum backup.sh            # writes to /restore (mounted)
#   docker compose exec flarum backup.sh /tmp/out   # or a directory you choose
#
# Produces:  <dir>/database.sql.gz  and  <dir>/storage.tar.gz
# To restore: place those two files in ./restore on a FRESH deploy (empty data
# volume) and `docker compose up` — they're imported instead of a fresh install.
# ==========================================================================
set -eu

OUT="${1:-/restore}"
mkdir -p "$OUT"

echo "[+] Dumping database '${DB_NAME}'..."
mysqldump --no-tablespaces --single-transaction \
    -h"${DB_HOST}" -u"${DB_USER}" -p"${DB_PASS}" "${DB_NAME}" \
    | gzip > "$OUT/database.sql.gz"

echo "[+] Archiving uploaded files (storage + public/assets)..."
tar -czf "$OUT/storage.tar.gz" -C /var/www/html storage public/assets

echo "[+] Backup complete:"
ls -lh "$OUT/database.sql.gz" "$OUT/storage.tar.gz"
echo "[+] Restore: put both files in ./restore on a fresh deploy, then 'docker compose up -d'."
