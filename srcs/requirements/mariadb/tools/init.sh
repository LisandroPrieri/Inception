#!/bin/bash
# Container entrypoint: initialise the database on first boot, then become the server.

# Abort on the first failing command, so the container dies at the real problem.
set -e

# Compose mounts each declared secret as a file under /run/secrets/<name>.
# Reading them here keeps the passwords out of the environment and out of `docker inspect`.
DB_PASSWORD=$(cat /run/secrets/db_password)
DB_ROOT_PASSWORD=$(cat /run/secrets/db_root_password)

# /run is empty on every start; the server needs this directory for its socket and
# pid file, owned by the 'mysql' account it drops privileges to.
mkdir -p /run/mysqld && chown mysql /run/mysqld

# First run only: the data directory has no 'mysql' system db yet
if [ ! -d "/var/lib/mysql/mysql" ]; then
	# Write the system tables straight to disk; no server can start without them.
	mysql_install_db --user=mysql --datadir=/var/lib/mysql

	# Temporary server, backgrounded with '&' so the script keeps going.
	# --user is required: mariadbd refuses to run as root unless told who to become.
	mariadbd --user=mysql --datadir=/var/lib/mysql &

	# Wait for a condition, not a duration. No password needed yet: a fresh install
	# authenticates root through the unix_socket plugin.
	until mysqladmin ping --silent; do sleep 1; done

	# Heredoc feeds SQL on stdin. EOF is unquoted, so the shell expands ${...} first;
	# <<- strips the leading tabs (tabs only, never spaces).
	mysql -u root <<-EOF
		CREATE DATABASE IF NOT EXISTS \`${MYSQL_DATABASE}\`;
		CREATE USER IF NOT EXISTS '${MYSQL_USER}'@'%' IDENTIFIED BY '${DB_PASSWORD}';
		GRANT ALL PRIVILEGES ON \`${MYSQL_DATABASE}\`.* TO '${MYSQL_USER}'@'%';
		ALTER USER 'root'@'localhost' IDENTIFIED BY '${DB_ROOT_PASSWORD}';
		DELETE FROM mysql.global_priv WHERE user='';
		DROP DATABASE IF EXISTS test;
		FLUSH PRIVILEGES;
EOF

	# Stop cleanly so InnoDB flushes to disk. -p is needed now:
	# the ALTER USER above just swapped root from socket auth to password auth.
	mysqladmin -u root -p"${DB_ROOT_PASSWORD}" shutdown
fi

# Become the real server: exec replaces bash, so mariadbd is PID 1 itself and
# receives Docker's SIGTERM directly instead of being force-killed.
exec mariadbd --user=mysql --datadir=/var/lib/mysql
