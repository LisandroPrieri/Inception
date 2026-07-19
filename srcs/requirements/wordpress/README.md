# WordPress container

The application service: WordPress running under php-fpm, with no web server of its own. NGINX (separate container) handles HTTP/TLS; this container only executes PHP.

## PHP itself — the context for everything below

PHP is an interpreter: it reads a `.php` file, executes the code in it, and produces output — usually HTML. That's all. On its own it knows nothing about HTTP or browsers. WordPress is just a big pile of `.php` files; something has to receive the browser's request, get PHP to run the right file, and send the result back.

Two gaps follow from this, and the packages in the Dockerfile fill them:

1. **Who talks HTTP?** → php-fpm (this container) + NGINX (the other one)
2. **What can PHP code do beyond core language features?** → extensions (`php-mysql` and friends)

## php-fpm — the process that runs PHP for a web server

The old way was to embed PHP *inside* the web server (Apache's `mod_php`): every web server worker carried a full PHP interpreter, and a PHP crash could take the server down with it.

The modern way separates them. **FastCGI** is a small protocol that lets a web server say to another process, over a socket: "run this script, here are the request details (URL, POST data, cookies), give me back the output." **php-fpm** (*FastCGI Process Manager*) is the PHP-side daemon that speaks it:

1. It starts as a master process and pre-forks a **pool of PHP worker processes** — the "process manager" part; it spawns and kills workers based on load.
2. It listens on a socket — a Unix socket by default, but here **TCP port 9000**, because NGINX lives in a *different container* and a Unix socket file cannot cross that boundary.
3. For each incoming FastCGI request, a worker executes the PHP script and returns the output.

The request flow for any page in this project:

```
browser ──HTTPS──▶ NGINX ──FastCGI, port 9000──▶ php-fpm worker runs WordPress ──▶ queries MariaDB:3306
```

This is why the subject says the WordPress container contains "php-fpm and nothing else": NGINX owns HTTP/TLS, php-fpm owns executing PHP. Neither can do the other's job, and this division is what makes the three-container design meaningful.

## php-mysql — how PHP code talks to the database

PHP the language has no built-in ability to speak MariaDB's wire protocol. That comes from an **extension** — a compiled C library that plugs into the interpreter and exposes new functions to PHP code. The Debian package `php-mysql` installs the MySQL/MariaDB extensions (`mysqli` and `pdo_mysql`).

WordPress's database layer calls `mysqli_connect()` etc. Without this package those functions simply don't exist, and WordPress dies immediately with *"Your PHP installation appears to be missing the MySQL extension."*

Note the division of labor: **php-mysql is for PHP code** talking to the DB; the separate `mariadb-client` package is for our **shell script** (`tools/init.sh`) to poll the DB with `mysqladmin ping` before installing WordPress. Same server, two different clients.

## php-curl, php-gd, php-mbstring, php-xml, php-zip — more extensions

Same mechanism as php-mysql: each adds a capability the core interpreter lacks. These five are on WordPress's own requirements list, and each maps to a concrete feature:

| Package | Adds | WordPress uses it for |
|---|---|---|
| `php-curl` | making HTTP requests *from PHP code* | checking for core/plugin updates, fetching from other APIs — WordPress acting as an HTTP *client* |
| `php-gd` | image manipulation | generating thumbnail/medium/large sizes on every media upload, cropping |
| `php-mbstring` | multibyte (Unicode) string handling | correct length/substring operations on non-ASCII text — post content, usernames, any language beyond plain English |
| `php-xml` | parsing and writing XML | RSS feeds, sitemaps, the import/export format, XML-RPC |
| `php-zip` | reading/creating ZIP archives | plugins and themes ship as `.zip`; installing one means unzipping it from PHP |

Without them, WordPress *boots* (only the MySQL extension is truly fatal) but degrades: uploads get no thumbnails, plugin installs fail, update checks break.

One distinction worth keeping crisp: **php-fpm is a process/daemon** (how PHP runs as a service), while **php-mysql and the rest are extensions** (what PHP code is capable of). Two different axes.

## Dockerfile

```dockerfile
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
```

- **`FROM debian:bookworm`** — same pinned base as MariaDB; Docker reuses the identical base layers already on disk (layer sharing).
- **First `RUN`** — one layer: update + install + cleanup, `&&`-chained so a failure stops the build. The packages are the ones explained above, plus `curl` (used by the next instruction) and `mariadb-client` (used by `init.sh` at runtime to poll the database).
- **Second `RUN` — wp-cli.** WordPress normally installs through a browser wizard; a container can't click through one. wp-cli is the official command-line tool that does everything the wizard does, scriptably: `wp core download`, `wp config create`, `wp core install`, `wp user create`. It ships as a single `.phar` file (PHP archive — a whole PHP application in one file, runnable because this container has PHP), dropped into `/usr/local/bin/wp` so it's on `$PATH`. Version pinned, like the base image: `latest` would make builds non-reproducible.
- **`COPY conf/www.conf`** to the exact stock Debian path — replaces the package's pool config in place; every unmentioned setting keeps its built-in default. Same pattern as MariaDB's `50-server.cnf`.
- **`COPY --chmod=755`** — copy + permission in one layer, avoiding the duplicate-file cost of a separate `RUN chmod`.
- **`WORKDIR /var/www/html`** — default directory for everything after it, *including the ENTRYPOINT at runtime*. This is where the `wp_data` volume mounts, so `init.sh` runs `wp` commands without `--path` flags.
- **`EXPOSE 9000`** — documentation only. No `ports:` in compose for this service: only NGINX connects to it, over the private bridge network.
- **`ENTRYPOINT`** — `init.sh` becomes PID 1: set up on first boot, then `exec` php-fpm in the foreground. Same PID-1 discipline as MariaDB.

### What's *not* in the Dockerfile: WordPress

No `wp core download` happens at build time, deliberately. `/var/www/html` is a volume, and a volume mounts *over* whatever the image had at that path — anything baked in at build time would be invisible at runtime. So the image contains only the *machinery* (PHP, extensions, wp-cli), and WordPress itself is downloaded on first boot by `init.sh`, straight into the volume, where it survives container destruction. Image = definition, volume = data — and the WordPress files are data.

## The build, frame by frame

Docker reads the file top to bottom. Each instruction runs in a temporary container, and the filesystem changes it makes are frozen into a **layer**; the stack of layers is the image.

1. **`FROM`** — lay down the Debian floor: a minimal filesystem with apt and bash, nothing else. Reused from disk — the MariaDB image sits on the identical base layers.
2. **`RUN` (apt)** — boot a throwaway container from that floor, run the command, diff the filesystem, save the diff as a layer. After this frame the image holds PHP 8.2, php-fpm, and the mysql client tools. The `&&` chain keeps it *one* frame: deleting the apt index in a separate `RUN` would only shadow the files in a later layer, never reclaim the space.
3. **`RUN` (wp-cli)** — another throwaway container; the resulting layer is essentially one file, `/usr/local/bin/wp`. Together with apt, the only moments the build touches the network — the finished image never downloads anything again; rebuilds replay from cache.
4. **`COPY` ×2** — no container needed: lift two files out of the repo and freeze them in. This is the only door project files pass through; at runtime the container cannot see the repo at all.
5. **`WORKDIR` / `EXPOSE` / `ENTRYPOINT`** — no files change. These attach metadata to the image — sticky notes: "start in `/var/www/html`", "I expect traffic on 9000", "run `init.sh` when a container starts".

Result: a machine that knows how to run PHP and how to install WordPress — containing no WordPress.

## What happens at runtime instead

Nothing above executes again. When `docker compose up` starts a container from the image:

1. The frozen layers get a disposable writable layer on top
2. The `wp_data` volume mounts **over** `/var/www/html` (why WordPress couldn't be baked there)
3. The container joins the bridge network
4. The `.env` variables are injected
5. The sticky notes are read: cd to `/var/www/html`, run `init.sh` as PID 1

**The rule that falls out: anything *used* at runtime must be *installed* at build time.** `init.sh` calls `mysqladmin ping` at runtime — so `mariadb-client` must be installed by the Dockerfile, even though no database exists or is reachable at build time. The build stocks the toolbox; runtime uses the tools. Installing at runtime instead would fail or hurt three ways: it needs the network and the apt index we deleted, anything installed would vanish with the container's writable layer, and startup would become slow and unreproducible.
