FROM alpine:3.22

# GNU grep and gawk: backup.sh needs grep --line-buffered and awk the busybox applets do not have.
# rsync and openssh-client: the optional off-host copy.
RUN apk add --no-cache bash ca-certificates coreutils findutils gawk grep isync openssh-client restic rsync supercronic tzdata util-linux-misc

COPY backup.sh entrypoint.sh /usr/local/bin/
RUN chmod 755 /usr/local/bin/backup.sh /usr/local/bin/entrypoint.sh

ENV TZ=UTC \
    RESTIC_REPOSITORY=/data/restic \
    RESTIC_PASSWORD_FILE=/run/secrets/restic_password \
    RESTIC_CACHE_DIR=/data/cache
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
