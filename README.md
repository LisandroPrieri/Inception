_This project has been created as part of the 42 curriculum by lprieri._

## Description

Inception is a system administration project focused on containerization with Docker.

The goal is to build and orchestrate a small web infrastructure from scratch, inside a virtual machine, without relying on any ready-made images.

The stack is composed of three services, each running in its own dedicated container built from a custom Dockerfile based on Debian Bookworm:

- **NGINX:** the single entry point of the infrastructure, exposed on port 443 only, serving traffic over TLSv1.2/TLSv1.3.
- **WordPress + PHP-FPM:** the application layer, listening on port 9000 and reached by NGINX over the internal Docker network.
- **MariaDB:** the database backing the WordPress installation.

The containers communicate through a Docker network, and persistent data (the WordPress database and the website files) is stored in two named volumes bound to `/home/lprieri/data` on the host.

Credentials are kept out of the repository via a `.env` file and Docker secrets, and every service restarts automatically on failure.

The whole stack is built and launched with a single `make` at the root of the project.

The site is reachable at `https://lprieri.42.fr`, a domain resolved locally to the
VM's own IP address.

### Project structure

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

### Core concepts

**Image**: a read-only template, built from a Dockerfile. Like a class: passive, instantiable many times.

**Container**: a running instance of an image. It's analogous to an object of the image's class. Behind the scenes it's an ordinary Linux process, isolated so it sees only the image's files, its own network, and its own process list. Nothing is emulated (unlike a VM), only isolated, which is why containers start in milliseconds.

**Layer**: an image is a stack of filesystem diffs, one per instruction that touches the filesystem (`RUN`, `COPY`, `ADD`). Metadata instructions (`ENV`, `WORKDIR`, `EXPOSE`, `CMD`, `ENTRYPOINT`) only update the image config and create no layer. Layers are:

- **immutable:** a later layer can hide a file from an earlier one, but never reclaims its space;
- **shared:** all three images reuse the same Debian base layers on disk;
- **cached:** unchanged instructions aren't re-run on rebuild, but one cache miss invalidates every instruction after it.

**Volume**: storage created and managed by Docker, mounted into a container at a chosen path.
A container's own writable layer dies with the container, so anything a service *accumulates* — database rows, uploads — goes in a volume instead.
This project uses **named volumes**: Docker owns them as objects (`docker volume ls`) and decides where their bytes live.
Here the `local` driver is pointed at `/home/lprieri/data/...`, as the subject requires.
A named volume that is empty on first mount is pre-populated with whatever the image has at that path.

**Bind mount**: the other way to expose host storage — a host path mounted straight into a container, with no Docker-managed object in between and no pre-population; it simply shadows whatever the image had there. 
The subject forbids bind mounts for the two persistent stores, so no service declares one.
The bind *mechanism* appears only in the volumes' driver options, telling the `local` driver where to put their storage.

**Division of labor**: what *defines* a service (software, configuration) lives in the image and is rebuilt at will; what a service *accumulates* lives in a volume and outlives every rebuild; the container itself owns nothing and is disposable by design.

### Client and daemon

The `docker` command you type is just a client. It sends requests to `dockerd`, a background service running as root on the machine. The two talk over a Unix socket, a special file at `/var/run/docker.sock` that programs use to communicate locally.

A practical consequence:

- That socket file is owned by `root:docker` (owner:group). So running `docker` without `sudo` means being in the `docker` group.

Since the daemon is root, **being in the `docker` group is effectively being root:** you can start a container that mounts the whole host filesystem.

### Networking

The three containers are connected to a **user-defined bridge network**: a private virtual switch that Docker creates for the project.

Each container gets its own IP on it and can reach the others **by service name** — WordPress connects to the database at the hostname `mariadb`, NGINX to php-fpm at `wordpress:9000`. Docker runs a small internal DNS server that resolves those names, so no IP addresses are ever hardcoded.

Nothing on this network is reachable from outside unless a port is deliberately published. Only NGINX publishes one: 443.

## Project description

### Virtual Machines vs Docker

A **virtual machine** simulates a whole computer. It boots a complete guest operating system, with **its own kernel**, on virtualized hardware. That costs gigabytes of disk and minutes of boot time, and buys strong isolation: the guest kernel is separate from the host's.

A **container** is not a machine at all. It's an ordinary Linux process that the host kernel isolates, using two kernel features:

- **namespaces:** control what the process can *see* (its own filesystem, network interfaces, process list);
- **cgroups:** control how much it can *use* (CPU, memory).

Nothing is emulated. The container **shares the host kernel**, weighs megabytes, and starts in milliseconds. The tradeoff is weaker isolation: a shared kernel is a shared attack surface.

