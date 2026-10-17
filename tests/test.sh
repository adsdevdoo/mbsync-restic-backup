#!/bin/sh
# Tests: builds the image and runs backup.sh against a stub mbsync that prints mbsync -V output for a scenario.
# The scenarios run without network and without a real mailbox; the first `docker build` needs the internet for
# the Alpine packages. Needs Docker. Usage: sh tests/test.sh
# Each scenario prints its result; the script ends with "FAILED: N" (0 = all good) and exits non-zero on failures.
# Every scenario starts from an empty Maildir and state (the restic repository stays), except where noted.
set -u
cd "$(dirname "$0")/.." || exit 1
IMG=mbsync-restic-backup:test
docker build -q -t "$IMG" . >/dev/null || { echo "build failed"; exit 1; }

d=$(mktemp -d)
cleanup() {
    docker rm -f mrb-sched-test >/dev/null 2>&1
    docker run --rm -v "$d:/d" alpine:3.22 rm -rf /d/data /d/metrics /d/secrets /d/bin
    rmdir "$d" 2>/dev/null
}
trap cleanup EXIT
trap 'exit 130' INT TERM
mkdir -p "$d/data" "$d/secrets" "$d/metrics" "$d/bin"
echo fake >"$d/secrets/imap_password"
head -c 32 /dev/urandom | base64 >"$d/secrets/restic_password"
E="-e IMAP_HOST=imap.example -e IMAP_USER=u@example"
V="$E -v $d/data:/data -v $d/secrets:/run/secrets:ro -v $d/metrics:/metrics -v $d/bin/mbsync:/usr/local/bin/mbsync:ro -v $d/bin/curl:/usr/local/bin/curl:ro"
FAILED=0

# The stub: argv is "-V -c <config> mail" for a sync and "-c <config> -l mail" for listing the folders; the
# scenario is in /data/scenario.
cat >"$d/bin/mbsync" <<'EOF'
#!/bin/bash
s=$(cat /data/scenario)
if [ "$3" = "-l" ]; then
  case $s in
    parallel) printf 'A\nB\nC\nD\n'; exit 0;;
    folders) printf 'INBOX\nжурналы\narchive/x\na&b\n'; exit 0;;
    *) exit 1;;
  esac
