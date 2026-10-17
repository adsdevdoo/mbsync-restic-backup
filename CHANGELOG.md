# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions follow
[Semantic Versioning](https://semver.org/spec/v2.0.0.html): a new major version means a change you have to act
on (settings, data layout, metric names).

## [Unreleased]

## [1.1.1] - 2026-10-17

### Changed
- `compose.yml`: `mem_limit` 4g instead of 1g. The prune of a mailbox of about a million letters (a 15 GB
  repository) needed more than 1 GB and was killed.

### Fixed
- A restic killed in the middle (out of memory during the retention prune, a container stop) left an exclusive lock
  behind, and every later run failed with "repository is already locked". Each run now removes stale locks
  (`restic unlock`, never `--remove-all`) before its snapshot.
- README, off-host copy: the rrsync line of the target lacked `-munge`. Without it, on rsync older than 3.5 a
  compromised backup host can upload a symbolic link, write through it outside the directory (e.g. the user's
  `~/.ssh`) and get a shell on the target. Now `-wo -no-del -no-overwrite -munge`, or `-wo -no-del -munge` with
  rsync older than 3.3; add `-munge` to an existing line.
- README, off-host copy: the example copy user is no longer `backup` (a system user on Debian and Ubuntu); rrsync is
  a package of its own on Alpine and needs python3, which a minimal Debian or Ubuntu may lack.

## [1.1.0] - 2026-10-11

### Added
- Checkpoints for big folders. A folder too big for one session never got its mbsync state written, and every
  attempt asked again, from the lowest UID, for all the letters refused before; after a few attempts nothing new
  came at all. Now, after an attempt cut off in a folder, its journal is folded into the state (stored letters and
  their flags kept) and `MaxPulledUid` moves up to where the attempt got to; the next attempt goes on from there.
  The folded journal is kept in `DATA_DIR/.journals/`.
- Per-folder counts: letters on the server (IMAP `STATUS` at the start of each run, one connection), here,
  refused, parked: `mail_backup_folder_*{folder}` metrics, `state/folders.tsv`, and a "Folders" table with totals on
  the dashboard. The image now has curl.

### Changed
- Parking is a fallback now: only a cut-off folder no checkpoint could be written for gets parked.
- `README.ru.md` has all the badges of `README.md`.

## [1.0.1] - 2026-10-11

### Added
- README in Russian (`README.ru.md`), a language switch in both, a Grafana dashboard screenshot.

### Changed
- `docs/yandex-360.md` links to the Russian README sections; small fixes in the README texts.

### Fixed
- The dashboard showed "idle" during a loop of runs: the next run started in the same second the last one ended,
  so its start was not later than that end. Run start and end are now written with microseconds.

## [1.0.0] - 2026-10-11

First release.

### Added
- One-way IMAP sync with mbsync into a Maildir, restic snapshots with retention, weekly `restic check`.
- Restart of mbsync after a dropped session, up to `MBSYNC_ATTEMPTS` per run.
- Refused letters: listed in `state/unfetchable.tsv`, collected later with `backup.sh retry` and
  `backup.sh rewind-all`; `REFUSED_PATTERN` and `REFUSED_MAX`.
- Parking of folders the server keeps refusing letters in (`PARK_FAILURES`, `PARK_RATIO`, `PARK_AFTER`,
  `NEVER_PARK`).
- Parallel sessions (`PARALLEL`).
- Optional off-host copy of the repository with rsync over SSH (`COPY_TARGET`).
- Metrics for the node_exporter textfile collector, live while syncing (`PROGRESS_INTERVAL`); Grafana dashboard
  in `grafana/`.
- Offline tests (`tests/test.sh`), images for amd64 and arm64 on ghcr.io and Docker Hub.
- Setup guide for Yandex 360 (`docs/yandex-360.md`, in Russian).

[Unreleased]: https://github.com/adsdevdoo/mbsync-restic-backup/compare/v1.1.1...HEAD
[1.1.1]: https://github.com/adsdevdoo/mbsync-restic-backup/compare/v1.1.0...v1.1.1
[1.1.0]: https://github.com/adsdevdoo/mbsync-restic-backup/compare/v1.0.1...v1.1.0
[1.0.1]: https://github.com/adsdevdoo/mbsync-restic-backup/compare/v1.0.0...v1.0.1
[1.0.0]: https://github.com/adsdevdoo/mbsync-restic-backup/releases/tag/v1.0.0
