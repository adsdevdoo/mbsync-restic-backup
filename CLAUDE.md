# Working on mbsync-restic-backup

Rules for anyone changing this repository, Claude included. This is a public repository: never commit anything
about a particular deployment (hosts, IPs, user names, mailbox addresses, paths of a real server, keys).

## Changes, commits, pushes

- No commit, push or tag without an explicit OK from the maintainer ("commit", "push"). Changes stay in the
  working tree until then. Commits already made are not rolled back; later work goes on top of them.
- Never rewrite pushed history (no amend, rebase or force-push of pushed commits): deployments build this
  repository at a pinned commit, which must stay reachable.
- Commit messages in English, in the style of the history: a short subject line and a body that says why. No
  `Co-Authored-By` or any other attribution trailer.
- One fix or feature per commit, with its README changes in the same commit.
- Edit files by hand in an editor (Claude: the Edit/Write tools), one place at a time. Don't patch files with sed,
  python or heredocs: escaping breaks (`\[` in a regex, quotes in awk) and the change isn't visible as a diff.
- Long commands (image builds, the test run) go to the background; don't block the session on them.

## Review before pushing

Every change gets reviewed before it is pushed, and the review is repeated after each round of fixes until a round
finds nothing. Each finding gets a severity, a concrete failure scenario and a decision: fixed, accepted (with the
reason) or left for later. Check claims against facts (logs, the mbsync state files, a test run) before fixing a
"could happen": hypotheses are not bugs.

## Tests

- `sh tests/test.sh` builds the image and runs backup.sh against a stub mbsync. The scenarios run without network
  (the first build needs it for the Alpine packages). All scenarios must pass; the script ends with `FAILED: 0`.
  Each scenario starts from an empty Maildir and state unless it says it builds on the previous one.
- New behavior gets a new scenario in the stub. A fix for a bug gets a scenario that failed before the fix.
- When a change touches how the image starts (Dockerfile, entrypoint), run the image's own command, not just
  `docker run … backup.sh`: a broken entrypoint once slipped through tests that only ran the script.
- Don't test against a real mailbox casually: providers rate-limit and ban. One careful run, read the log, stop.

## Code

- Bash with `set -euo pipefail` and `umask 077`. Each function starts with a comment `name <args> : what it does`;
  comments explain why, not what.
- `set -e` is off inside a function called as `f || …` (and in everything it calls). Such functions check each
  step explicitly (`|| return 1`) and replace files only after every step succeeded.
- Regexes for gawk go through `ENVIRON`, not `-v` (which eats backslashes). Arithmetic on settings only after
  `check_settings` validated them as numbers without leading zeros.
- Versions in the image: Alpine 3.22, isync 1.5.1, restic 0.18, supercronic, GNU grep and gawk (the busybox ones
  lack `--line-buffered` and some awk syntax).
- Never print secrets: not in logs, not in examples, not in commit messages.

## What we learned about mbsync (isync 1.5.1)

- mbsync only loads server UIDs above `MaxPulledUid` of a folder's state plus the UIDs it has records for. A letter
  whose fetch failed gets no record and is never asked for again; lowering `MaxPulledUid` (`retry`, `rewind-all`)
  makes it walk those UIDs again without downloading anything twice.
- The state of a folder is written only when the folder is done; until then progress lives in
  `.mbsyncstate.journal`, replayed on start. Never delete a journal: the records of downloaded letters go with it
  and mbsync downloads them again as duplicates. Don't edit a state that has a journal.
- Until a folder is done, every attempt retries its failed letters from the lowest UID. A block the server keeps
  refusing longer than a session lasts stalls the folder forever: that is what parking is for.
- `-V` prints `Opening far side box <name>...` before each folder; errors are attributed to the last such line.
- With `CopyArrivalDate yes` file mtimes are the letters' dates; use ctime to find files written by a run.
- As PID 1 supercronic re-executes itself by `argv[0]`: start it by absolute path.

## Yandex 360

- IMAP only on a paid plan; an organization admin can also switch it off for everyone (`enable_imap`). App
  password, not the account password.
- Sessions end after about 30 minutes (`BYE … session lifetime exceeded`); the first download of a big mailbox
  takes many runs.
- `PipelineDepth` above 1 barely helped against refusals: Yandex answered one connection's commands in order.
  Parallel sessions (`PARALLEL`) give it several queues instead. Yandex doesn't publish its limit on simultaneous
  IMAP connections.
- Refused letters: `[UNAVAILABLE] … backend error`. In October 2026 Yandex lost three data centers; some letters
  came back on a later try (363 of 366 in one retry of an INBOX), whole stretches of archive folders did not.
