#!/bin/bash
set -e

# Secrets, mounted by Compose as files under /run/secrets/.
DB_PASSWORD=$(cat /run/secrets/db_password)
source /run/secrets/credentials        # sets WP_ADMIN_PASSWORD and WP_USER_PASSWORD

# php-fpm needs this runtime dir for its pid file; /run is wiped on every start.
mkdir -p /run/php

# In docker-compose.yml, depends_on only waits for the mariadb container to START, not for the database to accept connections.
# Keep trying a query until one succeeds (mariadb-client is in the Dockerfile so we can do this).
until mariadb -h mariadb -u"${MYSQL_USER}" -p"${DB_PASSWORD}" \
		-e "SELECT 1" >/dev/null 2>&1; do
	sleep 1
done

if ! wp core is-installed --allow-root; then
	# Download WordPress core into the current dir (/var/www/html = the volume).
	wp core download --force --allow-root

	# Generate wp-config.php.
	# dbhost is the mariadb service name, resolved by Docker's internal DNS on the bridge network.
	wp config create --force \
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

# Become php-fpm in the foreground: -F stops it daemonizing
# $PHP_VERSION comes from the Dockerfile's ENV.
exec php-fpm${PHP_VERSION} -F