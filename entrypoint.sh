#!/usr/bin/env bash
# ==========================================================================
# Flarum 2.0 self-contained entrypoint.
#
# Idempotent: safe to re-run on every container restart. On first boot it
# installs Flarum (composer create-project + flarum install), requires + enables
# the full feature set (uploads, redis, Horizon, realtime, audit, extension
# manager), wires redis cache+queue and (optional) SMTP mail, runs migrations,
# then exec's supervisord. On subsequent boots it skips the install and just
# re-syncs config + migrates.
#
# Config comes entirely from the container env (.env). No network fetch, no
# external secrets, no callbacks.
# ==========================================================================
set -u

log()  { echo "[+] $*"; }
warn() { echo "[!] WARNING: $*"; }
die()  { echo "[!] FATAL: $*"; exit 1; }

run_as_www() {
    if command -v sudo >/dev/null 2>&1; then sudo -u www-data "$@"; else su -s /bin/bash www-data -c "$*"; fi
}
composer_as_www() {
    run_as_www env COMPOSER_HOME="$COMPOSER_CACHE_DIR" COMPOSER_MEMORY_LIMIT=-1 composer "$@"
}

# Import a (optionally gzipped) SQL dump into the database.
import_db() {
    local f="$1"
    log "Importing database dump: $f"
    case "$f" in
        *.gz) zcat "$f" | mysql -h"$DB_HOST" -u"$DB_USER" -p"$DB_PASS" "$DB_NAME" ;;
        *)    mysql -h"$DB_HOST" -u"$DB_USER" -p"$DB_PASS" "$DB_NAME" < "$f" ;;
    esac
}

# Write a fresh Flarum config.php from env (used by the restore path, which
# imports the DB dump instead of running `flarum install`).
write_config_php() {
    cat > "$CONFIG_FILE" <<PHP
<?php return [
    'debug' => false,
    'database' => [
        'driver' => 'mariadb',
        'host' => '${DB_HOST}',
        'port' => 3306,
        'database' => '${DB_NAME}',
        'username' => '${DB_USER}',
        'password' => '${DB_PASS}',
        'charset' => 'utf8mb4',
        'collation' => 'utf8mb4_unicode_ci',
        'prefix' => '',
        'prefix_indexes' => true,
        'strict' => false,
        'engine' => null,
    ],
    'url' => '${APP_URL}',
    'paths' => ['api' => 'api', 'admin' => 'admin'],
];
PHP
    chown www-data:www-data "$CONFIG_FILE"
}

# ── Variables ───────────────────────────────────────────────────────────────
WORKDIR="/var/www/html"
CONFIG_FILE="$WORKDIR/config.php"
SUPERVISOR_CONF="/etc/supervisor/conf.d/supervisord.conf"
LOG_DIR="$WORKDIR/storage/logs"
COMPOSER_CACHE_DIR="$WORKDIR/storage/composer-cache"

clean() { echo "$1" | tr -d '\r' | xargs; }

APP_URL=$(clean "${APP_URL:-}")
FORUM_TITLE=$(clean "${FORUM_TITLE:-My Forum}")
ADMIN_USER=$(clean "${ADMIN_USER:-}")
ADMIN_PASS=$(clean "${ADMIN_PASS:-}")
ADMIN_EMAIL=$(clean "${ADMIN_EMAIL:-}")

DB_HOST=$(clean "${DB_HOST:-mariadb}")
DB_NAME=$(clean "${DB_NAME:-flarum}")
DB_USER=$(clean "${DB_USER:-flarum}")
DB_PASS=$(clean "${DB_PASS:-}")

REDIS_HOST=$(clean "${REDIS_HOST:-valkey}")
REDIS_PORT=$(clean "${REDIS_PORT:-6379}")
REDIS_PASSWORD=$(clean "${REDIS_PASSWORD:-}")

TARGET_FLARUM_VERSION=$(clean "${TARGET_FLARUM_VERSION:-^2.0}")
REALTIME_ENABLED=$(echo "${REALTIME_ENABLED:-true}" | tr '[:upper:]' '[:lower:]')

