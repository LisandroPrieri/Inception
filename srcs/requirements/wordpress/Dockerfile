FROM debian:bookworm

# Debian pins PHP to one version per release (bookworm ships 8.2) and puts that
# version in both the config paths and the binary name (php-fpm8.2).
# Declared once here; ENV carries it into the container for init.sh.
ARG PHP_VERSION=8.2
ENV PHP_VERSION=${PHP_VERSION}

# php-cli is required by wp-cli. It is already pulled in as a dependency of the
# extensions, but naming it makes the dependency explicit instead of accidental.
RUN apt-get update && apt-get install -y \
        php${PHP_VERSION}-fpm php${PHP_VERSION}-cli php${PHP_VERSION}-mysql \
        php${PHP_VERSION}-curl php${PHP_VERSION}-gd php${PHP_VERSION}-mbstring \
        php${PHP_VERSION}-xml php${PHP_VERSION}-zip \
        curl mariadb-client && \
    rm -rf /var/lib/apt/lists/*

RUN curl -sSL -o /usr/local/bin/wp \
        https://github.com/wp-cli/wp-cli/releases/download/v2.12.0/wp-cli-2.12.0.phar && \
    chmod +x /usr/local/bin/wp

COPY conf/www.conf /etc/php/${PHP_VERSION}/fpm/pool.d/www.conf
COPY --chmod=755 tools/init.sh /usr/local/bin/init.sh

WORKDIR /var/www/html

EXPOSE 9000

ENTRYPOINT ["/usr/local/bin/init.sh"]