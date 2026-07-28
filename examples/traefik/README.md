# Flarum 2.0 behind Traefik (HTTPS)

The stack in the repository root publishes plain HTTP and ships no TLS, so it
stays generic enough to sit behind whatever proxy you already run. If you don't
already have one, this example is the shortest path to a real certificate.

It is the same app image with Traefik in front: HTTP redirected to HTTPS,
certificates issued and renewed by Let's Encrypt, and the forum reachable only
through the proxy — the app container publishes no ports of its own.

## Use it

```sh
cd examples/traefik
cp ../../.env.example .env
mkdir -p restore
```

Edit `.env`. Set `APP_URL` to your **https** address, and add the two values
this example needs on top of the normal ones:

```ini
APP_URL=https://forum.example.com
FORUM_HOST=forum.example.com
ACME_EMAIL=you@example.com
```

Then:

```sh
docker compose up -d
docker compose logs -f flarum      # first boot takes 1-2 minutes
```

## Before you start it

**DNS must already point at this machine.** Let's Encrypt validates over HTTP on
port 80, so if `FORUM_HOST` does not resolve here when the stack first comes up,
the challenge fails and Traefik serves its own self-signed certificate instead.
Fix the DNS and restart Traefik to retry.

**Ports 80 and 443 must be free.** Traefik binds both. If something else on the
host already holds them, stop it first.

**`APP_URL` must be `https://`.** Flarum builds absolute URLs from it, so an
`http://` value behind a TLS proxy produces mixed-content failures where assets
and the websocket silently do not load.

## Realtime

Live updates work without extra configuration. nginx inside the app image
proxies the realtime websocket at `/app`, so the single Traefik router covers
both the forum and the websocket — Traefik forwards the `Upgrade` and
`Connection` headers by default. Set `REALTIME_ENABLED=true` in `.env` to turn
the server on.

## Backups

Identical to the root stack — `restore/` is mounted at `/restore`:

```sh
docker compose exec flarum backup.sh
```

See the main [README](../../README.md) for the full backup and restore flow.
