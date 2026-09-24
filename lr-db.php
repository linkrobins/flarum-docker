<?php
/**
 * The entrypoint's database handle.
 *
 * Every `php -r` block in entrypoint.sh that touches the database starts with
 * `require "/usr/local/bin/lr-db.php";` and gets $pdo — connected with the
 * DSN the entrypoint built for the configured driver — plus the two settings
 * statements spelled for that driver. MariaDB has REPLACE INTO and backtick
 * quoting; PostgreSQL has ON CONFLICT and double quotes. This is the only
 * place those differences live.
 */
$pdo = new PDO(getenv('DB_DSN_DB'), getenv('DB_USER'), getenv('DB_PASS'), [PDO::ATTR_ERRMODE => PDO::ERRMODE_EXCEPTION]);

$pg = getenv('DB_DRIVER') === 'pgsql';

/** Quote an identifier for the driver in use. */
function qi(string $identifier): string
{
    return getenv('DB_DRIVER') === 'pgsql' ? '"' . $identifier . '"' : '`' . $identifier . '`';
}

define('SETTINGS_UPSERT', $pg
    ? 'INSERT INTO settings ("key", value) VALUES (?, ?) ON CONFLICT ("key") DO UPDATE SET value = EXCLUDED.value'
    : 'REPLACE INTO settings (`key`, value) VALUES (?, ?)');
define('SETTINGS_SELECT', 'SELECT value FROM settings WHERE ' . qi('key') . ' = ?');
