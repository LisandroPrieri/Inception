# Developer Documentation

How to set up, build, and operate the Inception stack from a clean machine. For end-user/administrator usage, see [USER_DOC.md](USER_DOC.md). Per-service deep dives: [srcs/requirements/mariadb/README.md](srcs/requirements/mariadb/README.md), [srcs/requirements/wordpress/README.md](srcs/requirements/wordpress/README.md), [srcs/requirements/nginx/README.md](srcs/requirements/nginx/README.md).

## Prerequisites

- A Linux virtual machine (this project targets Ubuntu under VirtualBox)
- Docker Engine with the Compose plugin (`docker compose version` must work)
- Your user in the `docker` group: `sudo usermod -aG docker $USER`, then a full logout/login
- `make` and `git`

## Setting up the environment from scratch

1. **Clone the repository** and `cd` into it.

2. **Create the environment file** from the template and fill in real values:

   ```
   cp srcs/.env.example srcs/.env
   ```

   It holds only *non-secret* configuration: `DATA_DIR`, `DOMAIN_NAME`, `MYSQL_DATABASE`, `MYSQL_USER`, WordPress usernames and emails. No passwords go in this file.

   `DATA_DIR` is the host directory where the volumes are stored, and both the Makefile and `docker-compose.yml` read it from here. On the evaluation VM it must be `/home/<login>/data` as the subject requires; set it to any writable path when developing on another machine.

3. **Create the secret files**: a `secrets/` directory at the repo root, git-ignored, one password per file:

   ```
   secrets/
   ├── db_password.txt        # password of the WordPress database user (one line)
   ├── db_root_password.txt   # password of the MariaDB root account (one line)
   └── credentials.txt        # WordPress account passwords (KEY=value lines:
                              #   WP_ADMIN_PASSWORD=..., WP_USER_PASSWORD=...)
   ```

   Compose mounts these into the containers at `/run/secrets/<name>`; the init scripts read them there at startup.

4. **Launch:** `make`

5. **Point the domain at the machine.** The site answers only to `lprieri.42.fr`, so map that name to the loopback address on whatever machine runs the browser (inside the VM, that's `127.0.0.1`). This appends one line to `/etc/hosts`:

   ```
   echo "127.0.0.1 lprieri.42.fr" | sudo tee -a /etc/hosts
   ```

   `tee` (rather than `echo ... >> /etc/hosts`) is needed because the redirection in `sudo echo ... >>` runs as your unprivileged shell and is denied; `sudo tee` does the privileged write. Then open **https://lprieri.42.fr** and accept the self-signed certificate warning.

## Building and launching

The Makefile wraps Docker Compose (project name `inception`, compose file `srcs/docker-compose.yml`):

| Target | What it does |
|---|---|
| `make` / `make up` | create `$DATA_DIR/{mariadb,wordpress}`, then `docker compose up --build -d` |
| `make down` | stop and remove containers and network; volumes and data survive |
| `make logs` | `docker compose logs -f` |
| `make fclean` | `down` plus removal of this project's images and volumes, and delete `$DATA_DIR` |
| `make re` | `fclean` followed by a full rebuild (a from-scratch first boot) |

## Managing containers and volumes

All compose commands need the project flags; define a shorthand if you use them often:

```
alias dc='docker compose -f srcs/docker-compose.yml -p inception'
```

| Task | Command |
|---|---|
| Status of the services | `dc ps` |
| Logs of one service | `dc logs -f mariadb` |
| Shell inside a container | `docker exec -it wordpress bash` |
| Rebuild + restart one service | `dc up --build -d wordpress` |
| Database shell | `docker exec -it mariadb mysql -u wp_user -p wordpress` |
| List volumes / inspect one | `docker volume ls`, `docker volume inspect inception_db_data` |
| List the network | `docker network ls` (look for `inception_inception`) |

## Where data lives and how it persists

Two named volumes, declared in `docker-compose.yml`, their storage placed under `$DATA_DIR` on the host (`/home/lprieri/data` on the VM):

| Volume | Container path | Host path | Contents |
|---|---|---|---|
| `db_data` | `/var/lib/mysql` (mariadb) | `$DATA_DIR/mariadb` | the database files |
| `wp_data` | `/var/www/html` (wordpress + nginx) | `$DATA_DIR/wordpress` | the WordPress site files |

Persistence semantics:

- **`make down` / container crash / rebuild**: data survives. Containers are disposable; volumes are not destroyed with them.
- **`make fclean` / `make re`**: data is deliberately erased (`rm -rf /home/lprieri/data`).
- **First boot vs restart**: both init scripts use the volume as their marker. MariaDB runs its database setup only if `/var/lib/mysql/mysql` doesn't exist; WordPress downloads core and installs the site only if `/var/www/html` is empty. A restart with existing data skips setup entirely, which is what makes the containers safe to destroy and recreate.
