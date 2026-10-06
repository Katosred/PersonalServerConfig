FROM rclone/rclone:latest
USER root
RUN apk add --no-cache bash curl jq findutils coreutils
COPY migrate.sh /usr/local/bin/migrate.sh
RUN chmod +x /usr/local/bin/migrate.sh
ENTRYPOINT ["/usr/local/bin/migrate.sh"]
