# Self-Hosted Flarum 2.0 (Docker)

A complete, self-contained [Flarum 2.0](https://flarum.org) stack in three
containers — clone, set a few env vars, and `docker compose up`. Everything is
baked into the image: nginx, php-fpm, Composer, all required PHP extensions, and
the boot script. There is **no runtime download** of a setup script, no external
services, and no telemetry.

## What you get

- **Flarum 2.0** served by nginx + php-fpm under supervisor (single app image).
- **MariaDB 11** sidecar (the database the Flarum extension ecosystem is built and
  tested against).
- **Valkey** (Redis-compatible) for cache + queue.
- **Horizon** queue worker (`fof/horizon` + `fof/redis`) — background jobs run
  out of process.
- **Realtime** websocket server (`flarum/realtime`) for live updates.
- **Audit log** (`flarum/audit`) and the **Extension Manager**
  (`flarum/extension-manager`) so you can install/manage extensions from the
  admin UI.
- **File uploads** (`fof/upload`) on Flarum's local filesystem by default (no S3
  required).

## Requirements

- Docker + Docker Compose v2.

## Quickstart

```bash
cp .env.example .env
$EDITOR .env          # set APP_URL, admin creds, and the DB/Redis passwords
docker compose up -d --build
```

First boot installs Flarum (Composer create-project + migrations + extensions),
which takes roughly **1–2 minutes**. Watch progress with:

```bash
docker compose logs -f flarum
```

When it's ready, visit `APP_URL` and log in with the `ADMIN_USER` /
`ADMIN_PASS` you set in `.env`.

## TLS / reverse proxy

This stack publishes plain HTTP on port **80** (and the realtime websocket on
**6001**, also proxied at `/app` on port 80). It deliberately ships **no TLS and
no Traefik labels** so it stays generic. In production put your own reverse proxy
(Caddy, Traefik, nginx, a cloud load balancer, …) in front to terminate HTTPS,
and set `APP_URL=https://...`. The app honours `X-Forwarded-Proto`, so Flarum and
the realtime client behave correctly behind a TLS-terminating proxy.

## Configuration

All configuration is via `.env` (see `.env.example` for the full, documented
list): forum identity, initial admin, MariaDB credentials, Valkey password,
optional SMTP mail, and the realtime toggle. Settings are applied idempotently on
every container start, so editing `.env` and re-running `docker compose up -d`
re-syncs them.

### Email

Email is optional. Leave `MAIL_HOST` empty to skip mail setup. Set the `MAIL_*`
values to any SMTP provider to enable signup/notification emails.

### File uploads

Uploads default to Flarum's local filesystem (stored in the `flarum_data`
volume). If you want object storage, you can configure an S3-compatible adapter
from the Uploads extension settings in the admin panel.

## Data & backups

State lives in named Docker volumes: `flarum_data` (Flarum code + `storage/` +
uploads), `mariadb_data` (database), `valkey_data` (cache/queue). Back these up
with your own tooling (e.g. `docker compose exec mariadb mariadb-dump ...` and a
volume snapshot).

## License

MIT — see [LICENSE](LICENSE). This is an independent, community self-hosting
setup. It is **not affiliated with any commercial Flarum hosting service**, and
ships no proprietary or managed-hosting components.
