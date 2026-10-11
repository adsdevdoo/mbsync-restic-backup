# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions follow
[Semantic Versioning](https://semver.org/spec/v2.0.0.html): a new major version means a change you have to act
on (settings, data layout, metric names).

## [Unreleased]

### Changed
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

[Unreleased]: https://github.com/adsdevdoo/mbsync-restic-backup/compare/v1.0.1...HEAD
[1.0.1]: https://github.com/adsdevdoo/mbsync-restic-backup/compare/v1.0.0...v1.0.1
[1.0.0]: https://github.com/adsdevdoo/mbsync-restic-backup/releases/tag/v1.0.0