# Restore-on-deploy: drop a backup in the mounted /restore dir (database.sql[.gz]
# + optional storage.tar.gz, as produced by backup.sh) and it's imported instead
# of installing fresh. Paths can be overridden via env; otherwise the
# conventional /restore layout is auto-detected.
RESTORE_DB=$(clean "${RESTORE_DB:-}")
RESTORE_FILES=$(clean "${RESTORE_FILES:-}")
RESTORE_FORCE=$(echo "${RESTORE_FORCE:-false}" | tr '[:upper:]' '[:lower:]')
if [ -z "$RESTORE_DB" ]; then
    for f in /restore/database.sql.gz /restore/database.sql; do
        [ -f "$f" ] && RESTORE_DB="$f" && break
    done
fi
[ -z "$RESTORE_FILES" ] && [ -f /restore/storage.tar.gz ] && RESTORE_FILES="/restore/storage.tar.gz"

# Was a forum already installed before this boot?
HAD_CONFIG=false; [ -f "$CONFIG_FILE" ] && HAD_CONFIG=true
# Decide whether to restore this boot:
#   • fresh volume (no install) + a backup present              -> restore
#   • existing forum + RESTORE_FORCE=true + a backup we haven't
#     already imported (different sha256)                       -> restore OVER it
# The consumed-hash marker makes a forced restore one-shot, so a plain restart
# can never silently re-clobber a live forum (only a NEW backup restores again).
DO_RESTORE=false
RESTORE_HASH=""
CONSUMED_FILE="$WORKDIR/storage/.restore_consumed"
if [ -n "$RESTORE_DB" ]; then
    RESTORE_HASH=$(sha256sum "$RESTORE_DB" 2>/dev/null | cut -d' ' -f1)
    if [ "$HAD_CONFIG" = "false" ]; then
        DO_RESTORE=true
    elif [ "$RESTORE_FORCE" = "true" ]; then
        PREV=$( [ -f "$CONSUMED_FILE" ] && cat "$CONSUMED_FILE" 2>/dev/null || echo "" )
        [ "$RESTORE_HASH" != "$PREV" ] && DO_RESTORE=true
    fi
fi

[ -n "$APP_URL" ] || die "APP_URL is required."

export COMPOSER_MEMORY_LIMIT=-1

# ── PHP tuning ────────────────────────────────────────────────────────────────
cat > /usr/local/etc/php/conf.d/flarum.ini <<'INI'
memory_limit = 512M
upload_max_filesize = 64M
post_max_size = 64M
max_execution_time = 900
opcache.enable = 1
opcache.memory_consumption = 128
opcache.max_accelerated_files = 24000
opcache.validate_timestamps = 1
opcache.revalidate_freq = 60
realpath_cache_size = 4096k
realpath_cache_ttl = 600
INI

# php-fpm pool: ondemand workers.
FPM_POOL="/usr/local/etc/php-fpm.d/www.conf"
if [ -f "$FPM_POOL" ]; then
    sed -i -e 's/^pm = .*/pm = ondemand/' -e 's/^pm.max_children = .*/pm.max_children = 8/' "$FPM_POOL"
fi

ln -sf /dev/stdout /var/log/nginx/access.log 2>/dev/null || true
ln -sf /dev/stderr /var/log/nginx/error.log 2>/dev/null || true

mkdir -p "$LOG_DIR" "$COMPOSER_CACHE_DIR" /var/log/supervisor
chown -R www-data:www-data "$WORKDIR/storage" 2>/dev/null || true
chmod -R 775 "$WORKDIR/storage" 2>/dev/null || true

# ── Wait for MariaDB + ensure the database exists ─────────────────────────────
log "Waiting for MariaDB ($DB_HOST)..."
for i in $(seq 1 60); do
    if php -r "new PDO('mysql:host=$DB_HOST', '$DB_USER', '$DB_PASS');" >/dev/null 2>&1; then break; fi
    sleep 2
done
php -r "
try {
    \$pdo = new PDO('mysql:host=$DB_HOST', '$DB_USER', '$DB_PASS');
    \$pdo->exec('CREATE DATABASE IF NOT EXISTS \`$DB_NAME\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci');
    echo 'DB ready.' . PHP_EOL;
} catch (Exception \$e) { echo \$e->getMessage() . PHP_EOL; exit(1); }
" || die "Could not reach/create the MariaDB database"

