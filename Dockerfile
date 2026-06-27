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
RUN curl -sSLf --retry 5 --retry-delay 2 --retry-connrefused \
        -o /usr/local/bin/install-php-extensions \
        https://github.com/mlocati/docker-php-extension-installer/releases/download/2.11.1/install-php-extensions \
    && chmod +x /usr/local/bin/install-php-extensions \
    && install-php-extensions \
        bcmath ctype curl dom exif fileinfo filter gd hash intl json \
        mbstring openssl pcre pdo session sodium tokenizer xml \
        pdo_mysql opcache redis pcntl sockets zip

# Composer baked in (Flarum create-project / extension requires run at runtime
# against the data volume, but the binary is present in the image).
RUN curl -sS --retry 5 --retry-delay 2 --retry-connrefused \
        https://getcomposer.org/installer \
    | php -- --install-dir=/usr/local/bin --filename=composer

# Baked config + boot scripts (no runtime download).
COPY nginx.conf       /etc/nginx/conf.d/flarum.conf
COPY supervisord.conf /etc/supervisor/conf.d/supervisord.conf
COPY entrypoint.sh    /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh \
    && rm -f /etc/nginx/sites-enabled/default /etc/nginx/conf.d/default.conf 2>/dev/null || true

WORKDIR /var/www/html

EXPOSE 80 6001

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
