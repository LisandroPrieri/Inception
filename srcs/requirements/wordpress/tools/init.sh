#!/bin/bash
# Container entrypoint: install WordPress on first boot, then run php-fpm as PID 1.
set -e

# Secrets, mounted by Compose as files under /run/secrets/.
DB_PASSWORD=$(cat /run/secrets/db_password)
. /run/secrets/credentials        # sets WP_ADMIN_PASSWORD and WP_USER_PASSWORD

# php-fpm needs this runtime dir for its pid file; /run is wiped on every start.
mkdir -p /run/php

# First boot only: no wp-config.php means the volume is fresh.
if [ ! -f wp-config.php ]; then
	# Download WordPress core into the current dir (/var/www/html = the volume).
	wp core download --allow-root

	# depends_on only waits for the mariadb container to START, not for the
	# database to accept connections. Poll with the DB client (the reason
	# mariadb-client is in the Dockerfile) until our user can run a query.
	until mariadb -h mariadb -u"${MYSQL_USER}" -p"${DB_PASSWORD}" \
			-e "SELECT 1" >/dev/null 2>&1; do
		sleep 1
	done

	# Generate wp-config.php. dbhost is the mariadb service name, resolved by
	# Docker's internal DNS on the bridge network.
	wp config create \
		--dbname="${MYSQL_DATABASE}" \
		--dbuser="${MYSQL_USER}" \
		--dbpass="${DB_PASSWORD}" \
		--dbhost=mariadb \
		--allow-root

	# Create the WP tables and the administrator account.
	wp core install \
		--url="https://${DOMAIN_NAME}" \
		--title="Inception" \
		--admin_user="${WP_ADMIN_USER}" \
		--admin_password="${WP_ADMIN_PASSWORD}" \
		--admin_email="${WP_ADMIN_EMAIL}" \
		--skip-email \
		--allow-root

	# Second, non-administrator user.
	wp user create \
		"${WP_USER}" "${WP_USER_EMAIL}" \
		--role=author \
		--user_pass="${WP_USER_PASSWORD}" \
		--allow-root

	# Everything was created as root; hand the tree to the user php-fpm runs as.
	chown -R www-data:www-data /var/www/html
fi

# Become php-fpm in the foreground: -F stops it daemonizing, so it stays PID 1
# and receives Docker's SIGTERM directly. $PHP_VERSION comes from the Dockerfile's ENV.
exec php-fpm${PHP_VERSION} -F