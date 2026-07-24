# NGINX container

The edge of the stack: the single entrypoint into the whole infrastructure. It terminates TLS on port 443, serves WordPress's static files directly, and forwards PHP requests to php-fpm. It is the only container that publishes a port to the host.

Three files define it, the same shape as the other services:

| File | Role | When it acts |
|---|---|---|
| `Dockerfile` | What goes in the image | Build time |
| `conf/nginx.conf` | How NGINX behaves | Read at startup |
| `tools/init.sh` | Generate the TLS cert, then run NGINX | Runtime, as PID 1 |

## Dockerfile

```dockerfile
FROM debian:bookworm

RUN apt-get update && apt-get install -y nginx openssl && \
    rm -rf /var/lib/apt/lists/*

COPY conf/nginx.conf /etc/nginx/nginx.conf
COPY --chmod=755 tools/init.sh /usr/local/bin/init.sh

EXPOSE 443

ENTRYPOINT ["/usr/local/bin/init.sh"]
```

- **`nginx openssl`**: the web server, plus the tool `init.sh` uses to generate the certificate.
- **`COPY conf/nginx.conf /etc/nginx/nginx.conf`**: the destination is the **main** config, not a snippet in `conf.d/`. We replace NGINX's entire configuration, which guarantees the Debian default's port-80 server never exists. The subject requires 443 only.
- **`EXPOSE 443`**: documentation only. The actual publishing is `ports: - "443:443"` in compose, and this is the *only* service with a `ports:` entry.
- **`ENTRYPOINT`**: `init.sh` becomes PID 1.

## conf/nginx.conf

```nginx
user www-data;
events {}

error_log /dev/stderr;

http {
    include /etc/nginx/mime.types;
    default_type application/octet-stream;
    access_log /dev/stdout;

    server {
        listen 443 ssl;
        server_name lprieri.42.fr;

        ssl_protocols TLSv1.2 TLSv1.3;
        ssl_certificate     /etc/nginx/ssl/inception.crt;
        ssl_certificate_key /etc/nginx/ssl/inception.key;

        root /var/www/html;
        index index.php;

        location / {
            try_files $uri $uri/ /index.php?$args;
        }

        location ~ \.php$ {
            include fastcgi_params;
            fastcgi_pass wordpress:9000;
            fastcgi_param SCRIPT_FILENAME $document_root$fastcgi_script_name;
        }
    }
}
```

NGINX config is a tree of contexts, read outside-in:

- **`user www-data`**: worker processes run as this unprivileged user (the master starts as root to bind 443, then workers drop). We pick `www-data` because it owns the WordPress files, so NGINX can read them.
- **`events {}`**: a mandatory block (NGINX won't start without it); empty means "use defaults."
- **`error_log`/`access_log` to `/dev/stderr`/`/dev/stdout`**: log to Docker, the same convention as MariaDB and php-fpm.
- **`listen 443 ssl`**: accept only TLS connections on 443. With the compose `ports:` mapping, this makes NGINX the single entrypoint.
- **`ssl_protocols TLSv1.2 TLSv1.3`**: the literal subject requirement; older protocols are refused.
- **`ssl_certificate` / `ssl_certificate_key`**: must match the paths `init.sh` writes to.
- **`root /var/www/html`**: served from the `wp_data` volume, shared with the WordPress container.
- **`location /` + `try_files $uri $uri/ /index.php?$args`**: serve a real file if it exists, otherwise fall through to `index.php`. That fallback is how WordPress "pretty permalinks" work: `/about/` isn't a file, so it goes to `index.php`, which figures out the page.
- **`location ~ \.php$`**: `~` is a regex match on URLs ending in `.php`. This block does **not** serve the file; it forwards it:
  - **`fastcgi_pass wordpress:9000`**: open a FastCGI connection to the wordpress container's php-fpm. Docker DNS resolves `wordpress` over the bridge network. This is where the two containers actually talk.
  - **`SCRIPT_FILENAME $document_root$fastcgi_script_name`** = `/var/www/html/index.php`, the file php-fpm must open. That path resolves *inside the wordpress container*, which is why both containers mount the same volume at `/var/www/html`: NGINX names the file, php-fpm opens it.

## tools/init.sh

```bash
#!/bin/bash
set -e

CERT_DIR=/etc/nginx/ssl
mkdir -p "$CERT_DIR"

if [ ! -f "$CERT_DIR/inception.crt" ]; then
	openssl req -x509 -nodes -days 365 \
		-newkey rsa:2048 \
		-keyout "$CERT_DIR/inception.key" \
		-out "$CERT_DIR/inception.crt" \
		-subj "/CN=${DOMAIN_NAME}"
fi

exec nginx -g "daemon off;"
```

Two jobs: make a certificate, then become the server.

- **Why self-signed:** no public CA issues certificates for `.42.fr` (it isn't a real domain), so NGINX signs its own. The browser warns once; the connection is still encrypted.
- **`openssl req` flags:**
  - `-x509`: output a finished self-signed certificate, not a signing request (CSR) for a CA.
  - `-nodes`: no passphrase on the private key, so NGINX can start unattended (a passphrase-protected key would hang at startup waiting for input).
  - `-newkey rsa:2048`: generate a fresh 2048-bit RSA key in the same command.
  - `-subj "/CN=${DOMAIN_NAME}"`: fill in the subject non-interactively; `DOMAIN_NAME` comes from `.env`. Without it, openssl prompts for country/org/etc.
- **`exec nginx -g "daemon off;"`**: the PID 1 pattern. `exec` replaces bash with NGINX (same PID). `daemon off` stops NGINX from forking into the background; if it did, the foreground process would exit and Docker would kill the container. Staying in the foreground means NGINX is PID 1 and receives SIGTERM directly on `docker compose down`.

## Testing

With the stack up (`make`):

```bash
# 1. HTTPS homepage is WordPress, and returns 200
curl -k https://lprieri.42.fr/          # needs 127.0.0.1 lprieri.42.fr in /etc/hosts

# 2. TLS 1.2/1.3 only, an older version must be refused
curl -k --tls-max 1.1 https://lprieri.42.fr/   # should fail

# 3. The certificate's CN
echo | openssl s_client -connect 127.0.0.1:443 -servername lprieri.42.fr 2>/dev/null \
    | openssl x509 -noout -subject

# 4. Port 80 must be closed (443 only)
curl http://127.0.0.1:80/               # should refuse
```

Expect: a `200` page titled "Inception" containing `wp-content`; the TLS 1.1 attempt refused; `subject=CN=lprieri.42.fr`; port 80 refused.
