# mbsync-restic-backup

Daily backup of one IMAP mailbox, in a single Docker container.

[mbsync](https://isync.sourceforge.io/) pulls every folder into a local Maildir, and
[restic](https://restic.net/) snapshots it. Optionally, the restic repository is copied to a second host over
SSH. The sync is one-way: nothing is written to the server and nothing is deleted locally, so a letter deleted in
the mailbox stays in the backup.

Built for a Yandex 360 mailbox that kept dropping sessions and refusing letters after its provider lost data
centers.

Limits: implicit TLS only (port 993, `TLSType IMAPS`) and password login only (`AuthMechs LOGIN`). No STARTTLS on
143, no OAuth, so it won't work with Microsoft 365 once basic auth is off. For Gmail, exclude `[Gmail]/All Mail`
(see `EXTRA_PATTERNS`), or the whole mailbox is stored twice.

## What a run does

1. **Sync.** mbsync downloads new letters from every folder into `DATA_DIR/maildir`. If the server drops the
   connection, mbsync is started again, up to 3 times per run, and continues where it stopped.
2. **Snapshot.** restic snapshots the Maildir into `DATA_DIR/restic`. Retention: 30 daily, 8 weekly, 24 monthly.
   Once a week `restic check` reads 10% of the data. If the sync failed, the snapshot is still taken, but retention
   is skipped and the run counts as failed.
3. **Copy** (optional). rsync sends the repository files the second host doesn't have yet.

The scheduler (supercronic) runs this daily at 04:30 by default. Two runs never overlap.

## Install

You need Docker with Compose, and a directory for the data.

```sh
git clone https://github.com/adsdevdoo/mbsync-restic-backup.git
cd mbsync-restic-backup
cp .env.example .env               # set DATA_DIR, IMAP_HOST, IMAP_USER
mkdir -p secrets && chmod 700 secrets
read -rs p && printf '%s' "$p" > secrets/imap_password; unset p     # type the IMAP password, Enter
head -c 32 /dev/urandom | base64 > secrets/restic_password
chmod 600 secrets/*
mkdir -p /srv/mail-backup          # the DATA_DIR from .env
docker compose up -d --build
docker exec mail-backup backup.sh init
```

**Save `secrets/restic_password` in your password manager.** Without it the snapshots can't be opened.

The first download of a big mailbox takes hours. Start it now instead of waiting for the schedule, detached from
your shell, with the output going to `docker logs`:

```sh
docker exec -d mail-backup sh -c 'backup.sh >/proc/1/fd/1 2>&1'
docker logs -f mail-backup
```

A run ends with `done: N letters, …`.

The data directory must exist before `up`. Compose won't create it, so that a backup never lands on the root disk
when the backup disk isn't mounted. For the same reason a run never creates the repository; only `init` does.

## Settings

All settings are in `.env`; see `.env.example`. The main ones:

| Variable | Default | |
|---|---|---|
| `DATA_DIR` | — | host directory for Maildir, repository and state |
| `IMAP_HOST`, `IMAP_PORT`, `IMAP_USER` | —, 993, — | the mailbox; password in `secrets/imap_password` |
| `SCHEDULE`, `TZ` | `30 4 * * *`, UTC | when to run |
| `KEEP_DAILY`, `KEEP_WEEKLY`, `KEEP_MONTHLY` | 30, 8, 24 | snapshot retention |
| `PIPELINE_DEPTH` | 8 | IMAP commands in flight |
| `MBSYNC_ATTEMPTS` | 3 | mbsync restarts per run after a dropped connection |
| `REFUSED_PATTERN` | any text | which server answers to a letter fetch count as a refused letter (regex) |
| `REFUSED_MAX` | 1000 | more refused letters in one attempt fail the run; 0 = no limit |
| `EXTRA_PATTERNS` | — | extra mbsync patterns, e.g. `!"[Gmail]/All Mail"` |
| `NEVER_PARK` | `INBOX Sent Drafts` | folders never parked; space-separated, empty = none |
| `COPY_TARGET`, `COPY_PORT` | off, 22 | off-host copy, `user@host:path`; the colon is required |

After changing `.env`, run `docker compose up -d`. Values with brackets, quotes or spaces need no quoting (checked
with Compose v5.1); to be sure they arrived as written: `docker exec mail-backup printenv REFUSED_PATTERN`.

## Refused letters

Some servers refuse single letters. Yandex 360 answers `[UNAVAILABLE] … backend error`: sometimes for a moment,
sometimes for weeks. mbsync skips such a letter. A run whose only errors are refused letters still counts as a
success. Each run logs the distinct refusal texts (`mbsync: refused: …`).

By default any error answer to a letter fetch counts as a refusal. If your server has a specific one, set
`REFUSED_PATTERN` (for Yandex 360: `\[UNAVAILABLE\]`), so that other answers fail the run. Independently, more
than `REFUSED_MAX` refusals in one attempt fail the run: a server that refuses everything (a download cap, a
quota, an outage) must not look like a good backup.

mbsync never asks for a skipped letter again on its own, so the script keeps a list: `DATA_DIR/state/unfetchable.tsv`,
with folder, UID, first and last seen, and attempts. To ask the server for them again:

```sh
docker exec -d mail-backup sh -c 'backup.sh retry >/proc/1/fd/1 2>&1'
```

With a long list, the attempt may refuse more than `REFUSED_MAX` letters and fail; lift the limit for this run:
`docker exec -d -e REFUSED_MAX=0 mail-backup sh -c 'backup.sh retry >/proc/1/fd/1 2>&1'`. Same for `rewind-all`.

Letters that come through move to `state/unfetchable-recovered.tsv`. It's a manual command on purpose: if the
nightly run did this, a block the server keeps refusing would eat every nightly session.

`backup.sh rewind-all` does the same for every folder and every letter that has no copy. That covers refusals that
were never listed, for example from before you started using this script.

Both commands work by lowering `MaxPulledUid` in mbsync's per-folder state. mbsync then walks the folder again,
skips what it has and asks for the rest. Nothing is downloaded twice.

## Parked folders

Until a folder is finished, mbsync retries its refused letters from the lowest UID in every attempt. If the server
refuses a block longer than one session lasts, the folder never finishes, and neither does the rest of the mailbox.

So a folder is **parked** (left out of the sync) when two attempts in a row were cut off in it and each had both:
- at least 300 refusals in that folder;
- more than twice as many refusals as letters stored from it.

A folder that is merely slow doesn't qualify. INBOX, Sent and Drafts are never parked; if they stall, the run fails.

Parked folders are listed in `state/parked.txt`, one per line. To take a folder back, remove its line; if the
server still refuses the block, the folder parks itself again:

```sh
docker exec mail-backup flock /data/.backup.lock sh -c 'f=/data/state/parked.txt; grep -vxF -- "$1" "$f" >"$f.edit"; [ $? -le 1 ] && mv "$f.edit" "$f"' _ 'Folder name'
```

While a folder is parked, nothing in it is backed up, new mail included.

## A folder deleted or renamed on the server

mbsync then fails on the local folder in every run. Move the local copy out of the sync, into `maildir-gone/`,
which is still in every snapshot:

```sh
docker exec mail-backup flock /data/.backup.lock sh -c 'umask 077; mkdir -p /data/maildir-gone; mv "/data/maildir/$1" /data/maildir-gone/' _ 'Folder name'
```

## Off-host copy

Set `COPY_TARGET` and put an SSH key in `secrets/copy_ssh_key` and the target's host key in
`secrets/copy_known_hosts`:

```sh
ssh-keygen -t ed25519 -N '' -f secrets/copy_ssh_key
ssh-keyscan -p 22 -t ed25519 backup-host.example > secrets/copy_known_hosts    # same port as COPY_PORT
ssh-keygen -lf secrets/copy_known_hosts     # compare with the fingerprint shown on the target
```

With the rrsync line below, use an empty path: `COPY_TARGET=backup@backup-host.example:`. The files then land
right in the rrsync directory.

On the target, restrict the key to adding files in one directory, with `rrsync` from the rsync package:

```
restrict,from="10.0.0.5",command="/usr/bin/rrsync -wo -no-del /srv/mail-backup-copy" ssh-ed25519 AAAA… mail-backup
```

Repository files never change once written, so adding the new ones keeps the copy a valid restic repository. It is
a superset: snapshots pruned locally stay there. Nothing prunes the copy, so pick the snapshot by date when you
restore from it. `-no-del` blocks deletion, not overwriting; use `chattr +i` on the target if that matters.

A failed copy doesn't fail the run. It has its own metric (below).

## Restore

```sh
docker exec mail-backup restic snapshots
docker exec mail-backup restic restore latest --target /data/restore
docker exec mail-backup restic restore latest --target /data/restore --include /data/maildir/INBOX
```

The result lands in `DATA_DIR/restore/data/maildir/`. Each letter is a file you can open as `.eml`, or the whole
folder can be pushed back to a server with mbsync (`Sync Push`) or imapsync.

When pushing back, mind two things:
- Letters deleted on the server carry the `T` flag in the file name (`…:2,ST`). Drop it, or they arrive marked
  as deleted.
- The restored files are root-only (600).

To restore from the copy: get the directory to any machine with restic and run
`restic -r <dir> restore latest --target …` with the same password.

## Metrics

Mount a node_exporter textfile collector directory at `/metrics` (see `compose.yml`) to get:

| Metric | |
|---|---|
| `mail_backup_last_success_timestamp_seconds` | last good run |
| `mail_backup_last_failure_timestamp_seconds` | last failed run |
| `mail_backup_letters`, `mail_backup_maildir_bytes`, `mail_backup_repository_bytes` | size after the last good run |
| `mail_backup_unfetchable_messages`, `mail_backup_parked_folders` | refused letters, parked folders |
| `mail_backup_copy_last_success_timestamp_seconds`, `…_copy_last_failure_…` | off-host copy |

Useful alerts:
- no success for 26 hours: `time() - mail_backup_last_success_timestamp_seconds > 26*3600`;
- the last run failed: failure newer than success;
- new refused letters: `mail_backup_unfetchable_messages` grew over a day;
- a new parked folder: `mail_backup_parked_folders` grew over a day.

## Yandex 360 notes

- **IMAP needs a paid plan.** Organizations without a paid plan can't use IMAP, and an organization admin can
  also switch IMAP off for everyone (the `enable_imap` mail setting). In both cases the user's mail settings say
  that mail clients can't be set up for this account.
- **App password.** Use an app password (Yandex ID → Security → App passwords → Mail). The account password
  doesn't work over IMAP.
- **Session lifetime.** A session lasts about 30 minutes, then the server sends `BYE … session lifetime exceeded`.
  The first download of a big mailbox needs many runs. Let it loop until a run finishes (`WAIT_FOR_LOCK=yes`:
  wait for a scheduled run instead of skipping):

  ```sh
  docker exec -d -e WAIT_FOR_LOCK=yes mail-backup sh -c 'for i in $(seq 1 60); do backup.sh && break; sleep 60; done >/proc/1/fd/1 2>&1'
  ```
- **Refusals.** Set `REFUSED_PATTERN=\[UNAVAILABLE\]`. During an outage there may be thousands of refusals; raise
  `REFUSED_MAX` or set it to 0 for the first download.
- **Pipelining.** `PIPELINE_DEPTH` above 1 barely helps against refusals: the server seems to answer the commands
  of one connection in order.

## Files

| | |
|---|---|
| `backup.sh` | everything a run does; the comments at the top explain the less obvious parts |
| `entrypoint.sh` | writes the crontab from `SCHEDULE` and starts supercronic |
| `Dockerfile` | Alpine with isync, restic, supercronic, rsync |
| `compose.yml`, `.env.example` | how to run it |
| `tests/test.sh` | tests against a stub mbsync, no mailbox needed: `sh tests/test.sh` (Docker; the first build downloads Alpine packages) |
| `CLAUDE.md` | rules for changing the code, and what we learned about mbsync and Yandex 360 |

Inside `DATA_DIR`:

| | |
|---|---|
| `maildir/` | the Maildir |
| `restic/` | the repository |
| `state/` | refused letters, parked folders; included in every snapshot |
| `maildir-gone/` | put folders here by hand that were deleted on the server; they stay in every snapshot |
| `.mbsync-last.log` | full mbsync output of the last run |

## License

MIT
