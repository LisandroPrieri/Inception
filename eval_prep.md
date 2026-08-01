# Activity overview

- [How Docker and docker compose work](#1-how-docker-and-docker-compose-work)
- [Image with compose vs. without compose](#2-image-with-compose-vs-without-compose)
- [Benefit of Docker compared to VMs](#3-benefit-of-docker-compared-to-vms)
- [Why this directory structure](#4-why-this-directory-structure)
- [Likely follow-ups](#likely-follow-ups)
- [README check](#readme-check) (separate rubric item)

Here's each of the four, in the words you can actually say out loud during the defense.

---

## 1. How Docker and docker compose work

**Docker** runs a program together with everything that program needs (its libraries, its config, its files) in an isolated **container**, using the host machine's kernel.

The three words to keep straight:

- **Dockerfile:** a recipe. A text file of instructions: start from Debian, install nginx, copy this config, run this script.
- **Image:** the result of that recipe. A read-only, frozen filesystem snapshot. Built once with `docker build`.
- **Container:** a running instance of an image. Same image can produce many containers. When it stops, anything written inside it that isn't on a volume is gone.

The key mechanism: a container is **just a process on the host**, isolated by Linux kernel features:
- **namespaces** → the process gets its own view of the world (its own PIDs, its own network stack, its own mount tree). It thinks it's alone on a machine.
- **cgroups** → limits how much CPU/RAM it can use.

That's why `ps aux` on the host shows your container's processes — there's no second kernel involved.

**docker compose** is the orchestrator on top. Instead of typing three long `docker run` commands with the right flags, network, volumes and order, you describe the whole stack **declaratively** in one YAML file, and run `docker compose up`. It creates the network, creates the volumes, builds the images, and starts the containers.

Point at [srcs/docker-compose.yml](srcs/docker-compose.yml): "three services — mariadb, wordpress, nginx — one bridge network, two volumes, secrets, and `depends_on` for the start order."

---

## 2. Image with compose vs. without compose

Trick question, and the honest answer is: **the image is exactly the same thing**. Same format, same build, same layers. `docker compose build` calls the same builder as `docker build`. Compose changes *how you drive it*, not *what it is*.

What actually differs is everything **around** the image:

| | Without compose | With compose |
|---|---|---|
| Build | `docker build -t nginx:inception ./requirements/nginx` | `build: ./requirements/nginx` in the YAML |
| Run | `docker run` + a pile of flags every time | `docker compose up` |
| Network | you create it by hand (`docker network create`) and attach each container | created automatically, all services joined |
| Name resolution | you wire it yourself | service name **is** the hostname — WordPress connects to `mariadb` because that's the service name |
| Volumes/secrets/env | flags on every command, retyped by hand | declared once in the file |
| Lifecycle | container by container | whole stack up/down together, in dependency order |

The one-liner to say: **"Without compose, the run configuration lives in my shell history. With compose, it lives in a versioned file."** Imperative vs. declarative.

Concrete example from your project: WordPress reaches the database at host `mariadb` — that only works because Docker's embedded DNS on the `inception` network resolves service names. Without compose you'd have to create that network and attach both containers yourself.

---

## 3. Benefit of Docker compared to VMs

The core difference: **a VM virtualizes hardware, a container virtualizes the OS.**

- **VM** = hypervisor + full guest OS + its own kernel + virtual disk + virtual devices. You boot a whole machine.
- **Container** = an isolated process sharing the **host's** kernel. Nothing to boot.

What follows from that:

| | VM | Container |
|---|---|---|
| Size | GBs (whole OS) | MBs (just your app + its deps) |
| Startup | tens of seconds — a real boot | ~instant, it's just a process |
| Overhead | RAM/CPU reserved for each guest kernel | nearly none |
| Density | a handful per host | dozens or hundreds |
| Reproducibility | snapshots, heavy to share | a Dockerfile: a few KB of text, rebuilds identically |

And the honest trade-off — **say this, it shows you actually understand it**: containers isolate *less*. They share the kernel, so isolation is weaker than a VM's, and you can't run a different kernel — no Windows container on a Linux host. A VM is a security/compatibility boundary; a container is mainly a packaging and isolation-of-concerns boundary.

If asked "then why are we in a VM for this project?" → because containers share the host kernel, so you need a Linux machine, and 42's iMacs run macOS. The VM provides the kernel; Docker provides the packaging.

---

## 4. Why this directory structure

The subject imposes it, but there's real logic in it. Walk it top-down:

```
Makefile               ← the entry point: make up / make down
secrets/               ← passwords, outside srcs/, gitignored
srcs/
├── .env               ← configuration (domain, db name, user)
├── docker-compose.yml ← how the services fit together
└── requirements/
    ├── mariadb/
    │   ├── Dockerfile ← how to build THIS image
    │   ├── conf/      ← config files copied in
    │   └── tools/     ← the init script that runs at startup
    ├── wordpress/     ← same shape
    └── nginx/         ← same shape
```

Four points to make:

1. **Separation of orchestration and construction.** `docker-compose.yml` says *how the pieces connect*. Each `Dockerfile` says *how one piece is built*. Two different questions, two different places.

2. **One folder per service, all the same shape.** Every service is self-contained — Dockerfile, conf, tools. To understand nginx you read one directory. To add a service you copy the pattern. That's the "one container, one job" rule made visible in the filesystem: a folder for the web server, a folder for PHP, a folder for the database — nobody's config leaks into anyone else's.

3. **Build context is scoped.** `build: ./requirements/nginx` means the build only sees that folder. nginx cannot accidentally copy MariaDB's files, and the build stays small and fast. (Your [.dockerignore](srcs/requirements/nginx/.dockerignore) files tighten this further.)

4. **Secrets live outside `srcs/`, config lives inside.** `secrets/` is a sibling of `srcs/`, gitignored — passwords never enter an image or the repo. `.env` holds the non-sensitive config. Two kinds of variable data, deliberately kept apart, and both kept out of the images so the same image works in any environment.

The summary line: **"The structure makes the project readable and modular — you can tell what each container does from the filesystem alone, without opening a single file."**

---

## Likely follow-ups

Be ready for these — they're the standard traps:

- **"Why is `network: host` / `links:` forbidden?"** → because compose's own bridge network already gives you isolation *and* DNS between services. `host` removes isolation; `links` is legacy, superseded by networks.
- **"Why no infinite loop / `tail -f` / `sleep infinity`?"** → a container lives as long as PID 1. The right way is to run the actual daemon in the foreground (`nginx -g "daemon off;"`, `php-fpm7.4 -F`, `mysqld`). A hack loop keeps the container "up" while the service may be dead, so Docker can't detect failure or restart it.
- **"What happens to your data if you `docker compose down`?"** → containers are destroyed, but the named volumes survive on the host. That's the point of volumes.
- **"Why `depends_on` isn't enough?"** → it only waits for the container to *start*, not for MariaDB to be *ready to accept connections*. That's why your WordPress init script waits for the DB itself.

---

# README check

The rubric: a `README.md` at the root, the exact italicized first line, and at least the sections Description, Instructions, and Resources (with an explanation of how AI was used). Anything missing ends the evaluation on the spot.

**Status: passes.** All four elements are present.

| Requirement | Status |
|---|---|
| `README.md` at repo root | ✅ [README.md](README.md) |
| First line, italicized, exact format | ✅ line 1: `*This project has been created as part of the 42 curriculum by lprieri.*` |
| `## Description` | ✅ [README.md:5](README.md#L5) |
| `## Instructions` | ✅ [README.md:90](README.md#L90) — the `make` targets |
| `## Resources` | ✅ [README.md:104](README.md#L104) — six links, all real docs |
| Explanation of how AI was used | ✅ [README.md:117](README.md#L117), `### How AI was used` under Resources |

Secrets hygiene also checks out: `git ls-files` shows only `srcs/.env.example` tracked — the real `.env` and `secrets/` are both git-ignored, so no credential is in the repo.

## One thing to fix before the defense

The `## Environment` section contradicts the rest of the README:

> [README.md:102](README.md#L102) — *"Secrets live in `srcs/.env`, injected into containers at runtime via `env_file`, never baked into images"*

But [README.md:76](README.md#L76) correctly says `.env` holds **only non-secret** config and the three passwords are Docker secrets under `secrets/`. Line 102 is leftover from an earlier version. An evaluator reading top-to-bottom hits your strongest section (Secrets vs Environment Variables), then hits a line saying your secrets are in `.env` — which is exactly the thing the subject warns about. It undercuts the part you got right.

Draft replacement for lines 100–102:

```markdown
## Environment

The stack runs in an Ubuntu VM (VirtualBox). Non-secret configuration lives in
`srcs/.env` (domain, database name, usernames, emails), injected via `env_file`.
The three passwords live in git-ignored files under `secrets/`, mounted as Docker
secrets at `/run/secrets/`. Neither is ever baked into an image or committed to git.
```

---

# Documentation check

The rubric: `USER_DOC.md` and `DEV_DOC.md` both at the root and non-empty. USER_DOC covers start/stop, accessing the site and admin panel, managing credentials, and basic checks. DEV_DOC covers prerequisites, setup, Makefile usage, docker compose commands, and data persistence.

**Status: passes.** Both files present and non-empty.

| Requirement | Status |
|---|---|
| `USER_DOC.md` at root, non-empty | ✅ [USER_DOC.md](USER_DOC.md), 67 lines |
| — start/stop the stack | ✅ [USER_DOC.md:17](USER_DOC.md#L17) — table of `make` targets |
| — access website + admin panel | ✅ [USER_DOC.md:29](USER_DOC.md#L29) — `/etc/hosts` line, both URLs, the self-signed cert warning explained |
| — manage credentials | ✅ [USER_DOC.md:48](USER_DOC.md#L48) — what lives in `.env` vs `secrets/`, and how to change each after first boot |
| — basic checks | ✅ [USER_DOC.md:61](USER_DOC.md#L61) — `docker ps`, `curl -k`, `mysqladmin ping`, `make logs` |
| `DEV_DOC.md` at root, non-empty | ✅ [DEV_DOC.md](DEV_DOC.md), 92 lines |
| — prerequisites | ✅ [DEV_DOC.md:5](DEV_DOC.md#L5) — VM, Docker + Compose plugin, `docker` group, make/git |
| — setup | ✅ [DEV_DOC.md:12](DEV_DOC.md#L12) — clone, `.env` from template, the three secret files, launch, hosts |
| — Makefile usage | ✅ [DEV_DOC.md:48](DEV_DOC.md#L48) — every target with what it actually runs |
| — docker compose commands | ✅ [DEV_DOC.md:60](DEV_DOC.md#L60) — `ps`, `logs`, `exec`, per-service rebuild, volume/network inspection |
| — data persistence | ✅ [DEV_DOC.md:78](DEV_DOC.md#L78) — volume→path→contents table, plus what survives `down` vs `fclean` |

The documented targets were cross-checked against the real [Makefile](Makefile): `up`, `down`, `logs`, `fclean`, `re` all behave as described, including `fclean` doing `sudo rm -rf $(DATA_DIR)` and `re` being a true from-scratch boot.

## Gap worth closing: two Makefile targets are undocumented

The Makefile has [`hosts`](Makefile#L19) and [`unhosts`](Makefile#L23), but neither doc mentions them. Both docs instead walk the reader through editing `/etc/hosts` by hand ([DEV_DOC.md:40-46](DEV_DOC.md#L40-L46), [USER_DOC.md:31-35](USER_DOC.md#L31-L35)) — the exact thing `make hosts` automates, and does better: it greps first, so it won't duplicate the line on repeat runs.

That's a bad look in a defense — the evaluator may run `make hosts`, or notice the target and ask why the docs ignore it. Drafts:

**DEV_DOC.md**, replacing step 5's command block:

````markdown
   ```
   make hosts     # appends the line only if it isn't already there
   ```

   Or by hand: `echo "127.0.0.1 lprieri.42.fr" | sudo tee -a /etc/hosts`. `tee` (rather
   than `echo ... >> /etc/hosts`) is needed because the redirection in `sudo echo ... >>`
   runs as your unprivileged shell and is denied; `sudo tee` does the privileged write.
   `make unhosts` removes the line again.
````

**USER_DOC.md**, replacing the manual `/etc/hosts` block at line 31-37:

````markdown
The site answers only to the name `lprieri.42.fr`. Inside the VM, map that name once:

```
make hosts
```

If your browser runs outside the VM, add the line there by hand instead, using the VM's
IP address in place of `127.0.0.1`:

```
127.0.0.1    lprieri.42.fr
```
````

(`make clean` is also undocumented, but it's just an alias for `down` — not worth a line.)

---

# Simple setup

The rubric: NGINX reachable on **443 only**, a TLS certificate in use, and WordPress already installed (no Installation page) at `https://lprieri.42.fr` — with `http://lprieri.42.fr` **not** working. Anything broken ends the evaluation.

**Status: passes**, but only after fixing a blocker — see the section below first.

| Check | Result |
|---|---|
| Only 443 published | ✅ `nginx: 0.0.0.0:443->443/tcp`; `wordpress: 9000/tcp` and `mariadb: 3306/tcp` are container-internal, not host-published |
| Nothing on port 80 | ✅ `ss -tlnp` shows no listener |
| `http://lprieri.42.fr` refused | ✅ `curl: (7) Failed to connect ... port 80` |
| `https://lprieri.42.fr` serves | ✅ HTTP 200 |
| TLS certificate present | ✅ self-signed, `CN=lprieri.42.fr`, valid Jul 29 2026 → Jul 29 2027 |
| TLS version | ✅ negotiates **TLSv1.3** (`TLS_AES_256_GCM_SHA384`); TLSv1.2 also accepted; **TLSv1.0 and TLSv1.1 refused**, as the subject requires |
| Not the Installation page | ✅ homepage `<title>Inception</title>`; `/wp-admin/` gives `Log In ‹ Inception — WordPress`; `install.php` answers **"Already Installed"** |
| PHP actually executing | ✅ `Content-Type: text/html; charset=UTF-8` from `Server: nginx/1.22.1` — php-fpm is being reached, not serving raw source |
| Database live and populated | ✅ `mysqladmin ping` → alive; `wp_posts` has 4 rows; `wp_users` has `lprieri_boss` and `wpguest` |
| Data at the required host path | ✅ real files under `/home/lprieri/data/mariadb` and `/home/lprieri/data/wordpress` |
| Named volumes, not bind mounts | ✅ `docker inspect` shows `volume inception_wp_data` and `volume inception_db_data` (the only `bind` entries are Docker's own `/run/secrets/` mounts) |

## The blocker that was found and fixed

`srcs/.env` was **missing `DATA_DIR`**. Because `docker-compose.yml` interpolates `${DATA_DIR}` into both volume `device:` paths, compose resolved them to `/mariadb` and `/wordpress` — the filesystem root — instead of `/home/lprieri/data/...`:

```
$ docker compose config
volumes:
  db_data:
    driver_opts:
      device: /mariadb        # ← should be /home/lprieri/data/mariadb
```

This would have failed the defense on two counts at once: the containers can't mount paths that don't exist, and the subject requires the data to live in `/home/<login>/data`. The Makefile hid it, because it has its own `DATA_DIR ?= /home/lprieri/data` fallback on line 5 — so `make` created the right directories while compose pointed somewhere else entirely.

The fix, added to the top of `srcs/.env`:

```
# Host directory holding the persistent data
DATA_DIR=/home/lprieri/data
```

**Why it happened, and the lesson:** `srcs/.env` is git-ignored, so it drifted out of sync with `srcs/.env.example` (which *does* have `DATA_DIR`). A fresh clone following DEV_DOC would have been fine; only this working copy was broken. Before the defense, verify with:

```
docker compose -f srcs/docker-compose.yml -p inception config | grep device
```

That prints the resolved paths and catches this class of bug instantly. Worth running any time `.env` changes.

## Cosmetic note

`/home/lprieri/data/wordpress/` contains `index.nginx-debian.html` — nginx's Debian default page, written into the shared `wp_data` volume when the nginx image installed the package. Harmless (the nginx config lists `index.php` first, which is why the real site loads), but it's a stray file an evaluator might spot in the shared volume.

---

# Docker Basics

The rubric: one non-empty Dockerfile per service, all written by hand (no ready-made images, no DockerHub service images), each starting from the **penultimate** stable Alpine/Debian, images named after their service, and everything brought up by the Makefile through docker compose without a crash.

**Status: passes on all five points.**

| Check | Result |
|---|---|
| One Dockerfile per service, non-empty | ✅ [mariadb](srcs/requirements/mariadb/Dockerfile) (12 lines), [wordpress](srcs/requirements/wordpress/Dockerfile) (29 lines), [nginx](srcs/requirements/nginx/Dockerfile) (11 lines) |
| Hand-written, no ready-made images | ✅ all three are `FROM debian:bookworm` + `apt-get install`. No `FROM wordpress`, `FROM nginx`, or `FROM mariadb` anywhere |
| Penultimate stable base | ✅ `debian:bookworm` = Debian **12.15**. Current stable is trixie (13, released Aug 2025), so bookworm is exactly the penultimate |
| Image name == service name | ✅ `mariadb → mariadb:inception`, `wordpress → wordpress:inception`, `nginx → nginx:inception` |
| Built by compose via the Makefile, no crash | ✅ `make` → `docker compose up --build -d`; all three `status=running`, `restarts=0`, `exitcode=0` |

## Backing evidence

```
$ docker images
wordpress:inception   592MB
mariadb:inception     530MB
nginx:inception       212MB

$ docker inspect <each> --format '{{.State.Status}} {{.RestartCount}}'
running 0     (nginx, wordpress, mariadb)
```

## The PID 1 question, which always follows

Every service execs its real daemon, so no keep-alive hack exists anywhere:

| Container | PID 1 | Handed off by |
|---|---|---|
| nginx | `nginx` | `exec nginx -g "daemon off;"` — [init.sh:19](srcs/requirements/nginx/tools/init.sh#L19) |
| wordpress | `php-fpm8.2` | `exec php-fpm${PHP_VERSION} -F` — [init.sh:56](srcs/requirements/wordpress/tools/init.sh#L56) |
| mariadb | `mariadbd` | `exec mariadbd --user=mysql --datadir=/var/lib/mysql` — [init.sh:48](srcs/requirements/mariadb/tools/init.sh#L48) |

A grep for `tail -f`, `sleep infinity`, and `while true` across all three init scripts returns nothing. Say it as: **"`exec` replaces the shell, so the daemon *becomes* PID 1 — it receives signals directly, and if it dies the container dies, which is what lets `restart: always` do its job."**

## Answers to have ready

- **"Why `debian:bookworm` and not a pinned digest?"** → bookworm *is* the release; the tag tracks its point releases (currently 12.15). The subject asks for the penultimate stable release, not a frozen digest.
- **"Isn't pulling `debian:bookworm` from DockerHub forbidden?"** → no. The rule bans ready-made *service* images (`FROM nginx`, `FROM wordpress`); the base OS layer is explicitly what the subject asks you to start `FROM`.
- **"You download wp-cli from GitHub — is that a ready-made image?"** → no, it's a CLI tool fetched into an image built by hand, the same category as an `apt-get install`. Nothing about the WordPress service comes prebuilt.
- **"Why is `PHP_VERSION` an ARG and an ENV?"** → Debian pins one PHP version per release (bookworm ships 8.2) and puts that version in both the config paths and the binary name. Declaring it once as `ARG` and promoting it to `ENV` means the Dockerfile and `init.sh` cannot drift apart.

---

# Docker Network

The rubric: a network declared in `docker-compose.yml`, visible in `docker network ls`, plus a simple spoken explanation of what docker-network is.

**Status: passes.**

| Check | Result |
|---|---|
| Network declared in compose | ✅ [docker-compose.yml:47-49](srcs/docker-compose.yml#L47-L49) — `inception`, `driver: bridge`; all three services list `networks: [inception]` |
| Visible in `docker network ls` | ✅ `inception_inception   bridge   local` |
| No forbidden directives | ✅ grep for `network_mode`, `network: host`, `links:` returns nothing |
| All three containers attached | ✅ mariadb `172.18.0.2`, wordpress `172.18.0.3`, nginx `172.18.0.4` |
| Name resolution works | ✅ `wordpress` resolves `mariadb` → 172.18.0.2; `nginx` resolves `wordpress` → 172.18.0.3 |
| Internal ports sealed from host | ✅ 3306 and 9000 both unreachable from the host; only 443 is published |

## The explanation to say out loud

**"A docker network is a private virtual switch that Docker creates for my containers."**

Then the three things it buys you:

1. **Isolation.** Containers on the network talk to each other freely, but nothing from outside can reach them unless a port is explicitly published. Here only NGINX publishes 443 — `mariadb:3306` and `wordpress:9000` are invisible from the host, which I can prove by trying to connect and failing.

2. **DNS by service name.** Docker runs an internal DNS server on the network, and every service is resolvable by its compose service name. WordPress connects to the database at hostname `mariadb`, NGINX reaches php-fpm at `wordpress:9000`. No hardcoded IPs — which matters because container IPs change every time they're recreated.

3. **Automatic setup.** Compose creates the network on `up` and removes it on `down`. The `_inception` in `inception_inception` is compose prefixing the network name with the project name.

The contrast that shows understanding: **`network: host` would give containers the host's own network stack** — every port they open would be open on the host, there'd be no per-container DNS, and no isolation at all. `links:` is the deprecated pre-network mechanism for connecting containers one-to-one. Both are forbidden by the subject, and a user-defined bridge makes both unnecessary.

## Cleanup before the defense

`docker network ls` currently shows **two** project networks:

```
777f2656c7fb   inception_inception   bridge    local   ← the live one
b27943e2b098   srcs_inception        bridge    local   ← leftover, 0 containers
```

`srcs_inception` is dangling from a run on Jul 27 where `docker compose` was invoked without `-p inception`, so the project name defaulted to the directory name `srcs`. It's empty and unused, but an evaluator running `docker network ls` will see two near-identical networks and ask which one is real. Remove it:

```
docker network rm srcs_inception
```

(Nothing breaks — compose recreates any network it needs on the next `up`.)
