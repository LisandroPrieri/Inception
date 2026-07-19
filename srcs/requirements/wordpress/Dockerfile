FROM debian:bookworm

RUN apt-get update && apt-get install -y \
        php-fpm php-mysql php-curl php-gd php-mbstring php-xml php-zip \
        curl mariadb-client && \
    rm -rf /var/lib/apt/lists/*

RUN curl -sSL -o /usr/local/bin/wp \
        https://github.com/wp-cli/wp-cli/releases/download/v2.12.0/wp-cli-2.12.0.phar && \
    chmod +x /usr/local/bin/wp

COPY conf/www.conf /etc/php/8.2/fpm/pool.d/www.conf
COPY --chmod=755 tools/init.sh /usr/local/bin/init.sh

WORKDIR /var/www/html

EXPOSE 9000

ENTRYPOINT ["/usr/local/bin/init.sh"]