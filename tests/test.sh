#!/bin/sh
# Offline tests: builds the image and runs backup.sh against a stub mbsync that prints mbsync -V output for a
# scenario. No network, no real mailbox. Needs Docker. Usage: sh tests/test.sh
# Each scenario prints its result; the script ends with "FAILED: N" (0 = all good) and exits non-zero on failures.
set -u
cd "$(dirname "$0")/.." || exit 1
IMG=mbsync-restic-backup:test
docker build -q -t "$IMG" . >/dev/null || { echo "build failed"; exit 1; }

d=$(mktemp -d)
mkdir -p "$d/data" "$d/secrets" "$d/metrics" "$d/bin"
echo fake >"$d/secrets/imap_password"
head -c 32 /dev/urandom | base64 >"$d/secrets/restic_password"
E="-e IMAP_HOST=imap.example -e IMAP_USER=u@example"
V="$E -v $d/data:/data -v $d/secrets:/run/secrets:ro -v $d/metrics:/metrics -v $d/bin/mbsync:/usr/local/bin/mbsync:ro"
FAILED=0

# The stub: argv is "-V -c <config> mail"; the scenario is in /data/scenario.
cat >"$d/bin/mbsync" <<'EOF'
#!/bin/bash
cfg="$3"
s=$(cat /data/scenario)
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
esac
EOF
chmod +x "$d/bin/mbsync"

# check <name> <expected rc> <regex the output must match> <scenario> [backup.sh args] [extra docker args]
check() {
  echo "$4" >"$d/data/scenario"
  out=$(docker run --rm --network none $V ${6:-} "$IMG" sh -c "backup.sh ${5:-}; echo rc=\$?" 2>&1)
  rc=$(echo "$out" | sed -n 's/^rc=//p')
  if [ "$rc" = "$2" ] && echo "$out" | grep -qE "$3"; then
    echo "ok   $1"
  else
    echo "FAIL $1 (rc=$rc, expected $2, wanted /$3/)"; echo "$out" | grep -vE 'UNAVAILABLE|SERVERBUG' | tail -5
    FAILED=$((FAILED + 1))
  fi
}

docker run --rm --network none $V "$IMG" backup.sh init >/dev/null || { echo "init failed"; FAILED=$((FAILED + 1)); }
check "refused letters do not fail the run"   0 'all folders done; 3 refused'         refused ""
check "retry rewinds and records recovery"    0 'STATE MaxPulledUid 612.*|came through' retry   retry
check "dropped session, second attempt ok"    0 'attempt 2 of 3'                      byeok   ""
check "real error fails the run"              1 'mbsync failed'                       realerr ""
check "killed mbsync fails the run"           1 'mbsync failed'                       killed  ""
check "stalled folder gets parked"            0 'parked Bad Box'                      stall   ""
check "INBOX is never parked"                 1 'INBOX is never parked'               inbox   ""
check "rewind-all runs"                       0 'MaxPulledUid set to 0'               refused rewind-all
check "unknown command"                       2 'unknown command'                     refused bogus
check "REFUSED_PATTERN mismatch fails"        1 'mbsync failed'                       refused "" "-e REFUSED_PATTERN=\\[UNAVAILABLE\\]"
check "REFUSED_MAX exceeded fails"            1 'more than REFUSED_MAX'               refused "" "-e REFUSED_MAX=1"
check "COPY_TARGET without colon"             1 'COPY_TARGET must be'                 refused "" "-e COPY_TARGET=nocolon"
check "bad number setting"                    1 'must be a number'                    refused "" "-e PARK_RATIO=08"

# The scheduler starts as PID 1 and stays up.
docker run -d --name mrb-sched-test $E -e SCHEDULE='*/5 * * * *' "$IMG" >/dev/null
sleep 4
if docker ps --filter name=mrb-sched-test --format '{{.Status}}' | grep -q '^Up'; then echo "ok   scheduler stays up"; else echo "FAIL scheduler"; FAILED=$((FAILED + 1)); fi
docker rm -f mrb-sched-test >/dev/null

docker run --rm -v "$d:/d" alpine:3.22 rm -rf /d/data /d/metrics /d/secrets /d/bin
rmdir "$d"
echo "FAILED: $FAILED"
[ "$FAILED" -eq 0 ]
