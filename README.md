*This project has been created as part of the 42 curriculum by lprieri.*

# Inception

## Description

A small web infrastructure built entirely with Docker, running inside a virtual machine. Three services, each in its own container built from a custom Dockerfile, orchestrated with Docker Compose.

## The stack

- **NGINX**: the single entry point. TLS only, port 443. Nothing else is reachable from outside.
- **WordPress + php-fpm**: the website itself. No web server inside this container.
- **MariaDB**: the database. Nothing else inside this container.

The three containers communicate over a private Docker bridge network. Two volumes persist the data that must survive container destruction: the database files and the WordPress site files. Both live on the host at `/home/lprieri/data/`.

## Project structure

```
inception/
├── Makefile                      # builds and runs everything
├── USER_DOC.md                   # how to use and administer the stack
├── DEV_DOC.md                    # how to set up, build, and operate it
├── secrets/                      # passwords: git-ignored, mounted as Docker secrets
└── srcs/
    ├── docker-compose.yml        # orchestration: services, network, volumes
    ├── .env                      # non-secret config (never committed)
    └── requirements/
        ├── mariadb/
        │   ├── Dockerfile        # recipe to build the image
        │   ├── README.md         # deep-dive documentation of the service
        │   ├── conf/             # configuration files copied into the image
        │   └── tools/            # startup scripts
        ├── nginx/
        └── wordpress/
```

Each service follows the same shape: the Dockerfile defines what goes in the image, `conf/` holds configuration, `tools/` holds the startup script that runs when the container starts.

## Core concepts

**Image**: a frozen, read-only filesystem plus a note about what to run. Built from a Dockerfile. Like a class: passive, instantiable many times.

**Container**: a running instance of an image. Like an object. Under the hood it is an ordinary Linux process, isolated so it only sees the image's files, its own network, and its own process list. Nothing is emulated (unlike a VM), only isolated, which is why containers start in milliseconds.

**Layer**: images are stored as stacks of filesystem diffs, one per Dockerfile instruction. Layers are immutable (a later layer can only shadow files in an earlier one, never reclaim their space), shared between images (all three images reuse the same Debian base layers on disk), and cached (unchanged instructions are not re-executed on rebuild).

**Volume**: a real folder on the host, plugged into the container at a chosen path. Containers get a disposable writable layer that is destroyed with them; anything that must survive (database rows, uploads) goes in a volume instead. This project uses Docker **named volumes**: volume objects Docker itself creates and manages (`docker volume ls` shows them), whose `local` driver is pointed at a fixed host path, so the data lands under `/home/lprieri/data/` as the subject requires.

**Bind mount**: the *other* way to get host storage into a container, mounting an exact host path directly into a service, bypassing Docker's volume management. The subject forbids bind mounts for the two persistent stores; the services here mount named volumes only. The bind *mechanism* appears solely inside the volumes' driver options, where it tells the `local` driver where to place their storage. One folder, two doorways: `/home/lprieri/data/mariadb` and `/var/lib/mysql` are the same directory viewed from two worlds.

**The container/image/volume division of labor:** everything that *defines* a service (software, config) lives in the image and is rebuilt at will; everything a service *accumulates* (data) lives in a volume and survives everything; the container itself owns nothing and is disposable by design ("cattle, not pets").

## Client and daemon

The `docker` command is a thin client. The actual engine is `dockerd`, a root daemon running as a systemd service. Every docker command is an HTTP API request from client to daemon, delivered over a Unix domain socket at `/var/run/docker.sock`. The socket is a file owned by `root:docker`, which is why using Docker without sudo requires membership in the `docker` group, and why that membership is effectively root on the machine. Group membership is read at login, so adding yourself to the group requires a fresh login to take effect.

## Networking

All three services join a user-defined bridge network: a private virtual switch. Containers on it resolve each other by service name via Docker's internal DNS (WordPress reaches the database at hostname `mariadb`). Nothing on the bridge is reachable from outside except the single port deliberately published: NGINX's 443. `network: host` (which removes isolation entirely) and `links` (the deprecated pre-network mechanism) are forbidden by the subject and unnecessary.

## Project description: Docker and design choices

This project runs a three-service WordPress infrastructure (NGINX, WordPress/php-fpm, MariaDB) as Docker containers orchestrated by Docker Compose, each built from its own Dockerfile. The sources under `srcs/` hold one directory per service (`Dockerfile`, `conf/`, `tools/`), the `docker-compose.yml` that wires them together, and a `.env` of non-secret configuration; passwords live in git-ignored `secrets/`. The key design choices are captured in the four comparisons below.

### Virtual Machines vs Docker

A virtual machine emulates a whole computer: it boots a full guest OS with **its own kernel** on virtualized hardware, using gigabytes of disk and minutes to boot, but giving strong isolation. A Docker container is not a machine at all; it is an ordinary Linux **process** that the host kernel isolates (via namespaces and cgroups) so it sees only its own filesystem, network, and process list. It **shares the host kernel**, weighs megabytes, and starts in milliseconds.