# ── Fresh install (only when config.php is absent) ────────────────────────────
if [ ! -f "$CONFIG_FILE" ]; then
    if [ "$DO_RESTORE" = "true" ]; then
        log "No config.php — RESTORING from backup ($RESTORE_DB)."
    else
        log "No config.php — fresh Flarum install."
        [ -n "$ADMIN_USER" ] && [ -n "$ADMIN_PASS" ] && [ -n "$ADMIN_EMAIL" ] \
            || die "ADMIN_USER / ADMIN_PASS / ADMIN_EMAIL are required for a fresh install."
    fi

    TMP_INSTALL="$WORKDIR/storage/flarum_stage"
    rm -rf "$TMP_INSTALL" && mkdir -p "$TMP_INSTALL" && chown www-data:www-data "$TMP_INSTALL"
    log "composer create-project flarum/flarum:${TARGET_FLARUM_VERSION}..."
    composer_as_www create-project "flarum/flarum:${TARGET_FLARUM_VERSION}" --stability=beta "$TMP_INSTALL" --no-interaction \
        >> "$LOG_DIR/composer_install.log" 2>&1 || die "composer create-project failed — see $LOG_DIR/composer_install.log"
    cp -an "$TMP_INSTALL/." "$WORKDIR/" && rm -rf "$TMP_INSTALL"
    chown -R www-data:www-data "$WORKDIR"
    find "$WORKDIR" -type d -exec chmod 775 {} + ; find "$WORKDIR" -type f -exec chmod 664 {} +
    chmod -R 775 "$WORKDIR/storage" "$WORKDIR/public/assets"

    if [ "$DO_RESTORE" = "true" ]; then
        # Restore: import the backup DB instead of running a fresh install, and
        # write config.php from env (the dump carries the forum's data/settings).
        import_db "$RESTORE_DB" >> "$LOG_DIR/db_restore.log" 2>&1 \
            || die "Database import failed — see $LOG_DIR/db_restore.log"
        write_config_php
        log "Database restored from backup."
    else
        cat > "$WORKDIR/install.yml" <<YAML
debug: false
baseUrl: '${APP_URL}'
databaseConfiguration:
  driver: mariadb
  host: '${DB_HOST}'
  database: '${DB_NAME}'
  username: '${DB_USER}'
  password: '${DB_PASS}'
  prefix: ''
adminUser:
  username: '${ADMIN_USER}'
  password: '${ADMIN_PASS}'
  email: '${ADMIN_EMAIL}'
settings:
  forum_title: '${FORUM_TITLE}'
YAML
        chown www-data:www-data "$WORKDIR/install.yml"

        log "Running Flarum CLI installer..."
        cd "$WORKDIR"
        run_as_www php flarum install --file=install.yml >> "$LOG_DIR/flarum_install.log" 2>&1 \
            || die "Flarum install failed — see $LOG_DIR/flarum_install.log"
        rm -f "$WORKDIR/install.yml"
        log "Flarum installed."
    fi
fi

# Keep config.php in sync with the DB + base URL on every boot.
if [ -f "$CONFIG_FILE" ]; then
    sed -i \
        -e "s/'driver' => 'mysql'/'driver' => 'mariadb'/g" \
        -e "s/'host' => '[^']*'/'host' => '${DB_HOST}'/g" \
        -e "s/'database' => '[^']*'/'database' => '${DB_NAME}'/g" \
        -e "s/'username' => '[^']*'/'username' => '${DB_USER}'/g" \
        -e "s/'password' => '[^']*'/'password' => '${DB_PASS}'/g" \
        -e "s~'url' => '[^']*'~'url' => '${APP_URL}'~g" \
        "$CONFIG_FILE"
fi

# Forced restore OVER an existing forum (RESTORE_FORCE=true). The fresh-volume
# case is handled in the install branch above; this covers "I already set up the
# site and now want to restore a backup into it." mysqldump's DROP TABLE IF
# EXISTS replaces the tables; the migrate step below reconciles the schema.
if [ "$DO_RESTORE" = "true" ] && [ "$HAD_CONFIG" = "true" ]; then
    warn "RESTORE_FORCE: importing the backup OVER the existing forum ($RESTORE_DB)."
    import_db "$RESTORE_DB" >> "$LOG_DIR/db_restore.log" 2>&1 \
        || die "Forced database import failed — see $LOG_DIR/db_restore.log"
    log "Existing database replaced from backup."
fi

