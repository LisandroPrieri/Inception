#!/bin/bash
set -e

# First run only: the data directory has no 'mysql' system db yet
if [ ! -d "/var/lib/mysql/mysql" ]; then
    mysql_install_db --user=mysql --datadir=/var/lib/mysql

    # Start a temporary server just for setup
    mysqld_safe --datadir=/var/lib/mysql &
    until mysqladmin ping --silent; do sleep 1; done

    mysql -u root <<-EOF
        CREATE DATABASE IF NOT EXISTS \`${MYSQL_DATABASE}\`;
        CREATE USER IF NOT EXISTS '${MYSQL_USER}'@'%' IDENTIFIED BY '${MYSQL_PASSWORD}';
        GRANT ALL PRIVILEGES ON \`${MYSQL_DATABASE}\`.* TO '${MYSQL_USER}'@'%';
        ALTER USER 'root'@'localhost' IDENTIFIED BY '${MYSQL_ROOT_PASSWORD}';
        FLUSH PRIVILEGES;
EOF

    # Stop the temporary server cleanly
    mysqladmin -u root -p"${MYSQL_ROOT_PASSWORD}" shutdown
fi

# Become the real server, in the foreground, as PID 1's job
exec mysqld_safe --datadir=/var/lib/mysql