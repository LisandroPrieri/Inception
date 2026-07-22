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
    rm -rf /var/lib/apt/lists/* && \
    rm -rf /var/lib/mysql/*

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
- **`rm -rf /var/lib/mysql/*`** fixes a silent first-boot bug. The Debian package's post-install script runs `mysql_install_db` itself, so a stock build ships an already-populated data directory (`ibdata1`, `mysql/`, `sys/`, …) baked into the image. That matters because Docker **pre-populates an empty volume by copying whatever the image holds at that path** — so on a genuine first boot the fresh volume arrives already containing `mysql/`, the guard in `init.sh` concludes the database is initialised, and setup is skipped: no `wordpress` database, no WordPress user, no root password. Emptying the directory at build time makes "volume is empty" and "database not initialised" mean the same thing again. (Confirmed by mounting an empty bind-backed volume over a stock build: all ten files appeared before the entrypoint ran.)

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

    mariadbd --user=mysql --datadir=/var/lib/mysql &
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

exec mariadbd --user=mysql --datadir=/var/lib/mysql
```

Two jobs: set up the database on first boot, then become the server.

### Which program is which

Everything here ships with the `mariadb-server` package — nothing is a script we wrote apart from `init.sh` itself. The names are confusing because they all start with "mysql" while doing unrelated jobs:

| Command | What it is | Role |
|---|---|---|
| `mariadbd` (`mysqld`) | The **server** — a daemon | Owns the data files, listens on 3306, answers queries. This *is* the database. |
| `mariadb` (`mysql`) | The **client** | Connects to a running server, sends SQL, prints results. |
| `mariadb-admin` (`mysqladmin`) | An **admin client** | Speaks a fixed command set, not SQL: `ping`, `shutdown`, `status`, `password`… |
| `mariadb-install-db` (`mysql_install_db`) | A **one-shot setup tool** | Creates the system tables in an empty data directory. |
| `mariadbd-safe` (`mysqld_safe`) | A **wrapper shell script** | Launches the server and relaunches it if it crashes. Deliberately unused here — see PID 1. |

The trailing **`d`** stands for *daemon*, the Unix convention for a background service (`sshd`, `httpd`, `crond`). So `mysqld` is the server; `mysql` without the `d` is the client that talks to it. Every `mysql*` name is a compatibility symlink to its `mariadb*` twin, kept so scripts written for MySQL keep working (`/usr/sbin/mysqld -> mariadbd`, `/usr/bin/mysqladmin -> mariadb-admin`, and so on).

Two of these are worth understanding rather than memorising:

- **Why a separate `install-db` tool instead of more SQL?** Chicken-and-egg: the server reads accounts and grants from tables inside the `mysql` database, but creating tables normally requires SQL, which requires a running server, which requires those tables. `mariadb-install-db` breaks the cycle from outside — it writes the initial table files straight to disk with no server involved. That is what "bootstrapping" means: building the thing a system needs before it can run at all.
- **Why avoid `mysqld_safe`?** Its job — restarting a crashed database — already belongs to Docker (`restart: always`). Worse, it is actively harmful as PID 1; the reason is in the PID 1 section below.

### Line by line

- **`set -e`** — abort on the first failed command, so the container dies at the actual problem instead of producing confusing downstream errors.
- **`DB_PASSWORD=$(cat /run/secrets/db_password)`** — `$( )` captures a command's output into a variable. Compose mounts each secret declared for this service as a plain file at `/run/secrets/<name>` (the name comes from the top-level `secrets:` block in `docker-compose.yml`, not the host filename). Reading it here, once, keeps the rest of the script identical to a version that used environment variables — only the *source* of the two passwords changed.
- **`mkdir -p /run/mysqld && chown mysql /run/mysqld`** — `/run` is wiped on every container start, and the server needs a writable directory there for two runtime files: its Unix **socket** (`/run/mysqld/mysqld.sock`) and its pid file. `chown mysql` because the server drops privileges to the `mysql` account before creating them. Omit this and the server cannot open its socket, so the readiness loop below waits forever.
- **The first-boot guard** — `[ ! -d ... ]` tests "is not a directory". `/var/lib/mysql` is the volume; MariaDB's own system database lives in a subfolder named `mysql`, so its absence means the volume is fresh. First start: run setup. Every restart: skip it. This makes the container safe to destroy and recreate endlessly. (It only works because the Dockerfile empties the image's copy of that directory — see above.)
- **`mysql_install_db --user=mysql --datadir=/var/lib/mysql`** — bootstraps the empty volume. `--user=mysql` makes the new files owned by the `mysql` OS account; without it root owns them and the server, which drops to `mysql`, cannot write. `--datadir` says where to create them.
- **Temporary server** — SQL needs a running server, but the final server must be the foreground PID 1 process. So: start in the background (`&`), wait for readiness, run the SQL, shut down cleanly, then start for real. `--user=mysql` is required because `mariadbd` launched by root refuses to run unless told which unprivileged account to become.
- **`until mysqladmin ping --silent`** — wait for a *condition*, not a duration; a `sleep N` is a guess that fails on slow days. `ping` exits 0 once the server accepts connections, and `until` loops while a command fails. `--silent` suppresses both the success message and the connection-refused noise, leaving the exit status as the only signal. No credentials are passed because a fresh install authenticates `root` through the **unix_socket** plugin: the server trusts that the caller is OS-root inside the container. That is also why the next line's `mysql -u root` needs no password.
- **`mysqladmin -u root -p"${DB_ROOT_PASSWORD}" shutdown`** — stops the temporary server *cleanly*: refuse new connections, flush InnoDB's in-memory changes to disk, exit. The password is glued to `-p` with no space (a space would make it a separate argument, read as a database name), and it is needed now only because the `ALTER USER` below just switched root from socket authentication to password authentication — the rules changed mid-script.
- **`exec mariadbd --user=mysql --datadir=/var/lib/mysql`** — the real server. `--datadir` is stated explicitly so the script does not depend silently on a config file's contents. For `exec`, see PID 1 below.

### The heredoc

```bash
mysql -u root <<-EOF
    ...SQL...
EOF
```

`<<EOF` is a **here-document**: the shell feeds every line up to the terminator into the command's standard input. The `mysql` client, given no query argument, reads SQL from stdin — so this is exactly equivalent to typing those five statements at an interactive `mysql>` prompt, without needing a temporary file.

- **The terminator is unquoted (`EOF`, not `'EOF'`), so the shell expands the body.** `${MYSQL_DATABASE}` becomes `wordpress` before the client sees a single byte. Quoting it would pass the text through literally and create a database named `${MYSQL_DATABASE}`. This is what lets non-secret configuration (`MYSQL_DATABASE`, `MYSQL_USER` from `.env`) and secrets (`DB_PASSWORD`, `DB_ROOT_PASSWORD`, read from `/run/secrets/`) meet in one place without either being hardcoded.
- **`\`` — escaped backticks.** In SQL, backticks quote an *identifier* so a database name may contain hyphens or reserved words. But an unquoted heredoc also performs command substitution, so bare backticks would make bash try to execute their contents. The backslash prevents that.
- **`<<-` strips leading tabs** — from the body *and* the terminator, which is what lets a heredoc be indented to match the `if` block around it. The catch: it strips **tabs only, never spaces**. Our SQL lines are indented with two real tab characters, so the `-` is doing genuine work here; re-indent them with spaces and the SQL would still run (SQL ignores leading whitespace) but the mechanism would silently stop applying. The same rule governs the terminator — an `EOF` indented with spaces is not recognised at all, and bash reports an unexpected end of file.

### The SQL

- **`CREATE DATABASE IF NOT EXISTS`** — creates the empty schema WordPress later fills with `wp_posts`, `wp_users` and the rest. `IF NOT EXISTS` makes the statement idempotent; belt-and-braces, since the first-boot guard already prevents a second run.
- **`CREATE USER '${MYSQL_USER}'@'%'`** — in MariaDB an account is a **pair**: username *and* host pattern, so `'wp_user'@'localhost'` and `'wp_user'@'%'` are two different accounts with separate passwords and privileges. `%` is the SQL wildcard for "any host", required because WordPress connects from another container — a different IP on the bridge network. This is the account-level twin of the `bind-address` problem: one is the server refusing to *listen* beyond localhost, the other an account refusing to be *used* from beyond it. `IDENTIFIED BY` supplies the plaintext password, which the server hashes before storing.
- **`GRANT ALL PRIVILEGES ON \`${MYSQL_DATABASE}\`.*`** — a newly created account has **no** rights at all; it can connect and see nothing. This grants every privilege (SELECT, INSERT, UPDATE, DELETE, CREATE, DROP, ALTER, INDEX…) on every table of that one database. WordPress genuinely needs the schema-changing ones, because its installer creates its own tables on first run. The scope is deliberately one database rather than `*.*`, so this account can never touch the `mysql` system tables.
- **`ALTER USER 'root'@'localhost'`** — replaces root's socket authentication with a password. Scoped to `localhost`, so the admin account stays reachable only from inside the container.
- **`DELETE FROM mysql.global_priv WHERE user=''`** — removes the **anonymous accounts**. `mysql_install_db` creates two of them, `''@'localhost'` and `''@'<container hostname>'`, with an empty username and no password. They are not merely untidy: MariaDB resolves a login against the *most specific host pattern* first, so a connection made from inside the container matches the anonymous `localhost` entry before it ever reaches `'wp_user'@'%'`, and the password check then fails against an account that has no password. Deleting them is what `mysql_secure_installation` does on a normal install; we do it here because that tool is interactive and cannot run unattended.
- **`DROP DATABASE IF EXISTS test`** — the same installer leaves an empty `test` database that any account may write to. Nothing uses it; removing it keeps the surface minimal.
- **`FLUSH PRIVILEGES`** — reloads the in-memory grant tables from disk. `CREATE USER`, `GRANT` and `ALTER USER` already update memory on their own, so this would be ceremonial on its own — but the `DELETE` above edits a grant table *directly*, and a direct write is exactly the case that requires an explicit reload. Without it the deleted accounts would keep working until the next restart.

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
2. **PID 1 alone receives Docker's signals.** `docker compose down` sends SIGTERM to PID 1, waits 10 seconds, then SIGKILLs. Without `exec`, bash would remain PID 1 with the server as a child; bash does not forward signals, so the server would never hear SIGTERM and would be force-killed mid-write. `exec` replaces the shell with `mariadbd` (same PID, new program), so the server receives SIGTERM directly, flushes to disk, and exits cleanly.

**Why not `mysqld_safe` as PID 1?** Because line 41 of `/usr/bin/mariadbd-safe` reads `trap '' 1 2 3 15 # we shouldn't let anyone kill us` — `trap ''` means *ignore*, and 15 is SIGTERM. On bare metal that stubbornness is the point: the supervisor should survive to relaunch a crashed server. As PID 1 it is a bug. `docker compose down` sends SIGTERM, PID 1 discards it, Docker waits out the full 10-second grace period and SIGKILLs — so *every* shutdown becomes a hard kill of a running database. `mariadbd` sets no such trap and stops cleanly, so the script calls it directly.

**Why a clean stop matters.** InnoDB, MariaDB's storage engine, does not write every change straight to the table files — that would be far too slow. It caches pages in RAM (the *buffer pool*), modifies them there, and flushes them in batches, with a small sequential redo log as the durability guarantee. So at any instant, committed data may exist only in memory plus that log. A clean shutdown flushes the dirty pages and checkpoints the log; a SIGKILL discards memory and forces InnoDB into *crash recovery* on the next start, replaying the log to reconstruct what was lost. It usually succeeds — but it is the recovery path, not the normal one, and it is where corruption comes from.

The script therefore runs `mariadbd` twice, differently: once with `&` (background, temporary, for setup) and once with `exec` (foreground, replacing the shell, as the real PID 1). Same program, two roles.

## Testing

```
docker compose up --build mariadb
```

Setup runs only on a genuine first boot, so any change to the SQL needs `make re` (or a deleted volume) before it can be observed — restarting an initialised container will not re-run it.

1. **Login + database exist:** `docker exec -it mariadb mysql -u wp_user -p`, then `SHOW DATABASES;` — expect `wordpress`. Proves the init script ran and configuration flowed through. This is also the test that fails if the anonymous accounts are still present (see Issues below).
2. **Volume captured the data:** `ls /home/lprieri/data/mariadb` on the host — expect real database files (`ibdata1`, `mysql/`, `wordpress/`).
3. **Persistence / idempotence:** `docker compose down && docker compose up mariadb` — second start must skip `mysql_install_db` (guard sees existing data) and the database must still be there.
4. **No leftover accounts:** `docker exec mariadb mysql -u root -p -e "SELECT user,host FROM mysql.global_priv;"` — expect exactly `PUBLIC`, `wp_user@%`, `mariadb.sys@localhost`, `mysql@localhost`, `root@localhost`. Any row with an empty username means the cleanup did not run.
5. **Clean shutdown:** `time docker compose down` — should return in about a second with `Shutdown complete` in `docker logs`. Ten seconds means PID 1 ignored SIGTERM and Docker had to SIGKILL it.

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
- **`ERROR 1045 (28000): Access denied for user 'wp_user'@'localhost'`** — the documented login test failed even though the account existed with the right password, and even though WordPress itself connected fine. The account was created as `'wp_user'@'%'`, but `mysql_install_db` had also left two anonymous accounts (`''@'localhost'` and `''@'<container hostname>'`). MariaDB matches the most specific host pattern first, so a connection from *inside* the container hit the passwordless anonymous entry instead of the wildcard one and rejected the password. WordPress was unaffected because it connects from another container, whose IP matches `%` and not `localhost` — so the bug was invisible in normal use and only appeared under manual testing. Adding `-h 127.0.0.1` does not help: the client still reports the host as `localhost`. Fixed by deleting the anonymous accounts in the init SQL.
- **Setup silently skipped on a real first boot** — the Debian package runs `mysql_install_db` during image build, and Docker seeds an empty volume from whatever the image holds at that path, so the "is this volume fresh?" guard saw a `mysql/` directory that came from the image rather than from a previous run. The container then started with no `wordpress` database and no WordPress user. Fixed by emptying `/var/lib/mysql` in the Dockerfile.