# Restore uploaded files (storage/ + public/assets — avatars, fof/upload files)
# from the backup archive (both the fresh and forced restore paths).
if [ "$DO_RESTORE" = "true" ] && [ -n "$RESTORE_FILES" ] && [ -f "$RESTORE_FILES" ]; then
    log "Restoring files from $RESTORE_FILES..."
    tar -xzf "$RESTORE_FILES" -C "$WORKDIR" >> "$LOG_DIR/files_restore.log" 2>&1 \
        || warn "File restore failed (non-fatal) — see $LOG_DIR/files_restore.log"
    chown -R www-data:www-data "$WORKDIR/storage" "$WORKDIR/public/assets" 2>/dev/null || true
fi

# ── Required extensions (hard-require — fail the boot on a composer error) ─────
composer_require() {
    local pkg="$1"
    if ! grep -q "\"$pkg\"" "$WORKDIR/composer.json" 2>/dev/null; then
        log "Requiring $pkg..."
        composer_as_www require "${pkg}:*" --no-interaction \
            >> "$LOG_DIR/composer_require_${pkg//\//_}.log" 2>&1 \
            || die "$pkg require failed — see $LOG_DIR/composer_require_${pkg//\//_}.log"
    else
        log "$pkg already present."
    fi
}

composer_require "fof/upload"
composer_require "fof/redis"
composer_require "fof/horizon"
composer_require "flarum/realtime"
# audit + extension-manager may ship with flarum/flarum already; require is a
# no-op if present, and guarantees they exist otherwise.
composer_require "flarum/audit"
composer_require "flarum/extension-manager"

# ── extend.php: redis cache/queue (fof/redis) + Horizon worker config ─────────
# fof/redis points Flarum's cache + queue at redis; Horizon manages the workers.
REDIS_PASS_PHP=$( [ -n "$REDIS_PASSWORD" ] && echo "'${REDIS_PASSWORD}'" || echo "null" )
cat > "$WORKDIR/extend.php" <<EPHP
<?php

error_reporting(E_ALL & ~E_DEPRECATED & ~E_USER_DEPRECATED);

use Flarum\Extend;
use FoF\Horizon\Extend\Horizon;

return [
    new FoF\Redis\Extend\Redis([
        'client'   => 'phpredis',
        'host'     => '${REDIS_HOST}',
        'password' => ${REDIS_PASS_PHP},
        'port'     => ${REDIS_PORT},
        'database' => 1,
    ]),
    (new Horizon())->environment([
        'supervisor-1' => [
            'connection' => 'redis',
            'queue'      => ['digest', 'default'],
            'balance'    => 'auto',
            'minProcesses' => 1,
            'maxProcesses' => 2,
            'processes'  => 2,
            'tries'      => 3,
            'memory'     => 128,
        ],
    ]),
];
EPHP
chown www-data:www-data "$WORKDIR/extend.php"
log "extend.php written (redis + horizon)."

# ── Realtime websocket config (port 6001) ─────────────────────────────────────
# Honour APP_URL's scheme: an https base URL implies a TLS-terminating proxy in
# front, so the JS client must connect securely on 443; otherwise plain on 80.
if [ "$REALTIME_ENABLED" = "true" ]; then
    log "Applying realtime websocket config..."
    DOMAIN_ONLY=$(echo "$APP_URL" | sed 's~https\?://~~' | sed 's~/.*~~')
    case "$APP_URL" in
        https://*) JS_PORT=443; JS_SECURE=true ;;
        *)         JS_PORT=80;  JS_SECURE=false ;;
    esac
    php -r "
    \$cfg = include '$CONFIG_FILE';
    \$cfg['websocket'] = [
        'server-host'       => '0.0.0.0',       'server-port'       => 6001,
        'js-client-host'    => '$DOMAIN_ONLY',  'js-client-port'    => $JS_PORT,
        'js-client-secure'  => $JS_SECURE,
        'php-client-host'   => '127.0.0.1',     'php-client-port'   => 6001,
        'php-client-scheme' => 'http',          'php-client-secure' => false,
    ];
    file_put_contents('$CONFIG_FILE', '<?php return ' . var_export(\$cfg, true) . ';');
    echo 'WebSocket config written.' . PHP_EOL;
    " || warn "WebSocket config failed — continuing"
fi