*In this project:* the whole stack runs inside one VM (a 42 requirement), and the three services run as containers **inside** that VM. Three VMs would be wasteful in disk and boot time; three bare processes would lack isolation and reproducibility. Containers hit the middle. This is also why the subject bans `tail -f` keep-alive hacks: a container is not a box to keep powered on, it lives exactly as long as its PID 1 process, so each service's real daemon must *be* PID 1.

### Secrets vs Environment Variables

Environment variables (here via `.env` and Compose `env_file`) are convenient but leaky: they appear in `docker inspect`, in `/proc/<pid>/environ`, are inherited by every child process, and often end up in logs or crash dumps. A Docker **secret** is instead a file mounted read-only at `/run/secrets/<name>`: nothing outside the container can read it, no child process inherits it, and code reads it only deliberately.

*In this project:* `.env` holds only **non-secret** config, namely the domain, database name, usernames, and emails. The three passwords (`db_password`, `db_root_password`, `credentials`) live in git-ignored files under `secrets/`, mounted as Docker secrets and read by the init scripts from `/run/secrets/`. Access is **scoped per service**: MariaDB never receives the WordPress credentials, and NGINX receives no secret at all, something `env_file` cannot do since it hands every variable to every container. The subject makes `.env` mandatory and secrets strongly recommended; any credential committed to the repo is an automatic fail.

### Docker Network vs Host Network

With **host networking** (`network: host`) a container shares the host's network stack directly: every port it opens is open on the host, there is no per-container DNS, and network isolation is gone. A **user-defined bridge** is a private virtual switch: each container gets its own IP, containers resolve each other by **service name** through Docker's internal DNS, and only ports you explicitly publish are reachable from the host.

*In this project:* all three services join one bridge network, `inception`. Only NGINX publishes a port (`443`); `wordpress:9000` and `mariadb:3306` are reachable **only** from inside the network. WordPress reaches the database at hostname `mariadb`, and NGINX reaches php-fpm at `wordpress:9000`, by name, with no hardcoded IPs. The subject's single entrypoint on 443 is only possible *because* of this isolation, which is exactly why `network: host` and `links` are forbidden.

### Docker Volumes vs Bind Mounts

A **bind mount** injects an exact host path into a container: simple, but Docker does not manage it and the compose file becomes tied to that host's layout. A **named volume** is a Docker-managed object with its own name and lifecycle, visible to `docker volume ls` and `docker volume inspect` and decoupled from any particular path.

*In this project:* the two persistent stores are **named volumes**, `db_data` (`/var/lib/mysql`) and `wp_data` (`/var/www/html`, shared by WordPress and NGINX), as the subject requires ("bind mounts are not allowed for these volumes"). The requirement to keep the data under `/home/lprieri/data` is met without a service-level bind mount: the services mount the *named volumes*, and the fixed host path appears only inside each volume's `driver_opts` (`type: none, o: bind, device: ...`), where it tells the local driver where to place the volume's storage. So it satisfies both rules at once: named volumes to the services, data pinned to the required host directory.

## Instructions

```
make            # create data dirs, build images, start everything detached
make logs       # follow container logs
make down       # stop and remove containers (data survives)
make fclean     # remove everything including data
make re         # full rebuild from scratch
```

## Environment

The stack runs in an Ubuntu VM (VirtualBox). Secrets live in `srcs/.env`, injected into containers at runtime via `env_file`, never baked into images, never committed to git.

## Resources

Documentation actually used to build this project:

- [Dockerfile reference](https://docs.docker.com/reference/dockerfile/): the canonical list of Dockerfile instructions (`FROM`, `RUN`, `COPY`, `ENTRYPOINT`, …)
- [Compose file reference](https://docs.docker.com/reference/compose-file/): everything available in `docker-compose.yml`
- [Official images' Dockerfiles](https://github.com/docker-library): forbidden to *use* in this project, instructive to *read*. The entrypoint patterns here (first-boot guard, `exec` as PID 1) are the same idioms the official `mariadb` and `wordpress` images use
- [wp-cli handbook](https://make.wordpress.org/cli/handbook/): the WordPress command-line tool driven by the wordpress container's init script
- [MariaDB Knowledge Base](https://mariadb.com/kb/en/): server configuration and SQL reference
- [PHP-FPM configuration reference](https://www.php.net/manual/en/install.fpm.configuration.php): pool directives (`listen`, `pm`, …)

Per-service deep dives live next to each service: [srcs/requirements/mariadb/README.md](srcs/requirements/mariadb/README.md), [srcs/requirements/wordpress/README.md](srcs/requirements/wordpress/README.md), and [srcs/requirements/nginx/README.md](srcs/requirements/nginx/README.md).

### How AI was used

AI (Claude) was used as an interactive tutor and pair-programmer, not as a code generator to copy from. Concretely: explaining Docker and service concepts before each component was written (images vs containers, layers, PID 1 and signal handling, FastCGI); drafting configuration files and scripts one piece at a time, which were then discussed line by line, questioned, and typed in manually; verifying package versions and file paths in throwaway containers instead of trusting memory; and co-writing the documentation in this repository. All design decisions (runtime setup vs build-time, named volumes pinned to a host path, TCP socket between containers) were understood before being adopted and are documented with their reasoning in the per-service docs.
