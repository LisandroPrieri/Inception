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
COPY --chmod=755 tools/init.sh /usr/local/bin/init.sh

EXPOSE 3306

ENTRYPOINT ["/usr/local/bin/init.sh"]
```

- **`FROM debian:bookworm`** — pinned release, as the subject requires (penultimate stable; `latest` is forbidden because it makes builds non-reproducible).
- **`RUN` chains update + install + cleanup in one instruction.** `&&` stops the build if any step fails. The cleanup (`rm -rf /var/lib/apt/lists/*` — apt's downloaded package indexes) must be in the *same* RUN: each RUN produces one immutable layer, and deleting files in a later layer only shadows them without reclaiming the space.
- **`COPY`** is the only way project files enter the image; the container cannot see the repo at runtime.
- **`EXPOSE 3306`** is documentation only. It does not publish anything — `ports:` in compose publishes; EXPOSE merely declares. MariaDB has no `ports:` entry, so it is reachable only on the internal network.
- **`ENTRYPOINT`** attaches a note to the image: when a container starts, run this script. That process becomes PID 1.
- **`COPY --chmod=755`** sets the executable bit in the same layer as the copy. A separate `RUN chmod +x` afterward would work too, but layers record metadata changes by copying the whole file up into a new layer — one instruction avoids the duplicate.

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

DB_PASSWORD=$(cat /run/secrets/db_password)
DB_ROOT_PASSWORD=$(cat /run/secrets/db_root_password)

mkdir -p /run/mysqld && chown mysql /run/mysqld

if [ ! -d "/var/lib/mysql/mysql" ]; then
    mysql_install_db --user=mysql --datadir=/var/lib/mysql

    mysqld_safe --datadir=/var/lib/mysql &
    until mysqladmin ping --silent; do sleep 1; done

    mysql -u root <<-EOF
        CREATE DATABASE IF NOT EXISTS \`${MYSQL_DATABASE}\`;
        CREATE USER IF NOT EXISTS '${MYSQL_USER}'@'%' IDENTIFIED BY '${DB_PASSWORD}';
        GRANT ALL PRIVILEGES ON \`${MYSQL_DATABASE}\`.* TO '${MYSQL_USER}'@'%';
        ALTER USER 'root'@'localhost' IDENTIFIED BY '${DB_ROOT_PASSWORD}';
        FLUSH PRIVILEGES;
EOF

    mysqladmin -u root -p"${DB_ROOT_PASSWORD}" shutdown
fi

exec mysqld_safe --datadir=/var/lib/mysql
```

Two jobs: set up on first boot, then become the server.

- **`set -e`** — abort on the first failed command, so the container dies at the actual problem instead of producing confusing downstream errors.
- **`DB_PASSWORD=$(cat /run/secrets/db_password)`** — Compose mounts each secret declared for this service as a plain file at `/run/secrets/<name>` (the name comes from the top-level `secrets:` block in `docker-compose.yml`, not the host filename). Reading it into a shell variable here, once, keeps the rest of the script identical to a version that used environment variables — only the *source* of the two passwords changed.
- **The first-boot guard** — `/var/lib/mysql` is the volume. MariaDB's own system database lives in a subfolder named `mysql`; its absence means the volume is fresh. First start: run setup. Every restart: skip it. This makes the container safe to destroy and recreate endlessly.
- **Temporary server** — SQL needs a running server, but the final server must be the foreground PID 1 process. So: start in the background (`&`), wait for readiness, run the SQL, shut down cleanly, then start for real.
- **`until mysqladmin ping`** — wait for a *condition*, not a duration. A `sleep N` is a guess that fails on slow days.
- **The heredoc** — bash substitutes `${MYSQL_*}` and `${DB_*}` before passing the SQL to the client. `MYSQL_DATABASE`/`MYSQL_USER` arrive via `.env` (non-secret); `DB_PASSWORD`/`DB_ROOT_PASSWORD` arrive via the secret files read above. Credentials are never hardcoded and never pass through `.env`.
- **`'user'@'%'`** — the WordPress user may connect from any host; it connects from another container, so `@'localhost'` would lock it out (the account-level twin of the bind-address problem).
- **`exec mysqld_safe`** — see PID 1 below.

### Why setup happens at runtime, not build time

1. **Secrets** — anything a build-time RUN touches is frozen into an inspectable layer (`docker history`). Passwords must arrive at runtime — as files Compose mounts from `secrets/` — leaving the image itself clean.
2. **The volume doesn't exist at build time** — volumes are plugged in when a container starts. Anything written to `/var/lib/mysql` during build would be hidden when the volume mounts over that path.
3. **Separation** — images hold definition, volumes hold data. A database is data; baking it into the image would reset it on every rebuild.

Rule of thumb: secret-free definition → image; secrets and data → runtime and volume.

### Secrets vs plain env vars, concretely

Earlier this script read `${MYSQL_PASSWORD}`/`${MYSQL_ROOT_PASSWORD}` straight from the environment (`.env` → compose `env_file:` → container env). Both variables have since moved into `secrets/db_password.txt` and `secrets/db_root_password.txt`, declared under `secrets:` in `docker-compose.yml` and granted to this service there. The practical difference: an env var is visible to `docker inspect mariadb` and to every child process this container ever spawns; a secret is a file only a process that deliberately reads it ever sees. `.env` still carries `MYSQL_DATABASE`/`MYSQL_USER` — a database name and a username aren't credentials, so they stay as ordinary configuration.

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

## Testing (secrets)

```
docker exec mariadb ls -l /run/secrets/
docker exec mariadb cat /run/secrets/db_password
```

Confirms both files are mounted and readable before trusting the rest of the script. After `make re` (a genuine first boot), the MariaDB login test above should still succeed with the password from `secrets/db_password.txt` — proving the container got it from the secret file, not a leftover env var.

## Issues encountered

- **`permission denied ... /var/run/docker.sock`** — the user wasn't in the `docker` group *in the current session*. Membership is read at login; `groups` (session) vs `groups <user>` (on disk) reveals the mismatch. Fix: `usermod -aG docker <user>` if needed, then a real logout/reboot.
- **`failed to mount local volume ... no such file or directory`** — bind-mount source directories are not auto-created with these driver_opts. Fix: `mkdir -p /home/lprieri/data/mariadb` — now guaranteed by the Makefile's `dirs` rule, so the project works on a fresh machine.
- **Nearly empty `docker logs`** — the Debian package logs to syslog, absent in the container. Fixed in `50-server.cnf` by redirecting the error log to stderr.