# ── Mail: generic SMTP from env (optional) ────────────────────────────────────
if [ -n "${MAIL_HOST:-}" ]; then
    log "Writing SMTP mail settings..."
    MAIL_PORT=$(clean "${MAIL_PORT:-587}")
    MAIL_USERNAME=$(clean "${MAIL_USERNAME:-}")
    MAIL_PASSWORD_VAL="${MAIL_PASSWORD:-}"
    MAIL_ENCRYPTION=$(clean "${MAIL_ENCRYPTION:-tls}")
    MAIL_FROM=$(clean "${MAIL_FROM:-$ADMIN_EMAIL}")
    MAIL_HOST_VAL=$(clean "${MAIL_HOST}")
    MAIL_HOST_VAL="$MAIL_HOST_VAL" MAIL_PORT="$MAIL_PORT" MAIL_USERNAME="$MAIL_USERNAME" \
    MAIL_PASSWORD_VAL="$MAIL_PASSWORD_VAL" MAIL_ENCRYPTION="$MAIL_ENCRYPTION" MAIL_FROM="$MAIL_FROM" \
    DB_HOST="$DB_HOST" DB_NAME="$DB_NAME" DB_USER="$DB_USER" DB_PASS="$DB_PASS" php -r '
    $pdo = new PDO("mysql:host=".getenv("DB_HOST").";dbname=".getenv("DB_NAME"), getenv("DB_USER"), getenv("DB_PASS"));
    $s = $pdo->prepare("REPLACE INTO settings (`key`, value) VALUES (?, ?)");
    foreach ([
        "mail_driver"     => "smtp",
        "mail_host"       => getenv("MAIL_HOST_VAL"),
        "mail_port"       => getenv("MAIL_PORT"),
        "mail_encryption" => getenv("MAIL_ENCRYPTION"),
        "mail_username"   => getenv("MAIL_USERNAME"),
        "mail_password"   => getenv("MAIL_PASSWORD_VAL"),
        "mail_from"       => getenv("MAIL_FROM"),
    ] as $k => $v) $s->execute([$k, $v]);
    echo "Mail settings saved." . PHP_EOL;
    ' || warn "Failed to write mail settings"
fi

# ── Migrate + enable extensions ───────────────────────────────────────────────
log "Running Flarum migrations..."
run_as_www php "$WORKDIR/flarum" migrate >> "$LOG_DIR/flarum_migrate.log" 2>&1 \
    || die "Flarum migration failed — see $LOG_DIR/flarum_migrate.log"

enable_ext() {
    log "Enabling extension: $1"
    run_as_www php "$WORKDIR/flarum" extension:enable "$1" 2>/dev/null || warn "Could not enable $1"
}

enable_ext "fof-upload"
enable_ext "fof-redis"
enable_ext "fof-horizon"
enable_ext "flarum-audit"
enable_ext "flarum-extension-manager"
[ "$REALTIME_ENABLED" = "true" ] && enable_ext "flarum-realtime"

# Route the queue through redis (Horizon picks it up).
php -r "
\$pdo = new PDO('mysql:host=$DB_HOST;dbname=$DB_NAME', '$DB_USER', '$DB_PASS');
\$pdo->prepare(\"REPLACE INTO settings (\`key\`,value) VALUES ('queue_driver','redis')\")->execute();
" || warn "Failed to set queue driver"

log "Clearing Flarum cache..."
run_as_www php "$WORKDIR/flarum" cache:clear >> "$LOG_DIR/cache_clear.log" 2>&1 || warn "cache:clear failed (non-fatal)"

# Mark this backup consumed so a forced restore is one-shot: a plain restart
# won't re-import it (only a different backup will). Cleared with the volume.
if [ "$DO_RESTORE" = "true" ] && [ -n "$RESTORE_HASH" ]; then
    echo "$RESTORE_HASH" > "$CONSUMED_FILE" 2>/dev/null || true
    chown www-data:www-data "$CONSUMED_FILE" 2>/dev/null || true
fi

# ── Flarum scheduler cron (runs as www-data) ──────────────────────────────────
( crontab -u www-data -l 2>/dev/null | grep -v "schedule:run"
  echo "* * * * * /usr/local/bin/php /var/www/html/flarum schedule:run >> /dev/null 2>&1"
) | crontab -u www-data -

log "All done. Starting supervisord."
exec /usr/bin/supervisord -c "$SUPERVISOR_CONF"
