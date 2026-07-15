*This project has been created as part of the 42 curriculum by lprieri.*

# Inception

A small web infrastructure built entirely with Docker, running inside a virtual machine. Three services, each in its own container built from a custom Dockerfile, orchestrated with Docker Compose.

## The stack

- **NGINX** — the single entry point. TLS only, port 443. Nothing else is reachable from outside.
- **WordPress + php-fpm** — the website itself. No web server inside this container.
- **MariaDB** — the database. Nothing else inside this container.

The three containers communicate over a private Docker bridge network. Two volumes persist the data that must survive container destruction: the database files and the WordPress site files. Both live on the host at `/home/lprieri/data/`.

## Project structure

```
inception/
├── Makefile                      # builds and runs everything
├── docs/                         # per-container documentation
└── srcs/
    ├── docker-compose.yml        # orchestration: services, network, volumes
    ├── .env                      # credentials and config values (never committed)
    └── requirements/
        ├── mariadb/
        │   ├── Dockerfile        # recipe to build the image
        │   ├── conf/             # configuration files copied into the image
        │   └── tools/            # startup scripts
        ├── nginx/
        └── wordpress/
```

Each service follows the same shape: the Dockerfile defines what goes in the image, `conf/` holds configuration, `tools/` holds the startup script that runs when the container starts.

## Core concepts

**Image** — a frozen, read-only filesystem plus a note about what to run. Built from a Dockerfile. Like a class: passive, instantiable many times.

**Container** — a running instance of an image. Like an object. Under the hood it is an ordinary Linux process, isolated so it only sees the image's files, its own network, and its own process list. Nothing is emulated (unlike a VM) — only isolated, which is why containers start in milliseconds.

**Layer** — images are stored as stacks of filesystem diffs, one per Dockerfile instruction. Layers are immutable (a later layer can only shadow files in an earlier one, never reclaim their space), shared between images (all three images reuse the same Debian base layers on disk), and cached (unchanged instructions are not re-executed on rebuild).

**Volume** — a real folder on the host, plugged into the container at a chosen path. Containers get a disposable writable layer that is destroyed with them; anything that must survive (database rows, uploads) goes in a volume instead. This project uses named volumes backed by bind mounts, so the data lives at a fixed host path as the subject requires.

**Bind mount** — the mechanism behind the volumes here: one folder, two doorways. The host folder `/home/lprieri/data/mariadb` and the container path `/var/lib/mysql` are the same directory viewed from two worlds. No copying, no syncing.

**The container/image/volume division of labor:** everything that *defines* a service (software, config) lives in the image and is rebuilt at will; everything a service *accumulates* (data) lives in a volume and survives everything; the container itself owns nothing and is disposable by design ("cattle, not pets").

## Client and daemon

The `docker` command is a thin client. The actual engine is `dockerd`, a root daemon running as a systemd service. Every docker command is an HTTP API request from client to daemon, delivered over a Unix domain socket at `/var/run/docker.sock`. The socket is a file owned by `root:docker`, which is why using Docker without sudo requires membership in the `docker` group — and why that membership is effectively root on the machine. Group membership is read at login, so adding yourself to the group requires a fresh login to take effect.

## Networking

All three services join a user-defined bridge network — a private virtual switch. Containers on it resolve each other by service name via Docker's internal DNS (WordPress reaches the database at hostname `mariadb`). Nothing on the bridge is reachable from outside except the single port deliberately published: NGINX's 443. `network: host` (which removes isolation entirely) and `links` (the deprecated pre-network mechanism) are forbidden by the subject and unnecessary.

## Usage

```
make            # create data dirs, build images, start everything detached
make logs       # follow container logs
make down       # stop and remove containers (data survives)
make fclean     # remove everything including data
make re         # full rebuild from scratch
```

## Environment

The stack runs in an Ubuntu VM (VirtualBox). Secrets live in `srcs/.env`, injected into containers at runtime via `env_file` — never baked into images, never committed to git.