*In this project:* the whole stack runs inside one VM, with the three services as containers **inside** it.

A container has no init system, it *is* a single process, and lives exactly as long as that process (its **PID 1**), which is why each service's real daemon must run in the foreground as PID 1.

### Secrets vs Environment Variables

**Environment variables** (here through `.env` and Compose's `env_file`) are convenient but leaky.
They show up in `docker inspect`, they're readable in `/proc/<pid>/environ`, every child process inherits them, and they frequently end up in logs and crash dumps.

A **Docker secret** is a file instead: mounted read-only inside the container at `/run/secrets/<name>`. It isn't in the environment, so no child process inherits it and it can't leak into a stack trace; code has to open the file deliberately to read it.
(The file still exists on the host, so this is about limiting exposure, not making the value unreadable.)

*In this project:* `.env` holds only **non-secret** configuration: the domain, database name, usernames, emails.

The three passwords (`db_password`, `db_root_password`, `credentials`) live in git-ignored files under `secrets/`, are mounted as Docker secrets, and are read from `/run/secrets/` by the init scripts.

Secrets are also **scoped per service**: MariaDB never receives the WordPress credentials, and NGINX receives no secret at all.
`env_file` can't do that; it hands every variable to every container that loads it.

The subject makes `.env` mandatory and secrets strongly recommended.
Any credential committed to the repository is an automatic fail.

### Docker Network vs Host Network

With **host networking** (`network: host`) a container skips network isolation entirely and uses the host's network stack. Every port it opens is immediately open on the host, there's no per-container DNS, and containers can't be addressed by name.

With a **user-defined bridge**, each container gets its own IP on a private network, containers resolve each other by service name, and only the ports you explicitly publish are reachable from outside.

*In this project:* all three services join one bridge network: `inception`. Only NGINX publishes a port (443). `wordpress:9000` and `mariadb:3306` are reachable **only** from inside the network. With host networking, php-fpm and MariaDB would be exposed on the host too.

This is why `network: host` and `links` (the deprecated mechanism that predates Docker networks) are both forbidden.

### Docker Volumes vs Bind Mounts

A container's own filesystem is disposable, it's destroyed with the container. Anything that must survive a rebuild has to live outside it.

A **bind mount** attaches an exact host path into a container. It's simple, but Docker doesn't manage it: there's no object to list or inspect, and the compose file becomes tied to one machine's directory layout.

A **named volume** is a storage object that Docker creates, names, and tracks. It appears in `docker volume ls`, can be inspected and removed by name, and the compose file refers to it by name rather than by path.

*In this project:* the two persistent stores are named volumes — `db_data` (`/var/lib/mysql`) and `wp_data` (`/var/www/html`, shared by WordPress and NGINX) — since the subject states that bind mounts are not allowed for these.

The subject *also* requires the data to end up under `/home/lprieri/data`.
Both rules are satisfied at once: the services mount **named volumes**, and the fixed host path appears
only inside each volume's `driver_opts` (`type: none, o: bind, device: ...`), where it tells Docker's local driver where to place that volume's storage. The services never see a host path.

## Instructions

```
make            # create data dirs, build images, start everything detached
make logs       # follow container logs
make down       # stop and remove containers (data survives)
make fclean     # remove everything including data
make re         # full rebuild from scratch
```

## Environment

The stack runs in an Ubuntu VM (VirtualBox).

Secrets live in `srcs/.env`, injected into containers at runtime via `env_file`, never baked into images, never committed to git.

## Resources

Documentation actually used to build this project:

- [Dockerfile reference](https://docs.docker.com/reference/dockerfile/): the canonical list of Dockerfile instructions (`FROM`, `RUN`, `COPY`, `ENTRYPOINT`, …)
- [Compose file reference](https://docs.docker.com/reference/compose-file/): everything available in `docker-compose.yml`
- [wp-cli handbook](https://make.wordpress.org/cli/handbook/): the WordPress command-line tool driven by the wordpress container's init script
- [MariaDB Knowledge Base](https://mariadb.com/kb/en/): server configuration and SQL reference
- [PHP-FPM configuration reference](https://www.php.net/manual/en/install.fpm.configuration.php): pool directives (`listen`, `pm`, …)

### How AI was used

AI (Claude) was used as an interactive tutor and pair-programmer, not as a code generator to copy from. Concretely: explaining Docker and service concepts before each component was written (images vs containers, layers, PID 1 and signal handling, FastCGI); drafting configuration files and scripts one piece at a time, which were then discussed line by line, questioned, and typed in manually; and co-writing the documentation in this repository.
