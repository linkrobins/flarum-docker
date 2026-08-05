# Self-Hosted Flarum 2.0 (Docker)

[![CI — build + backup/restore round-trip](https://github.com/linkrobins/flarum-docker/actions/workflows/ci.yml/badge.svg)](https://github.com/linkrobins/flarum-docker/actions/workflows/ci.yml)

A complete, self-contained [Flarum 2.0](https://flarum.org) stack in three
containers — clone, set a few env vars, and `docker compose up`.

Two things set this apart:

- **It runs Flarum 2.0**, not 1.x. Horizon, Realtime, the audit log and the
  Extension Manager are wired up and working out of the box.
- **Backup and restore are part of the product, not an exercise for the reader.**
  A dump-and-reimport round trip runs in CI on every push, so the restore path
  is tested rather than assumed — including restoring a backup from an older
  Flarum into a newer one.

**Flarum itself is in the image, at a pinned version.** It is not fetched from
Packagist when your container starts, so the same image tag always installs the
same forum, a first boot needs no internet access, and an upstream outage cannot
break a new install. The exact version set lives in
[`skeleton/`](skeleton/) and moves only in a reviewed pull request.

Everything else is baked in too: nginx, php-fpm, Composer, all required PHP
extensions, and the boot script. No external services, and no telemetry.

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

> **Prefer the prebuilt image?** A multi-arch image (amd64 + arm64) is published to
> the GitHub Container Registry on every release, so you can skip the local build:
>
> ```bash
> docker compose pull && docker compose up -d
> # or pull directly:
> docker pull ghcr.io/linkrobins/flarum-docker:latest
> ```
>
> The compose file already references `ghcr.io/linkrobins/flarum-docker:latest`
> (with `build: .` as a fallback). Pin a version with a tag, e.g.
> `ghcr.io/linkrobins/flarum-docker:1.0`.

First boot installs Flarum (Composer create-project + migrations + extensions),
which takes roughly **1–2 minutes**. Watch progress with:

```bash
docker compose logs -f flarum
```

When it's ready, visit `APP_URL` and log in with the `ADMIN_USER` /
`ADMIN_PASS` you set in `.env`.

## Updating the image

**Pulling a new image does not upgrade an existing forum, by design.** The image
tag describes what a **fresh install** gets, not what an already-installed volume
runs. The baked Flarum only ever seeds an empty volume, so `docker compose pull`
on a live site gives you new nginx/PHP/entrypoint and the **same** Flarum.

That keeps a routine pull from becoming a database-migrating operation on a
running forum. It does mean the tag and the forum can differ, so every boot logs
which is which:

```
[!] WARNING: VERSION DRIFT: this forum runs Flarum 2.0.0-rc.5, this image ships 2.0.0-rc.6.
```

The same three facts are written to `storage/.flarum_version` inside the
container, for scripting or a status check:

```bash
docker compose exec flarum cat storage/.flarum_version
# installed=2.0.0-rc.5
# image=2.0.0-rc.6
# drift=true
```

Upgrading Flarum stays a deliberate act. Back up first, then either use the
**Extension Manager** in admin, or:

```bash
docker compose exec flarum backup.sh
docker compose exec -u www-data flarum composer update flarum/core --with-all-dependencies
docker compose restart flarum          # runs migrations on the way back up
```

## TLS / reverse proxy

This stack publishes plain HTTP on port **80** (and the realtime websocket on
**6001**, also proxied at `/app` on port 80). It deliberately ships **no TLS and
no Traefik labels** so it stays generic. In production put your own reverse proxy
(Caddy, Traefik, nginx, a cloud load balancer, …) in front to terminate HTTPS,
and set `APP_URL=https://...`. The app honours `X-Forwarded-Proto`, so Flarum and
the realtime client behave correctly behind a TLS-terminating proxy.

If you don't already run a proxy, [`examples/traefik`](examples/traefik) is a
ready-made stack with Traefik in front: HTTPS, automatic Let's Encrypt
certificates, HTTP redirected to HTTPS, and the app container publishing no
ports of its own.

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

## Data, backups & restore

State lives in named Docker volumes: `flarum_data` (Flarum code + `storage/` +
uploads), `mariadb_data` (database), `valkey_data` (cache/queue).

### Create a backup

Run the bundled helper inside the running container — it writes a database dump
and an uploaded-files archive into the mounted `./restore` directory:

```bash
docker compose exec flarum backup.sh
# -> ./restore/database.sql.gz  +  ./restore/storage.tar.gz
```

### Where is `./restore`?

It's the **`restore/` folder that ships in this repo**, right next to
`docker-compose.yml` — so after you clone, it already exists. Put your backup
files in there. (It's mounted into the container at `/restore`.)

### Restore on a fresh deploy

On a **fresh deploy** (empty `flarum_data` volume — i.e. you haven't set the
forum up yet), drop a backup into `restore/` and bring the stack up. The
entrypoint imports it **instead of** doing a fresh install.

```bash
cp /path/to/database.sql.gz ./restore/      # required
cp /path/to/storage.tar.gz  ./restore/      # optional (uploads/avatars)
docker compose up -d --build
```

### Restore into a site you've ALREADY set up

If you've already installed the forum and now want to load a backup into it
(migrating in, or recovering), set **`RESTORE_FORCE=true`** in your `.env`, put
the backup in `restore/`, and redeploy:

```bash
echo 'RESTORE_FORCE=true' >> .env
cp /path/to/database.sql.gz ./restore/
docker compose up -d              # imports OVER the existing forum
```

This is deliberately opt-in so a stray backup can't wipe a live forum. It's also
**one-shot**: once a backup is imported, a plain restart won't re-import it — only
a *different* backup will. (Leave `RESTORE_FORCE` off again afterward.)

The DB dump is imported, `config.php` is written from your `.env`, uploaded files
are extracted, and `flarum migrate` runs — so a backup from an **older** Flarum is
upgraded to the running version on the way in. Notes:

- On a fresh volume, restore is automatic. On an existing forum it requires
  `RESTORE_FORCE=true` (above) — so a stray backup can never wipe a live forum on
  a restart.
- File names are auto-detected (`database.sql[.gz]`, `storage.tar.gz`); override
  with `RESTORE_DB` / `RESTORE_FILES` env vars to point at other paths.
- Any third-party extensions your backup used must be installed too (this image
  bundles uploads, redis, Horizon, realtime, audit, and the extension manager —
  use the extension manager in admin to reinstall others).
- `./restore` is git-ignored — backups contain forum data, so they're never
  committed.

## License

MIT — see [LICENSE](LICENSE). This is an independent, community self-hosting
setup. It is **not affiliated with any commercial Flarum hosting service**, and
ships no proprietary or managed-hosting components.
