#!/bin/sh
# No arguments: run the scheduler, backup.sh on SCHEDULE (cron syntax, default daily 04:30 in TZ).
# With arguments: run them instead, e.g. `docker compose run --rm mail-backup backup.sh init`.
set -eu

if [ "$#" -gt 0 ]; then
    exec "$@"
fi

echo "${SCHEDULE:-30 4 * * *} /usr/local/bin/backup.sh" >/tmp/crontab
# Absolute path: as PID 1 supercronic re-executes itself by argv[0] to reap children.
exec /usr/bin/supercronic -passthrough-logs /tmp/crontab
