# ==========================================================================
# Flarum 2.0 — self-contained image (nginx + php-fpm under supervisor).
#
# Everything is baked at build time: system packages, PHP extensions, Composer,
# and the boot/entrypoint scripts. There is NO runtime fetch of a setup script
# from the network — the image is fully self-describing and reproducible.
# ==========================================================================
FROM php:8.3-fpm

# Ride over transient apt mirror/network blips during the build. Applies to
# every apt-get below, including the ones install-php-extensions spawns to pull
# gd/intl build deps.
RUN printf 'Acquire::Retries "8";\nAcquire::http::Timeout "30";\nAcquire::https::Timeout "30";\n' \
        > /etc/apt/apt.conf.d/80-retries

# System packages baked at build time — no apt at container start.
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        git unzip zip curl ca-certificates supervisor \
        netcat-openbsd mariadb-client nginx cron libgmp-dev \
    && update-ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# install-php-extensions pinned to a release tag (not /latest) so a compromised
# release can't slip into a build without a git diff.
#
# redis is pinned too. Everything else here is compiled from the PHP source
# already in the base image, but redis is fetched from pecl.php.net at build
# time — which is why v1.0.0 needed three attempts while PECL returned 504s.
# A pin does not make PECL more reliable, but it does mean a retry produces the
# SAME extension rather than whatever is newest by then.
ARG PECL_REDIS_VERSION=6.3.0
RUN curl -sSLf --retry 5 --retry-delay 2 --retry-connrefused \
        -o /usr/local/bin/install-php-extensions \
        https://github.com/mlocati/docker-php-extension-installer/releases/download/2.11.1/install-php-extensions \
    && chmod +x /usr/local/bin/install-php-extensions \
    && install-php-extensions \
        bcmath ctype curl dom exif fileinfo filter gd hash intl json \
        mbstring openssl pcre pdo session sodium tokenizer xml \
        pdo_mysql opcache "redis-${PECL_REDIS_VERSION}" pcntl sockets zip

# Composer pinned, and the installer's signature checked before it is run.
#
# This used to pipe whatever getcomposer.org served straight into php,
# unverified and unversioned: a bad day upstream became a bad image, and two
# builds of the same commit could ship different Composer versions. The
# signature check is the one the Composer project publishes for exactly this.
ARG COMPOSER_VERSION=2.10.2
RUN set -eux; \
    curl -sSLf --retry 5 --retry-delay 2 --retry-connrefused \
        -o /tmp/composer-setup.php https://getcomposer.org/installer; \
    expected="$(curl -sSLf --retry 5 https://composer.github.io/installer.sig)"; \
    actual="$(php -r 'echo hash_file("sha384", "/tmp/composer-setup.php");')"; \
    if [ "$expected" != "$actual" ]; then \
        echo "composer installer signature mismatch" >&2; exit 1; \
    fi; \
    php /tmp/composer-setup.php --install-dir=/usr/local/bin --filename=composer \
        --version="${COMPOSER_VERSION}"; \
    rm -f /tmp/composer-setup.php; \
    composer --version

# ── The pinned Flarum skeleton ───────────────────────────────────────────────
# Flarum itself, resolved at BUILD time from the committed lock rather than
# from Packagist when a container first starts. Build-time network is fine and
# reproducible — the lock decides what gets installed. Runtime network is not:
# it made the same image tag produce different forums a week apart and left no
# offline install path at all. See issue #2 and skeleton/README.md.
#
# create-project supplies the skeleton's OWN files (index.php, the flarum CLI,
# public/, storage/) which are part of the flarum/flarum package and never
# appear in vendor/. --no-install skips dependency resolution, because the
# committed lock replaces its composer.json immediately below and decides that.
ARG FLARUM_VERSION=2.0.0-rc.5
ENV FLARUM_SKELETON=/opt/flarum-skeleton
ENV FLARUM_SKELETON_VERSION=${FLARUM_VERSION}

RUN COMPOSER_HOME=/tmp/composer composer create-project \
        "flarum/flarum:${FLARUM_VERSION}" "$FLARUM_SKELETON" \
        --stability=beta --no-install --no-interaction --no-progress

COPY skeleton/composer.json skeleton/composer.lock ${FLARUM_SKELETON}/

# Fail the build rather than ship a skeleton whose files and lock disagree: the
# ARG picks the package that supplies the root files, the lock picks everything
# else, and nothing else would notice them drifting apart.
RUN set -eu; \
    locked="$(php -r '$l = json_decode(file_get_contents(getenv("FLARUM_SKELETON")."/composer.lock"), true); foreach ($l["packages"] as $p) { if ($p["name"] === "flarum/core") { echo ltrim($p["version"], "v"); exit; } } exit(1);')"; \
    if [ "$locked" != "${FLARUM_VERSION}" ]; then \
        echo "FLARUM_VERSION=${FLARUM_VERSION} but skeleton/composer.lock pins flarum/core $locked" >&2; \
        exit 1; \
    fi; \
    cd "$FLARUM_SKELETON"; \
    COMPOSER_HOME=/tmp/composer composer install \
        --no-dev --no-interaction --no-progress --optimize-autoloader; \
    rm -rf /tmp/composer

# Baked config + boot scripts (no runtime download).
COPY nginx.conf       /etc/nginx/conf.d/flarum.conf
COPY supervisord.conf /etc/supervisor/conf.d/supervisord.conf
COPY entrypoint.sh    /usr/local/bin/entrypoint.sh
COPY backup.sh        /usr/local/bin/backup.sh
RUN chmod +x /usr/local/bin/entrypoint.sh /usr/local/bin/backup.sh \
    && rm -f /etc/nginx/sites-enabled/default /etc/nginx/conf.d/default.conf 2>/dev/null || true

WORKDIR /var/www/html

EXPOSE 80 6001

# docker-compose.yml declares the same check, but a compose-level healthcheck
# does not travel with the image — anyone running `docker run`, or pulling this
# into their own orchestrator, gets nothing. Declaring it here makes the image
# self-describing; compose's copy simply overrides it with identical values.
#
# The long start period covers first boot: composer create-project, migrations
# and extension installs take 1-2 minutes on a cold volume, and the container
# must not be declared unhealthy while that is still legitimately running.
HEALTHCHECK --interval=30s --timeout=5s --start-period=240s --retries=5 \
    CMD curl -fsS -o /dev/null http://127.0.0.1/ || exit 1

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
