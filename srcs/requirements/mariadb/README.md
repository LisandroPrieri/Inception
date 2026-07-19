# MariaDB container

The database service. First container built, because the dependency chain runs one direction: WordPress needs a working database, NGINX needs a working WordPress. Building bottom-up means each layer can be tested in isolation before the next depends on it.

Three files define it:

| File | Role | When it acts |
|---|---|---|
| `Dockerfile` | What goes in the image | Build time |
| `conf/50-server.cnf` | How MariaDB behaves | Read at server startup |
| `tools/init.sh` | What happens when the container starts | Runtime, as PID 1 |

## Dockerfile

```dockerfile
FROM debian:bookworm

RUN apt-get update && apt-get install -y mariadb-server && \
    rm -rf /var/lib/apt/lists/*

COPY conf/50-server.cnf /etc/mysql/mariadb.conf.d/50-server.cnf
COPY tools/init.sh /usr/local/bin/init.sh
RUN chmod +x /usr/local/bin/init.sh

EXPOSE 3306

ENTRYPOINT ["/usr/local/bin/init.sh"]
```

- **`FROM debian:bookworm`** — pinned release, as the subject requires (penultimate stable; `latest` is forbidden because it makes builds non-reproducible).
- **`RUN` chains update + install + cleanup in one instruction.** `&&` stops the build if any step fails. The cleanup (`rm -rf /var/lib/apt/lists/*` — apt's downloaded package indexes) must be in the *same* RUN: each RUN produces one immutable layer, and deleting files in a later layer only shadows them without reclaiming the space.
- **`COPY`** is the only way project files enter the image; the container cannot see the repo at runtime.
- **`EXPOSE 3306`** is documentation only. It does not publish anything — `ports:` in compose publishes; EXPOSE merely declares. MariaDB has no `ports:` entry, so it is reachable only on the internal network.
- **`ENTRYPOINT`** attaches a note to the image: when a container starts, run this script. That process becomes PID 1.
- Note: `RUN chmod` after `COPY` creates a full duplicate of the file in a new layer (layers record metadata changes by copying the file up). `COPY --chmod=755` does both in one layer and avoids the duplication.

## conf/50-server.cnf

```ini
[mysqld]
bind-address = 0.0.0.0
port = 3306
log_error = /dev/stderr
skip-log-syslog
```

- **`bind-address = 0.0.0.0`** is the reason this file exists. Debian's default binds to 127.0.0.1 — localhost *inside the container* — making the server unreachable from the WordPress container, which is a different host on the bridge network. Listening on all interfaces is safe here because the network is isolated and no port is published.
- **`log_error = /dev/stderr` / `skip-log-syslog`** — the Debian package logs to syslog, which doesn't exist in a minimal container, leaving `docker logs` empty. Redirecting to stderr follows the container convention: log to stdout/stderr and let Docker collect it.
- **Why the name `50-server.cnf`:** MariaDB reads the whole `/etc/mysql/mariadb.conf.d/` directory in alphabetical order, later files overriding earlier ones. The numeric prefix controls load order (the same `.d` convention as `/etc/sysctl.d/` etc.). Using the exact stock filename means our file *replaces* the package's server config; every unmentioned setting falls back to built-in defaults.
- **Why a file instead of `sed` in the Dockerfile:** the config stays readable as a file, `COPY` is deterministic where `sed` silently breaks if the package's file changes, and the `conf/` pattern is needed for NGINX anyway — so all three services keep the same shape.

## tools/init.sh

```bash
#!/bin/bash
set -e

if [ ! -d "/var/lib/mysql/mysql" ]; then
    mysql_install_db --user=mysql --datadir=/var/lib/mysql

    mysqld_safe --datadir=/var/lib/mysql &
    until mysqladmin ping --silent; do sleep 1; done

    mysql -u root <<-EOF
        CREATE DATABASE IF NOT EXISTS \`${MYSQL_DATABASE}\`;
        CREATE USER IF NOT EXISTS '${MYSQL_USER}'@'%' IDENTIFIED BY '${MYSQL_PASSWORD}';
        GRANT ALL PRIVILEGES ON \`${MYSQL_DATABASE}\`.* TO '${MYSQL_USER}'@'%';
        ALTER USER 'root'@'localhost' IDENTIFIED BY '${MYSQL_ROOT_PASSWORD}';
        FLUSH PRIVILEGES;
EOF

    mysqladmin -u root -p"${MYSQL_ROOT_PASSWORD}" shutdown
fi

exec mysqld_safe --datadir=/var/lib/mysql
```

Two jobs: set up on first boot, then become the server.

- **`set -e`** — abort on the first failed command, so the container dies at the actual problem instead of producing confusing downstream errors.
- **The first-boot guard** — `/var/lib/mysql` is the volume. MariaDB's own system database lives in a subfolder named `mysql`; its absence means the volume is fresh. First start: run setup. Every restart: skip it. This makes the container safe to destroy and recreate endlessly.
- **Temporary server** — SQL needs a running server, but the final server must be the foreground PID 1 process. So: start in the background (`&`), wait for readiness, run the SQL, shut down cleanly, then start for real.
- **`until mysqladmin ping`** — wait for a *condition*, not a duration. A `sleep N` is a guess that fails on slow days.
- **The heredoc** — bash substitutes `${MYSQL_*}` before passing the SQL to the client; this is where `.env` values become database reality. Credentials are never hardcoded: `.env` → compose `env_file:` → container environment → this script.
- **`'user'@'%'`** — the WordPress user may connect from any host; it connects from another container, so `@'localhost'` would lock it out (the account-level twin of the bind-address problem).
- **`exec mysqld_safe`** — see PID 1 below.

### Why setup happens at runtime, not build time

1. **Secrets** — anything a build-time RUN touches is frozen into an inspectable layer (`docker history`). Passwords must arrive at runtime via environment, leaving the image clean.
2. **The volume doesn't exist at build time** — volumes are plugged in when a container starts. Anything written to `/var/lib/mysql` during build would be hidden when the volume mounts over that path.
3. **Separation** — images hold definition, volumes hold data. A database is data; baking it into the image would reset it on every rebuild.

Rule of thumb: secret-free definition → image; secrets and data → runtime and volume.

## PID 1

The ENTRYPOINT process is the container's PID 1, and two rules follow:

1. **The container lives exactly as long as PID 1.** The server must run in the foreground; a daemonizing parent that exits would kill the container. Keeping a container alive with `tail -f /dev/null` or `sleep infinity` is explicitly forbidden: PID 1 then knows nothing about the service, so a crashed database leaves a "healthy" container running nothing.
2. **PID 1 alone receives Docker's signals.** `docker compose down` sends SIGTERM to PID 1, waits 10 seconds, then SIGKILLs. Without `exec`, bash would remain PID 1 with mysqld as a child; bash does not forward signals, so mysqld would never hear SIGTERM and would be force-killed mid-write — how databases corrupt. `exec` replaces the shell with mysqld (same PID, new program), so the server receives SIGTERM directly, flushes to disk, and exits cleanly.

The script therefore runs `mysqld_safe` twice, differently: once with `&` (background, temporary, for setup) and once with `exec` (foreground, replacing the shell, as the real PID 1).

## Testing

```
docker compose up --build mariadb
```

1. **Login + database exist:** `docker exec -it mariadb mysql -u wp_user -p`, then `SHOW DATABASES;` — expect `wordpress`. Proves the init script ran and env variables flowed through.
2. **Volume captured the data:** `ls /home/lprieri/data/mariadb` on the host — expect real database files (`ibdata1`, `mysql/`, `wordpress/`).
3. **Persistence / idempotence:** `docker compose down && docker compose up mariadb` — second start must skip `mysql_install_db` (guard sees existing data) and the database must still be there.

## Issues encountered

- **`permission denied ... /var/run/docker.sock`** — the user wasn't in the `docker` group *in the current session*. Membership is read at login; `groups` (session) vs `groups <user>` (on disk) reveals the mismatch. Fix: `usermod -aG docker <user>` if needed, then a real logout/reboot.
- **`failed to mount local volume ... no such file or directory`** — bind-mount source directories are not auto-created with these driver_opts. Fix: `mkdir -p /home/lprieri/data/mariadb` — now guaranteed by the Makefile's `dirs` rule, so the project works on a fresh machine.
- **Nearly empty `docker logs`** — the Debian package logs to syslog, absent in the container. Fixed in `50-server.cnf` by redirecting the error log to stderr.