fi
cfg="$3"
pat=$(grep '^Patterns' "$cfg")
box() { mkdir -p "/data/maildir/$1/cur" "/data/maildir/$1/new"; echo "Opening far side box $1..."; echo "Synchronizing..."; }
fail() {
  echo "Warning from IMAP server: [UNAVAILABLE] UID FETCH message 5 uid $1: failure due to backend error" >&2
  echo "IMAP command 'UID FETCH $1 (INTERNALDATE BODY.PEEK[])' returned an error: [UNAVAILABLE] UID FETCH Completed. sc=x" >&2
}
other() { echo "IMAP command 'UID FETCH $1 (INTERNALDATE BODY.PEEK[])' returned an error: NO [SERVERBUG] boom" >&2; }
sum() { echo "Channels: 1    Boxes: 2"; }
state() { printf 'FarUidValidity 1\nNearUidValidity 2\nMaxPulledUid 5000\nMaxPushedUid 9\n\n612 590 S\n' >/data/maildir/INBOX/.mbsyncstate; }
case $s in
  refused) box INBOX; state; fail 613; fail 800; box Other; other 9; sum; exit 1;;
  slow) box INBOX; sleep 4; sum; exit 0;;
  rewound) echo "STATE $(grep MaxPulledUid /data/maildir/INBOX/.mbsyncstate)"; box INBOX; sum; exit 0;;
  retry)
    echo "STATE $(grep MaxPulledUid /data/maildir/INBOX/.mbsyncstate)"
    box INBOX; fail 613; echo "800 700 S" >>/data/maildir/INBOX/.mbsyncstate; box Other; sum; exit 1;;
  byeok)
    box INBOX
    if [ ! -f /tmp/second ]; then touch /tmp/second; echo "IMAP error: unexpected BYE response: session lifetime exceeded" >&2; sum; exit 1; fi
    box Other; sum; exit 0;;
  realerr) box INBOX; fail 613; echo "Error: channel mail: near side box INBOX cannot be opened" >&2; sum; exit 1;;
  killed) box INBOX; fail 613; exit 137;;
  stall)
    box INBOX
    if [[ "$pat" == *'!"Bad Box"'* ]]; then box Zeta; sum; exit 0; fi
    box "Bad Box"; for u in $(seq 1000 1349); do fail $u; done
    echo "IMAP error: unexpected BYE response: problems with connection" >&2; sum; exit 1;;
  inbox) box INBOX; for u in $(seq 1 400); do fail $u; done; echo "IMAP error: unexpected BYE response: x" >&2; sum; exit 1;;
  checkpoint)
    # Attempt 1: a journal as mbsync leaves it when cut off: 10 stored (flags S), 11 refused, 12 stored (then RS),
    # 13 queued but not reached, and a last line cut off mid-write. Attempt 2 shows the state it got.
    box INBOX
    if [ ! -f /tmp/second ]; then
      touch /tmp/second
      printf '5\n| 111 222\n+ 10 0\n+ 11 0\n+ 12 0\n+ 13 0\n%% 10 0 16\n> 10 0 1\n- 11 0\n%% 12 0 0\n> 12 0 2\n* 12 2 24\n> 13 0 3' \
        >/data/maildir/INBOX/.mbsyncstate.journal
      : >/data/maildir/INBOX/.mbsyncstate.new
      fail 11; echo "IMAP error: unexpected BYE response: session lifetime exceeded" >&2; sum; exit 1
    fi
    echo "STATE $(tr '\n' ' ' </data/maildir/INBOX/.mbsyncstate)"; sum; exit 0;;
  checkpoint2)
    # Over an existing state (an extra header line, MaxPulledUid 5, one pair): 10 stored, 11 failed with an answer
    # REFUSED_PATTERN does not match, 13 stored before 12 (answers out of order), 12 still in flight when cut off.
    box INBOX
    if [ ! -f /tmp/second ]; then
      touch /tmp/second
      printf 'FarUidValidity 111\nNearUidValidity 222\nMaxPulledUid 5\nMaxPushedUid 1\nMaxExpiredFarUid 0\n\n3 1 S\n' \
        >/data/maildir/INBOX/.mbsyncstate
      printf '5\n+ 10 0\n+ 11 0\n+ 12 0\n+ 13 0\n> 10 0 2\n- 11 0\n> 13 0 3\n' >/data/maildir/INBOX/.mbsyncstate.journal
      : >/data/maildir/INBOX/.mbsyncstate.new
      echo "IMAP error: unexpected BYE response: session lifetime exceeded" >&2; sum; exit 1
    fi
    echo "STATE $(tr '\n' ' ' </data/maildir/INBOX/.mbsyncstate)"; echo "LISTED $(tr '\t\n' ' ;' </data/state/unfetchable.tsv)"; sum; exit 0;;
  folders) box INBOX; box журналы; box archive/x; box 'a&b'; touch '/data/maildir/журналы/cur/1:2,S'; sum; exit 0;;
  parallel)
    # Sync the folders named in Patterns; B has refused letters; the session with C drops once.
    rc=0
    for f in $(echo "$pat" | grep -oE '"[A-Z]"' | tr -d '"'); do
      box "$f"
      [ "$f" = B ] && { fail 21; fail 22; rc=1; }
      if [ "$f" = C ] && [ ! -f /data/c-dropped ]; then
        touch /data/c-dropped; echo "IMAP error: unexpected BYE response: session lifetime exceeded" >&2; sum; exit 1
      fi
    done
    echo "SESSION $pat"; sum; exit $rc;;
esac
EOF
chmod +x "$d/bin/mbsync"

# The curl stub: LIST "" "" gets the delimiter |; a -K config gets a STATUS answer (7 letters) per request, the
# requests as sent are kept in /data/curl-requests.
cat >"$d/bin/curl" <<'EOF'
#!/bin/bash
cfg=""; prev=""
for a in "$@"; do [ "$prev" = -K ] && cfg="$a"; prev="$a"; done
if [ -n "$cfg" ]; then
  grep '^request = ' "$cfg" | sed -e 's/^request = "//' -e 's/"$//' -e 's/\\\(.\)/\1/g' | tee -a /data/curl-requests \
    | while IFS= read -r r; do printf '* STATUS %s (MESSAGES 7)\r\n' "$(echo "$r" | sed 's/^STATUS \(.*\) (MESSAGES)$/\1/')"; done
  exit 0
fi
case "$*" in *'LIST "" ""'*) printf '* LIST (\\Noselect) "|" ""\r\n';; esac
EOF
chmod +x "$d/bin/curl"

# reset : empty Maildir, state and log; the restic repository stays.
reset() {
  docker run --rm -v "$d/data:/data" alpine:3.22 rm -rf /data/maildir /data/state /data/.mbsync-last.log
}

