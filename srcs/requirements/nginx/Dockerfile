FROM debian:bookworm

RUN apt-get update && apt-get install -y nginx openssl && \
	rm -rf /var/lib/apt/lists/*

COPY conf/nginx.conf /etc/nginx/nginx.conf
COPY --chmod=755 tools/init.sh /usr/local/bin/init.sh

EXPOSE 443

ENTRYPOINT ["/usr/local/bin/init.sh"]
