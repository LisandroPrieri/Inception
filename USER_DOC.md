# User Documentation

How to use and administer the Inception stack as an end user or site administrator. For setup from scratch and internals, see [DEV_DOC.md](DEV_DOC.md).

## What this stack provides

One website, served by three cooperating services, each in its own Docker container:

| Service | What it does for you |
|---|---|
| **NGINX** | The front door: receives all browser traffic, HTTPS only, port 443 |
| **WordPress** | The website itself: pages, posts, media, and the admin panel |
| **MariaDB** | The database where all content (posts, users, settings) is stored |

Only NGINX is reachable from outside. Site content and the database survive restarts: they are stored permanently under `/home/lprieri/data/` on the host machine.

## Starting and stopping the project

Run these from the repository root, inside the VM:

| Command | Effect |
|---|---|
| `make` | Build (if needed) and start all services in the background |
| `make down` | Stop everything (**your data is kept**) |
| `make logs` | Watch live output of all services (Ctrl-C to stop watching) |
| `make re` | Full reset: wipe everything **including all site data**, rebuild, restart |
| `make fclean` | Stop and delete everything, including all data (irreversible) |

## Accessing the website and the admin panel

The site answers only to the name `lprieri.42.fr`. Map that name to the machine once, in `/etc/hosts` of the machine where your browser runs:

```
127.0.0.1    lprieri.42.fr
```

(Use the VM's IP address instead of `127.0.0.1` if your browser runs outside the VM.)

Then:

- **Website:** https://lprieri.42.fr
- **Admin panel:** https://lprieri.42.fr/wp-admin

The first visit shows a certificate warning: the site uses a self-signed TLS certificate, because no public certificate authority issues certificates for `.42.fr` names. Accept the warning; the connection is still encrypted.

Log in to the admin panel with the administrator account, or with the second (non-administrator) account for daily editing. Usernames live in `srcs/.env`; passwords in the `secrets/` folder (next section).

## Credentials: where they live and how to manage them

| What | Where |
|---|---|
| Domain name, database name, usernames, emails | `srcs/.env` |
| Database user password | `secrets/db_password.txt` |
| Database root password | `secrets/db_root_password.txt` |
| WordPress account passwords | `secrets/credentials.txt` |

The `secrets/` files are plain text, exist only on this machine, and are **never committed to git** (`.gitignore` excludes them).

To change credentials: edit these files **before the first launch**. After the stack has been initialized, the passwords live inside the database, so change them through the WordPress admin panel (WordPress accounts) or with SQL (database accounts), or start over with `make re` (which erases all site content).

## Checking that the services are running

1. **Containers up?** `docker ps` should list three containers (`nginx`, `wordpress`, `mariadb`), each with status `Up`. A crashing service shows `Restarting`.
2. **Website responding?** Open https://lprieri.42.fr, or from the VM run `curl -k https://lprieri.42.fr`.
3. **Database alive?** `docker exec mariadb mysqladmin ping` answers `mysqld is alive`.
4. **Something wrong?** `make logs` shows what every service is doing; errors appear there.