# check <name> <expected rc> <regexes, ";;"-separated, all must match> <scenario> [backup.sh args]
#       [extra docker args] [keep: do not reset before]
check() {
  [ "${7:-}" = keep ] || reset
  echo "$4" >"$d/data/scenario"
  out=$(docker run --rm --network none $V ${6:-} "$IMG" sh -c "backup.sh ${5:-}; echo rc=\$?" 2>&1)
  rc=$(echo "$out" | sed -n 's/^rc=//p')
  ok=yes
  [ "$rc" = "$2" ] || ok=no
  rest="$3;;"
  while [ -n "$rest" ]; do
    re="${rest%%;;*}"; rest="${rest#*;;}"
    [ -z "$re" ] || echo "$out" | grep -qE "$re" || ok=no
  done
  if [ "$ok" = yes ]; then
    echo "ok   $1"
  else
    echo "FAIL $1 (rc=$rc, expected $2, wanted /$3/)"; echo "$out" | grep -vE 'UNAVAILABLE|SERVERBUG' | tail -5
    FAILED=$((FAILED + 1))
  fi
}

docker run --rm --network none $V "$IMG" backup.sh init >/dev/null || { echo "init failed"; FAILED=$((FAILED + 1)); }
check "refused letters do not fail the run"   0 'all folders done; 3 refused'         refused ""
# Needs the list and the INBOX state the previous scenario left.
check "retry rewinds and records recovery"    0 'STATE MaxPulledUid 612;;: 1 letters .* came through' retry retry "" keep
check "dropped session, second attempt ok"    0 'attempt 2 of 3'                      byeok   ""
check "real error fails the run"              1 'mbsync failed'                       realerr ""
if grep -q '^mail_backup_letters [0-9]' "$d/metrics/mail_backup_size.prom" 2>/dev/null; then
  echo "ok   sizes written after a failed run"; else echo "FAIL sizes written after a failed run"; FAILED=$((FAILED + 1)); fi
