# mbsync-restic-backup

[![build](https://github.com/adsdevdoo/mbsync-restic-backup/actions/workflows/build.yml/badge.svg)](https://github.com/adsdevdoo/mbsync-restic-backup/actions/workflows/build.yml)
[![ghcr.io](https://img.shields.io/badge/ghcr.io-adsdevdoo%2Fmbsync--restic--backup-blue?logo=github)](https://github.com/adsdevdoo/mbsync-restic-backup/pkgs/container/mbsync-restic-backup)
[![Docker Hub](https://img.shields.io/docker/v/adsdevdoo/mbsync-restic-backup?sort=semver&logo=docker&label=docker%20hub)](https://hub.docker.com/r/adsdevdoo/mbsync-restic-backup)
[![Docker pulls](https://img.shields.io/docker/pulls/adsdevdoo/mbsync-restic-backup?logo=docker)](https://hub.docker.com/r/adsdevdoo/mbsync-restic-backup)
[![image size](https://img.shields.io/docker/image-size/adsdevdoo/mbsync-restic-backup/latest?logo=docker)](https://hub.docker.com/r/adsdevdoo/mbsync-restic-backup)
![platforms](https://img.shields.io/badge/platforms-amd64%20%7C%20arm64-lightgrey)
[![release](https://img.shields.io/github/v/release/adsdevdoo/mbsync-restic-backup?sort=semver)](https://github.com/adsdevdoo/mbsync-restic-backup/releases)
[![license](https://img.shields.io/github/license/adsdevdoo/mbsync-restic-backup)](LICENSE)
[![last commit](https://img.shields.io/github/last-commit/adsdevdoo/mbsync-restic-backup)](https://github.com/adsdevdoo/mbsync-restic-backup/commits/main)

**English** | [Русский](README.ru.md)

Daily backup of one IMAP mailbox, in a single Docker container.

[mbsync](https://isync.sourceforge.io/) pulls every folder into a local Maildir, and
[restic](https://restic.net/) snapshots it. Optionally, the restic repository is copied to a second host over
SSH. The sync is one-way: nothing is written to the server and nothing is deleted locally, so a letter deleted in
the mailbox stays in the backup.

Built for a Yandex 360 mailbox that kept dropping sessions and refusing letters after its provider lost data
centers. Setting up Yandex 360 for IMAP, step by step with screenshots (in Russian):
[docs/yandex-360.md](docs/yandex-360.md).

<!-- Absolute URL: this README is also the Docker Hub description, where a relative image path does not load. -->
![Grafana dashboard: run state, letters, sizes, refused letters, parked folders](https://raw.githubusercontent.com/adsdevdoo/mbsync-restic-backup/main/docs/img/grafana-dashboard.png)

Limits: implicit TLS only (port 993, `TLSType IMAPS`) and password login only (`AuthMechs LOGIN`). No STARTTLS on
143, no OAuth, so it won't work with Microsoft 365 once basic auth is off. For Gmail, exclude `[Gmail]/All Mail`
(see `EXTRA_PATTERNS`), or the whole mailbox is stored twice.

## Features

- **One-way, nothing lost.** Pull-only sync: the mailbox is never changed, deleted letters stay in the backup.
- **Snapshots, not a mirror.** restic keeps daily, weekly and monthly snapshots, deduplicated and encrypted.
- **Survives a flaky server.** Restarts after dropped sessions and goes on where it stopped, even in folders too
  big for one session; keeps a list of letters the server refuses and fetches them again later.
- **Per-folder counts:** letters on the server, here, refused, so you see what is left without checking by hand.
- **Parallel sessions** for slow servers.
- **Off-host copy** to a second machine over SSH, with a key that can only add files (rrsync).
- **Metrics and a Grafana dashboard**, live while a sync runs.
- **One container**, amd64 and arm64, settings in `.env`.

## Quick start

```sh
git clone https://github.com/adsdevdoo/mbsync-restic-backup.git && cd mbsync-restic-backup
cp .env.example .env                 # DATA_DIR, IMAP_HOST, IMAP_USER
mkdir -p secrets && chmod 700 secrets
read -rs p && printf '%s' "$p" > secrets/imap_password; unset p
head -c 32 /dev/urandom | base64 > secrets/restic_password && chmod 600 secrets/*
mkdir -p /srv/mail-backup            # the DATA_DIR from .env
docker compose pull && docker compose up -d && docker exec mail-backup backup.sh init
```

The first backup then runs on the schedule (04:30); to start it now, see [Install](#install). Details, and what
to save in your password manager, are there too.

## Image tags

Images for `linux/amd64` and `linux/arm64`, the same in both registries:

- `ghcr.io/adsdevdoo/mbsync-restic-backup`
- [`adsdevdoo/mbsync-restic-backup`](https://hub.docker.com/r/adsdevdoo/mbsync-restic-backup) (Docker Hub)

| Tag | What it is | Use it when |
|---|---|---|
| `latest` | the newest release | you want releases, no pinning |
| `1`, `1.2`, `1.2.3` | the newest `1.x.x`, the newest `1.2.x`, exactly `1.2.3` | `1`: updates without breaking changes; `1.2.3`: nothing changes until you decide |
| `edge` | the current `main`, not released yet | trying what's coming |
| `sha-abc1234`, full commit SHA | one exact commit | pinning a deployment to a commit |

`compose.yml` runs `latest`; set `IMAGE` in `.env` to pick another tag, or your own build
(`docker build -t mbsync-restic-backup:local .`, then `IMAGE=mbsync-restic-backup:local`).

Versions follow [Semantic Versioning](https://semver.org/): a new major version means something you have to act on
(settings, data layout, metric names). Changes are listed in [CHANGELOG.md](CHANGELOG.md) and on the
[releases page](https://github.com/adsdevdoo/mbsync-restic-backup/releases).

## What a run does

1. **Count.** The number of letters in every folder on the server (IMAP `STATUS`, one connection), for the
   per-folder metrics.
2. **Sync.** mbsync downloads new letters from every folder into `DATA_DIR/maildir`. If the server drops the
   connection, mbsync is started again, up to 3 times per run, and continues where it stopped (see
   [Big folders](#big-folders)). With `PARALLEL=N`
   the folders are split into N groups, one session each, all at the same time; useful when the server is slow to
   answer (each session has its own queue). Servers limit simultaneous IMAP connections (Gmail allows 15; Yandex
   doesn't publish its limit): start with 2.
3. **Snapshot.** restic snapshots the Maildir into `DATA_DIR/restic`. Retention: 30 daily, 8 weekly, 24 monthly.
   Once a week `restic check` reads 10% of the data. If the sync failed, the snapshot is still taken, but retention
   is skipped and the run counts as failed.
4. **Copy** (optional). rsync sends the repository files the second host doesn't have yet.

The scheduler (supercronic) runs this daily at 04:30 by default. Two runs never overlap.

## Install

You need Docker with Compose, and a directory for the data. Which image tag to run: see [Image tags](#image-tags).

```sh
git clone https://github.com/adsdevdoo/mbsync-restic-backup.git
cd mbsync-restic-backup
cp .env.example .env               # set DATA_DIR, IMAP_HOST, IMAP_USER
mkdir -p secrets && chmod 700 secrets
read -rs p && printf '%s' "$p" > secrets/imap_password; unset p     # type the IMAP password, Enter
head -c 32 /dev/urandom | base64 > secrets/restic_password
chmod 600 secrets/*
mkdir -p /srv/mail-backup          # the DATA_DIR from .env
docker compose pull && docker compose up -d
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
| `PARALLEL` | 1 | mbsync sessions at the same time, each on its own share of the folders (1-8) |
| `PROGRESS_INTERVAL` | 60 | while mbsync runs, write letters and sizes every N seconds (0 = after each attempt only) |
| `PIPELINE_DEPTH` | 8 | IMAP commands in flight |
| `MBSYNC_ATTEMPTS` | 3 | mbsync restarts per run after a dropped connection |
| `REFUSED_PATTERN` | any text | which server answers to a letter fetch count as a refused letter (regex) |
| `REFUSED_MAX` | 1000 | more refused letters in one attempt fail the run; 0 = no limit |
| `EXTRA_PATTERNS` | — | extra mbsync patterns, e.g. `!"[Gmail]/All Mail"` |
| `NEVER_PARK` | `INBOX Sent Drafts` | folders never parked; space-separated, empty = none |
| `PARK_AFTER` | 2 | stalled attempts in a row before a folder is parked: 2 or 1 |
| `COPY_TARGET`, `COPY_PORT` | off, 22 | off-host copy, `user@host:path`; the colon is required |

After changing `.env`, run `docker compose up -d`. To update to the latest image:
`docker compose pull && docker compose up -d`; with your own build, rebuild it and run `docker compose up -d`.
Not during a run: a killed mbsync just resumes from its journal, but a killed restic leaves a repository lock, and
the next runs fail until it is 30 minutes old (or run `docker exec mail-backup restic unlock` once no restic runs).

Values with brackets, quotes or spaces need no quoting (checked with Compose v5.1); to be sure they arrived as
written: `docker exec mail-backup printenv REFUSED_PATTERN`.

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

## Big folders

mbsync writes a folder's state only when it finishes the folder; until then it keeps a journal. A folder too big
for one session (Yandex 360 drops a session after about 30 minutes) never finishes, and every attempt asks again,
from the lowest UID, for all the letters refused before. After a few attempts the whole session goes on old
refusals and nothing new comes.

So after an attempt cut off in a folder, the script does what mbsync does when it finishes one: folds the journal
into the state file, with every stored letter and its flags, and moves `MaxPulledUid` up to the end of the unbroken
run of letters the attempt dealt with (`mbsync: checkpoint of …` in the log). The next attempt goes on from there.
Every letter whose fetch failed up to there (refused or not) goes on the list for `retry`; letters queued but not
reached come next time. The folded journal is kept in `DATA_DIR/.journals/` (the last one per folder, not in the
snapshots).

A letter deleted on the server between the listing and its fetch also counts as failed. It stays on the list (and
in the refused count) until you remove its line:

```sh
docker exec mail-backup flock /data/.backup.lock gawk -i inplace -F'\t' -v f='Folder name' -v u=UID '!($1 == f && $2 == u)' /data/state/unfetchable.tsv
```

## Parked folders

A fallback, for a cut-off folder no checkpoint could be written for (no journal to fold) or where one would not
move anything (the server gave nothing in the whole attempt): a folder is
**parked** (left out of the sync) when two attempts in a row (`PARK_AFTER=2`, the default; `1` parks after the
first) were cut off in it and each had both:
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
restrict,from="10.0.0.5",command="/usr/bin/rrsync -wo -no-del -no-overwrite -munge /srv/mail-backup-copy" ssh-ed25519 AAAA… mail-backup
```

- `-munge` is what keeps the key inside the directory: without it a compromised backup host can upload a symbolic
  link and write through it outside the directory, e.g. into the user's `~/.ssh`, and get a shell on the target
  (rsync older than 3.5 lets it). Keep it.
- `-no-del` blocks deletion, `-no-overwrite` overwriting a file that is there. `-no-overwrite` needs rsync 3.3 or
  newer on the target; with an older one (Debian 12, Ubuntu 24.04) use `-wo -no-del -munge`, and protect the
  received files with `chattr +i` if a compromised backup host must not be able to spoil the copy.

Repository files never change once written, so adding the new ones keeps the copy a valid restic repository. It is
a superset: snapshots pruned locally stay there. Nothing prunes the copy, so pick the snapshot by date when you
restore from it.

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
| `mail_backup_letters`, `mail_backup_maildir_bytes`, `mail_backup_repository_bytes` | size now, updated after every mbsync attempt and snapshot (shows the progress of a long first download) |
| `mail_backup_progress_timestamp_seconds` | last progress tick of a running sync (every `PROGRESS_INTERVAL`) |
| `mail_backup_run_started_timestamp_seconds`, `mail_backup_run_finished_timestamp_seconds` | start and end of the last run; started > finished = a run is going |
| `mail_backup_unfetchable_messages`, `mail_backup_parked_folders` | refused letters, parked folders |
| `mail_backup_folder_server_messages{folder}` | letters of the folder on the server at the start of the last run |
| `mail_backup_folder_letters{folder}`, `…_folder_refused{folder}`, `…_folder_parked{folder}` | per folder: letters here now, refused letters listed, 1 if parked |
| `mail_backup_copy_last_success_timestamp_seconds`, `…_copy_last_failure_…` | off-host copy |

A Grafana dashboard for these metrics: `grafana/mail-backup.json` (Dashboards → New → Import; pick your Prometheus
data source). It shows the last run, letters, sizes, refused letters, parked folders, the off-host copy, and a
table of folders: on the server, here, not downloaded yet, refused.

Useful alerts:
- no success for 26 hours: `time() - mail_backup_last_success_timestamp_seconds > 26*3600`;
- the last run failed: failure newer than success;
- new refused letters: `mail_backup_unfetchable_messages` grew over a day;
- a new parked folder: `mail_backup_parked_folders` grew over a day.

## Yandex 360 notes

Step by step, with screenshots (in Russian): [docs/yandex-360.md](docs/yandex-360.md): paid plan, IMAP for the
organization and the mailbox, app password.

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
| `Dockerfile` | Alpine with isync, restic, supercronic, rsync, curl |
| `compose.yml`, `.env.example` | how to run it |
| `grafana/mail-backup.json` | Grafana dashboard for the metrics |
| `tests/test.sh` | tests against a stub mbsync, no mailbox needed: `sh tests/test.sh` (Docker; the first build downloads Alpine packages) |
| `CLAUDE.md` | rules for changing the code, and what we learned about mbsync and Yandex 360 |
| `README.ru.md` | this README in Russian |
| `docs/yandex-360.md` | setting up a Yandex 360 mailbox for IMAP, with screenshots (in Russian) |
| `CHANGELOG.md` | changes by release |

Inside `DATA_DIR`:

| | |
|---|---|
| `maildir/` | the Maildir |
| `restic/` | the repository |
| `state/` | refused letters, parked folders, letters per folder on the server; included in every snapshot |
| `.journals/` | the last mbsync journal folded by a checkpoint, per folder; not in the snapshots |
| `maildir-gone/` | put folders here by hand that were deleted on the server; they stay in every snapshot |
| `.mbsync-last.log` | full mbsync output of the last run |

## License

MIT