check "killed mbsync fails the run"           1 'mbsync failed'                       killed  ""
# A restic killed in the middle leaves its lock behind (same container: a dead process on this host = stale); the next
# run removes it before the snapshot and goes through.
reset; echo refused >"$d/data/scenario"
out=$(docker run --rm --network none $V "$IMG" sh -c '
  head -c 50000000 /dev/urandom >/data/big; restic backup --quiet --limit-upload 100 /data/big & p=$!
  for i in $(seq 1 30); do [ "$(restic list locks --no-lock | wc -l)" -gt 0 ] && break; sleep 1; done; kill -9 $p; wait $p 2>/dev/null
  rm -f /data/big; echo "locks before: $(restic list locks --no-lock | wc -l)"; backup.sh; echo rc=$?' 2>&1)
if echo "$out" | grep -q 'locks before: [1-9]' && echo "$out" | grep -q 'left by a killed restic' && echo "$out" | grep -q '^rc=0$'; then
  echo "ok   a stale restic lock is removed before the snapshot"
else
  echo "FAIL a stale restic lock is removed before the snapshot"; echo "$out" | grep -vE 'UNAVAILABLE|SERVERBUG' | tail -5; FAILED=$((FAILED + 1))
fi
rm -f "$d/metrics/mail_backup_progress.prom"
# Also proves the run does not hang waiting for the ticker.
check "progress ticker during a slow sync"    0 'done:'                               slow    "" "-e PROGRESS_INTERVAL=1"
if grep -q '^mail_backup_progress_timestamp_seconds [0-9]' "$d/metrics/mail_backup_progress.prom" 2>/dev/null \
  && grep -qE '^mail_backup_run_started_timestamp_seconds [0-9]+\.[0-9]{6}$' "$d/metrics/mail_backup_run.prom" 2>/dev/null \
  && grep -qE '^mail_backup_run_finished_timestamp_seconds [0-9]+\.[0-9]{6}$' "$d/metrics/mail_backup_run_end.prom" 2>/dev/null; then
  echo "ok   progress and run start written"; else echo "FAIL progress and run start written"; FAILED=$((FAILED + 1)); fi
# A loop of runs: the next run's start must be later than the last run's end, even within the same second.
reset; echo refused >"$d/data/scenario"
if docker run --rm --network none $V "$IMG" sh -c '
  backup.sh >/dev/null 2>&1; f=$(sed -n "s/^mail_backup_run_finished_timestamp_seconds //p" /metrics/mail_backup_run_end.prom)
  backup.sh >/dev/null 2>&1; s=$(sed -n "s/^mail_backup_run_started_timestamp_seconds //p" /metrics/mail_backup_run.prom)
  awk -v s="$s" -v f="$f" "BEGIN { exit !(f != \"\" && s + 0 > f + 0) }"'; then
  echo "ok   next run starts after the last one ended"; else echo "FAIL next run starts after the last one ended"; FAILED=$((FAILED + 1)); fi
check "stalled folder gets parked"            0 'parked Bad Box'                      stall   ""
check "PARK_AFTER=1 parks at the first stall" 0 'parked Bad Box: attempt stalled;;attempt 2 of 3' stall "" "-e PARK_AFTER=1"
check "PARK_AFTER must be 1 or 2"             1 'PARK_AFTER must be 1 or 2'           refused "" "-e PARK_AFTER=3"
check "INBOX is never parked"                 1 'INBOX is never parked'               inbox   ""
check "cut-off folder gets a checkpoint"      0 'checkpoint of INBOX: MaxPulledUid 0 -> 12, 2 letters recorded;;STATE FarUidValidity 111 NearUidValidity 222 MaxPulledUid 12 MaxPushedUid 2  10 1 S 12 2 RS $;;attempt 2 of 3' checkpoint ""
# Inside a container: what the script writes under /data is root's only.
if docker run --rm -v "$d/data:/data" alpine:3.22 sh -c '[ -f /data/.journals/INBOX.journal ] && [ ! -e /data/maildir/INBOX/.mbsyncstate.journal ] && [ ! -e /data/maildir/INBOX/.mbsyncstate.new ]'; then
  echo "ok   checkpoint sets the journal aside"; else echo "FAIL checkpoint sets the journal aside"; FAILED=$((FAILED + 1)); fi
check "checkpoint over a state, out of order" 0 'checkpoint of INBOX: MaxPulledUid 5 -> 11, 3 letters recorded;;STATE FarUidValidity 111 NearUidValidity 222 MaxPulledUid 11 MaxPushedUid 3 MaxExpiredFarUid 0  3 1 S 10 2  13 3  $;;LISTED INBOX 11 ' checkpoint2 ""
check "refused letters again (for rewind-all)" 0 'all folders done; 3 refused'        refused ""
# Needs the INBOX state the previous scenario left (the Other folder has none).
check "rewind-all rewinds every state"        0 'MaxPulledUid set to 0 in 1 folders;;STATE MaxPulledUid 0' rewound rewind-all "" keep
check "unknown command"                       2 'unknown command'                     refused bogus
check "two parallel sessions, one retried"    0 '4 folders on the server, 2 sessions;;\[1\] SESSION Patterns "A" "C";;\[2\] SESSION Patterns "B" "D";;1 of 2 sessions;;all folders done; 2 refused' parallel "" "-e PARALLEL=2"
check "listing fails: one session"            0 'could not list the folders; one session' refused "" "-e PARALLEL=2"
check "PARALLEL must be 1-8"                  1 'PARALLEL must be 1-8'                refused "" "-e PARALLEL=9"
docker run --rm -v "$d/data:/data" alpine:3.22 rm -f /data/curl-requests
check "per-folder counts"                     0 'all folders done'                    folders ""
m="$d/metrics/mail_backup_folders.prom"
# The requests file is root's only (inside a container).
req=$(docker run --rm -v "$d/data:/data" alpine:3.22 cat /data/curl-requests 2>/dev/null)
if echo "$req" | grep -qxF 'STATUS "&BDYEQwRABD0EMAQ7BEs-" (MESSAGES)' \
  && echo "$req" | grep -qxF 'STATUS "archive|x" (MESSAGES)' \
  && echo "$req" | grep -qxF 'STATUS "a&-b" (MESSAGES)' \
  && grep -qxF 'mail_backup_folder_server_messages{folder="журналы"} 7' "$m" 2>/dev/null \
  && grep -qxF 'mail_backup_folder_letters{folder="журналы"} 1' "$m" \
  && grep -qxF 'mail_backup_folder_server_messages{folder="archive/x"} 7' "$m" \
  && grep -qxF 'mail_backup_folder_server_messages{folder="a&b"} 7' "$m" \
  && grep -qxF 'mail_backup_folder_parked{folder="INBOX"} 0' "$m"; then
  echo "ok   folder names to the server, counts in the metrics"
else
  echo "FAIL folder names to the server, counts in the metrics"; echo "$req"; head -20 "$m"; FAILED=$((FAILED + 1))
fi
check "REFUSED_PATTERN mismatch fails"        1 'mbsync failed'                       refused "" "-e REFUSED_PATTERN=\\[UNAVAILABLE\\]"
check "REFUSED_MAX exceeded fails"            1 'more than REFUSED_MAX'               refused "" "-e REFUSED_MAX=1"
check "COPY_TARGET without colon"             1 'COPY_TARGET must be'                 refused "" "-e COPY_TARGET=nocolon"
check "bad number setting"                    1 'must be a number'                    refused "" "-e PARK_RATIO=08"

# The scheduler starts as PID 1 and stays up.
docker rm -f mrb-sched-test >/dev/null 2>&1
docker run -d --name mrb-sched-test $E -e SCHEDULE='*/5 * * * *' "$IMG" >/dev/null
sleep 4
if docker ps --filter name=mrb-sched-test --format '{{.Status}}' | grep -q '^Up'; then echo "ok   scheduler stays up"; else echo "FAIL scheduler"; FAILED=$((FAILED + 1)); fi

echo "FAILED: $FAILED"
[ "$FAILED" -eq 0 ]
