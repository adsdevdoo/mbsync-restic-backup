#!/usr/bin/env bash
#
# mbsync-restic-backup: daily backup of one IMAP mailbox.
#   1. mbsync pulls every folder into the Maildir /data/maildir: one way, incremental, nothing is ever written to
#      the server and nothing is deleted locally.
#   2. restic takes a snapshot of the Maildir into /data/restic and applies retention.
#   3. Optionally the repository files are copied to another host with rsync over SSH.
# The Maildir alone is not a backup: a corrupted or wiped copy would be synced as is. The snapshots are.
#
# Usage (inside the container):
#   backup.sh             a run (the scheduler calls this)
#   backup.sh init        create the restic repository, once
#   backup.sh retry       ask the server again for the letters it refused, then a run
#   backup.sh rewind-all  ask again for every letter mbsync has no record of, in every folder, then a run
#
# Settings come from the environment, see .env.example. Notes on the less obvious parts:
#
# Dropped sessions. Some servers close an IMAP session after a while (Yandex 360: ~30 minutes, "BYE … session
# lifetime exceeded"). After a dropped connection mbsync is started again, up to MBSYNC_ATTEMPTS times per run; it
# continues where it stopped.
#
# Parallel sessions. With PARALLEL > 1 the folders the server lists (parked ones left out) are dealt round-robin into
# that many groups, each synced by its own mbsync at the same time. A folder belongs to one group only, so no two
# processes touch the same folder state. A server answering one connection's commands in order (refusals ~0.8 s
# each on Yandex) gets that many queues instead of one.
#
# Unfetchable letters. A server may refuse single letters (Yandex 360: "[UNAVAILABLE] … backend error"). mbsync
# skips them and exits 1. A run whose only errors are refused letters is a success; the letters are listed in
# UNFETCHABLE_LIST. mbsync never asks for them again by itself: it only loads UIDs above MaxPulledUid of the folder
# state, and a refused letter gets no record there. `retry` lowers MaxPulledUid of each listed folder below its
# smallest listed UID, so mbsync walks the folder again, skips what it has and asks for the rest. A letter counts
# as come through once the folder state has a record for it. Not done in the nightly run: a block of letters the
# server keeps refusing would eat every nightly session.
#
# Parked folders. Until a folder is done, every attempt asks again for its refused letters from the lowest UID. If
# the server refuses a block longer than a session lasts, the folder never gets done. A folder is parked (left out
# of mbsync) when PARK_AFTER attempts in a row (2 by default, or 1) were cut off in it with at least PARK_FAILURES
# refused letters and more than PARK_RATIO times as many as letters stored from it in that attempt. NEVER_PARK
# folders are not parked: the run fails instead. The folder keeps its journal; remove its line from PARKED_LIST to
# take it back.
#
set -euo pipefail
# The Maildir is plain text mail: readable by root only.
umask 077

# --- settings (environment) ---
IMAP_HOST="${IMAP_HOST:?IMAP_HOST is not set}"
IMAP_USER="${IMAP_USER:?IMAP_USER is not set}"
IMAP_PORT="${IMAP_PORT:-993}"
IMAP_PASSWORD_FILE="${IMAP_PASSWORD_FILE:-/run/secrets/imap_password}"
PIPELINE_DEPTH="${PIPELINE_DEPTH:-8}"
MBSYNC_ATTEMPTS="${MBSYNC_ATTEMPTS:-3}"
KEEP_DAILY="${KEEP_DAILY:-30}"
KEEP_WEEKLY="${KEEP_WEEKLY:-8}"
KEEP_MONTHLY="${KEEP_MONTHLY:-24}"
# restic check on this weekday (date +%u, 1 = Monday; empty = never), reading this share of the data.
CHECK_WEEKDAY="${CHECK_WEEKDAY-7}"
CHECK_READ_SUBSET="${CHECK_READ_SUBSET:-10%}"
SNAPSHOT_HOST="${SNAPSHOT_HOST:-mail-backup}"
SNAPSHOT_TAG="${SNAPSHOT_TAG:-mail}"
# Which server answers to a letter's body fetch count as a refused letter (extended regex on the error text; any
# by default; Yandex 360: \[UNAVAILABLE\]). Other answers are errors.
REFUSED_PATTERN="${REFUSED_PATTERN:-.}"
# More refused letters than this in one run make the run fail (0 = no limit): a server refusing every fetch (a
# download cap, a quota, an outage) must not look like a good run.
REFUSED_MAX="${REFUSED_MAX:-1000}"
# Extra mbsync patterns appended after *, e.g. !"[Gmail]/All Mail".
EXTRA_PATTERNS="${EXTRA_PATTERNS:-}"
PARK_FAILURES="${PARK_FAILURES:-300}"
PARK_RATIO="${PARK_RATIO:-2}"
# Stalled attempts in a row (in the same folder) before it is parked: 2 waits for a confirmation, 1 parks at once.
PARK_AFTER="${PARK_AFTER:-2}"
# mbsync sessions at the same time, each on its own share of the folders (1-8). Mind the server's limit on
# simultaneous IMAP connections.
PARALLEL="${PARALLEL:-1}"
# While mbsync runs, letters and sizes are written every this many seconds, with a progress timestamp (0 = only
# after each attempt).
PROGRESS_INTERVAL="${PROGRESS_INTERVAL:-60}"
# Space-separated, so a folder with a space in its name cannot be listed here; empty = none.
read -r -a NEVER_PARK <<<"${NEVER_PARK-INBOX Sent Drafts}"
# yes: wait for a running backup instead of skipping (for loops of manual runs).
WAIT_FOR_LOCK="${WAIT_FOR_LOCK:-no}"
# Off-host copy: empty COPY_TARGET = off.
COPY_TARGET="${COPY_TARGET:-}"
COPY_PORT="${COPY_PORT:-22}"
COPY_KEY="${COPY_KEY_FILE:-/run/secrets/copy_ssh_key}"
COPY_KNOWN_HOSTS="${COPY_KNOWN_HOSTS_FILE:-/run/secrets/copy_known_hosts}"
# RESTIC_REPOSITORY, RESTIC_PASSWORD_FILE and RESTIC_CACHE_DIR come from the image.

# --- paths ---
MAILDIR="/data/maildir"
# Local folders of mailboxes deleted on the server, moved here by hand; still in every snapshot.
GONE_DIR="/data/maildir-gone"
# Script state, in every snapshot.
STATE_DIR="/data/state"
# Refused letters: folder <TAB> uid <TAB> first seen <TAB> last seen <TAB> attempts.
UNFETCHABLE_LIST="$STATE_DIR/unfetchable.tsv"
# Letters that came through later: the same columns plus the time they did.
RECOVERED_LIST="$STATE_DIR/unfetchable-recovered.tsv"
# Parked folders, one per line.
PARKED_LIST="$STATE_DIR/parked.txt"
# The last stalled attempt per folder, waiting for a second one (PARK_AFTER=2): folder <TAB> refused letters.
STALL_FILE="$STATE_DIR/stall.tsv"
LOCK_FILE="/data/.backup.lock"
# Full mbsync -V output of the last run, all attempts and sessions (.g<i>: one session's attempt, while it runs).
MBSYNC_LOG="/data/.mbsync-last.log"
# mbsync configs, one per session: /tmp/mbsyncrc.<i> (.list: the one for listing the folders).
MBSYNC_RC_FILE="/tmp/mbsyncrc"
# Touched before each attempt: letters stored in it are the files changed after this.
ATTEMPT_MARK="/tmp/mbsync-attempt.mark"
# node_exporter textfile collector; nothing is written when it is not mounted.
METRICS_DIR="/metrics"

# --- what mbsync prints ---
# Progress lines of -V: kept out of the console and out of the error search (a folder name may hold "error").
MBSYNC_CHATTER='^(Reading configuration file|Channel |Opening (far|near) side (store|box)|Resolving |Connecting to |Connection is now encrypted|Logging in|Loading (far|near) side box|(far|near) side: [0-9]+ messages|Synchronizing)'
# A refused letter: the server's error answer to the body fetch of one UID, with a text REFUSED_PATTERN matches.
# Servers may add an untagged warning before it.
UNFETCHABLE_TAGGED="^IMAP command 'UID FETCH [0-9]+ \\(INTERNALDATE BODY\\.PEEK\\[\\]\\)' returned an error"
REFUSED_LINE="${UNFETCHABLE_TAGGED}: .*(${REFUSED_PATTERN})"
UNFETCHABLE_WARNING='^Warning from IMAP server: .*UID FETCH'
MBSYNC_ERROR='error|bye|fail|cannot|refused|timed out|reset|denied|invalid'
# Drops worth another attempt.
CONNECTION_DROP='unexpected BYE response|Connection reset by peer|Socket error|Connection timed out'


log() {
    echo "$(date -u '+%Y-%m-%dT%H:%M:%SZ') $*"
}


# write_prom <file> : stdin -> METRICS_DIR/<file>, atomically, readable by node_exporter.
write_prom() {
    local tmp

    if [[ ! -d "$METRICS_DIR" ]]; then
        cat >/dev/null
        return 0
    fi
    tmp="$(mktemp "$METRICS_DIR/.${1%.prom}.XXXXXX")"
    cat >"$tmp"
    chmod 644 "$tmp"
    mv "$tmp" "$METRICS_DIR/$1"
}


on_exit() {
    local rc=$?

    if (( rc != 0 )); then
        log "ERROR: backup failed (exit code $rc)."
        write_prom mail_backup_failure.prom <<EOF || true
# HELP mail_backup_last_failure_timestamp_seconds When the last mail backup run failed.
# TYPE mail_backup_last_failure_timestamp_seconds gauge
mail_backup_last_failure_timestamp_seconds $(date +%s)
EOF
    fi
}


check_secrets() {
    local f

    for f in "$IMAP_PASSWORD_FILE" "$RESTIC_PASSWORD_FILE"; do
        if [[ ! -s "$f" ]]; then
            log "ERROR: $f is missing or empty."
            exit 1
        fi
    done
}


check_settings() {
    local v

    for v in "$IMAP_HOST" "$IMAP_USER" "$IMAP_PASSWORD_FILE" "$EXTRA_PATTERNS"; do
        if [[ "$v" == *$'\n'* ]]; then
            log "ERROR: a setting contains a newline."
            exit 1
        fi
    done
    for v in IMAP_PORT PIPELINE_DEPTH MBSYNC_ATTEMPTS KEEP_DAILY KEEP_WEEKLY KEEP_MONTHLY PARK_FAILURES PARK_RATIO PARK_AFTER PARALLEL PROGRESS_INTERVAL REFUSED_MAX COPY_PORT; do
        # No leading zeros: bash arithmetic would read 08 as octal.
        if [[ ! "${!v}" =~ ^(0|[1-9][0-9]*)$ ]]; then
            log "ERROR: $v must be a number, got '${!v}'."
            exit 1
        fi
    done
    if [[ ! "$PARALLEL" =~ ^[1-8]$ ]]; then
        log "ERROR: PARALLEL must be 1-8, got '$PARALLEL'."
        exit 1
    fi
    if [[ ! "$PARK_AFTER" =~ ^[12]$ ]]; then
        log "ERROR: PARK_AFTER must be 1 or 2, got '$PARK_AFTER'."
        exit 1
    fi
    if [[ ! "$CHECK_WEEKDAY" =~ ^[1-7]?$ ]]; then
        log "ERROR: CHECK_WEEKDAY must be 1-7 or empty, got '$CHECK_WEEKDAY'."
        exit 1
    fi
    if [[ "$IMAP_PASSWORD_FILE" == *"'"* ]]; then
        log "ERROR: IMAP_PASSWORD_FILE must not contain a single quote."
        exit 1
    fi
    # Without a colon rsync copies to a local path inside the container and reports success.
    if [[ -n "$COPY_TARGET" && "$COPY_TARGET" != *:* ]]; then
        log "ERROR: COPY_TARGET must be user@host:path (an empty path after the colon is fine)."
        exit 1
    fi
}


check_repository() {
    if [[ ! -f "$RESTIC_REPOSITORY/config" ]]; then
        log "ERROR: no restic repository in $RESTIC_REPOSITORY. Is the data volume mounted? First install: backup.sh init."
        exit 1
    fi
}


# sync_mail : 0 when mbsync went through every folder (refused letters aside), 1 otherwise (the snapshot is taken
# either way). The folders are split into PARALLEL groups, one mbsync session each, run at the same time; after a
# dropped connection only the unfinished groups run again. A failure in keeping the lists is logged but does not
# decide the run.
sync_mail() {
    local attempt i n f glog more ticker="" state=() pids=()

    mkdir -p "$MAILDIR" "$STATE_DIR"
    # Leftovers of a killed run (the lock is ours).
    rm -f "$STATE_DIR"/*.tmp.* "$MBSYNC_LOG".g* "$MBSYNC_RC_FILE".* "$METRICS_DIR"/.mail_backup_*
    : >"$MBSYNC_LOG"
    touch "$PARKED_LIST" "$STALL_FILE" || return 1

    plan_groups
    n=${#GROUP_PATTERNS[@]}
    if (( PROGRESS_INTERVAL > 0 )); then
        progress_ticker &
        ticker=$!
    fi
    # state[i]: "" = to run, done, failed (an error another attempt would just repeat).
    for (( attempt = 1; attempt <= MBSYNC_ATTEMPTS; attempt++ )); do
        touch "$ATTEMPT_MARK"
        log "mbsync: pulling (attempt $attempt of $MBSYNC_ATTEMPTS, $(pending_groups) of $n sessions)"
        for (( i = 0; i < n; i++ )); do
            [[ -z "${state[i]:-}" ]] || continue
            if ! build_mbsyncrc "$MBSYNC_RC_FILE.$i" "${GROUP_PATTERNS[i]}"; then
                log "ERROR: could not write $MBSYNC_RC_FILE.$i."
                state[i]=failed
                continue
            fi
            run_group "$i" &
            pids+=($!)
        done
        # The sessions only: a bare wait would also wait for the progress ticker, forever.
        (( ${#pids[@]} == 0 )) || wait "${pids[@]}"
        pids=()

        more=no
        for (( i = 0; i < n; i++ )); do
            [[ -z "${state[i]:-}" ]] || continue
            glog="$MBSYNC_LOG.g$i"
            cat "$glog" >>"$MBSYNC_LOG"
            read -r MBSYNC_RC TEE_RC <"$glog.rc" || { MBSYNC_RC=255; TEE_RC=255; }
            if mbsync_complete "$glog"; then
                state[i]=done
                # Its folders are done: forget their stalls.
                while IFS= read -r f; do
                    stall_set "$f"
                done < <(gawk '/^Opening far side box / { b = $0; sub(/^Opening far side box /, "", b); sub(/\.\.\.$/, "", b); print b }' "$glog" | sort -u)
                continue
            fi
            check_stall "$glog" || log "ERROR: could not check session $((i + 1)) for a stalled folder."
            # Only a dropped connection is worth another attempt; any other error would just repeat.
            if grep -qE "$CONNECTION_DROP" "$glog"; then
                more=yes
            else
                state[i]=failed
            fi
        done
        write_sizes
        [[ "$more" == yes ]] || break
    done
    if [[ -n "$ticker" ]]; then
        # Its sleep first: an orphaned sleep would hold the run's output open for up to PROGRESS_INTERVAL.
        pkill -P "$ticker" 2>/dev/null
        kill "$ticker" 2>/dev/null
        wait "$ticker" 2>/dev/null
    fi
    rm -f "$MBSYNC_LOG".g* "$MBSYNC_RC_FILE".*

    local complete=yes
    for (( i = 0; i < n; i++ )); do
        [[ "${state[i]:-}" == done ]] || complete=no
    done
    [[ "$complete" == yes ]] && : >"$STALL_FILE"

    update_unfetchable || log "ERROR: could not update $UNFETCHABLE_LIST; it is left as it was."

    log_refusals

    if [[ "$complete" != yes ]]; then
        log "ERROR: mbsync failed; taking the snapshot of what is there, without retention."
        return 1
    fi
    log "mbsync: all folders done; $(wc -l <"$UNFETCHABLE_LIST") refused letters listed in $UNFETCHABLE_LIST; $(gawk 'NF' "$PARKED_LIST" 2>/dev/null | wc -l) folders parked, see $PARKED_LIST"
}


# log_refusals : the distinct texts servers gave for refused letters in this run, with counts.
log_refusals() {
    local line

    while IFS= read -r line; do
        log "mbsync: refused: $line"
    done < <(grep -E "$REFUSED_LINE" "$MBSYNC_LOG" | sed -E 's/^[^:]*returned an error: //; s/ sc=[^ ]*//' | sort | uniq -c | sort -rn | head -5)
}


# quote <value> : the value as an mbsync config string, in double quotes with \ and " escaped.
quote() {
    local v="${1//\\/\\\\}"

    printf '"%s"' "${v//\"/\\\"}"
}


# pending_groups : how many groups the coming attempt runs (reads state from sync_mail).
pending_groups() {
    local i c=0

    for (( i = 0; i < n; i++ )); do
        [[ -n "${state[i]:-}" ]] || c=$((c + 1))
    done
    echo "$c"
}


# plan_groups : GROUP_PATTERNS, one mbsync Patterns value per session. PARALLEL=1: one session, all folders ("*").
# Otherwise the folders mbsync lists on the server, parked ones left out, dealt round-robin in listing order (runs
# of similar folders end up in different sessions). If the list cannot be had, one session. A folder name holding
# * or % works as a wildcard in Patterns and may match another group's folder: mbsync's folder lock then fails
# one of the two sessions, visibly.
plan_groups() {
    local names

    GROUP_PATTERNS=("*")
    (( PARALLEL > 1 )) || return 0
    if ! build_mbsyncrc "$MBSYNC_RC_FILE.list" "*" \
        || ! names="$(mbsync -c "$MBSYNC_RC_FILE.list" -l mail 2>/dev/null)" || [[ -z "$names" ]]; then
        log "mbsync: could not list the folders; one session this run"
        return 0
    fi
    mapfile -t GROUP_PATTERNS < <(printf '%s\n' "$names" | P="$PARKED_LIST" N="$PARALLEL" gawk '
        BEGIN { while ((getline f < ENVIRON["P"]) > 0) parked[f] = 1 }
        NF && !($0 in parked) {
            g = k++ % ENVIRON["N"]
            gsub(/\\/, "\\\\\\\\"); gsub(/"/, "\\\"")
            p[g] = p[g] " \"" $0 "\""
        }
        END { for (i = 0; i < ENVIRON["N"]; i++) if (p[i] != "") print substr(p[i], 2) }')
    if (( ${#GROUP_PATTERNS[@]} == 0 )); then
        GROUP_PATTERNS=("*")
    fi
    log "mbsync: $(printf '%s\n' "$names" | gawk 'NF' | wc -l) folders on the server, ${#GROUP_PATTERNS[@]} sessions"
}


# build_mbsyncrc <file> <patterns> : writes an mbsync config from the settings; Patterns is <patterns>, then
# EXTRA_PATTERNS, then !"<folder>" for each parked folder (the last match wins).
build_mbsyncrc() {
    local exclude

    exclude="$(gawk 'NF { gsub(/\\/, "\\\\\\\\"); gsub(/"/, "\\\""); printf " !\"%s\"", $0 }' "$PARKED_LIST")" || return 1
    cat >"$1" <<EOF
IMAPAccount remote
Host $(quote "$IMAP_HOST")
Port $IMAP_PORT
User $(quote "$IMAP_USER")
PassCmd $(quote "cat '$IMAP_PASSWORD_FILE'")
TLSType IMAPS
CertificateFile /etc/ssl/certs/ca-certificates.crt
AuthMechs LOGIN
Timeout 120
PipelineDepth $PIPELINE_DEPTH

IMAPStore remote
Account remote

MaildirStore local
Path $MAILDIR/
Inbox $MAILDIR/INBOX
SubFolders Verbatim

Channel mail
Far :remote:
Near :local:
Patterns $2${EXTRA_PATTERNS:+ $EXTRA_PATTERNS}$exclude
Create Near
Remove None
Expunge None
Sync Pull
SyncState *
CopyArrivalDate yes
EOF
}


# run_group <i> : one mbsync session with MBSYNC_RC_FILE.<i>. The raw output goes to MBSYNC_LOG.g<i>, the exit
# codes of mbsync and tee to MBSYNC_LOG.g<i>.rc; the console gets the output timestamped, without the per-folder
# chatter, prefixed with the session number when there are several. Runs in the background.
run_group() {
    local rcs prefix=""

    (( PARALLEL > 1 )) && prefix="[$(( $1 + 1 ))] "
    set +e
    mbsync -V -c "$MBSYNC_RC_FILE.$1" mail 2>&1 | tee "$MBSYNC_LOG.g$1" | grep --line-buffered -vE "$MBSYNC_CHATTER" \
        | P="$prefix" gawk '{ print strftime("%Y-%m-%dT%H:%M:%SZ", systime(), 1), ENVIRON["P"] $0; fflush() }'
    rcs=("${PIPESTATUS[@]}")
    echo "${rcs[0]} ${rcs[1]}" >"$MBSYNC_LOG.g$1.rc"
}


# stall_get <folder> : refused letters of the last stalled attempt in that folder, or nothing.
stall_get() {
    F="$1" gawk -F'\t' '$1 == ENVIRON["F"] { print $2 }' "$STALL_FILE" 2>/dev/null
}


# stall_set <folder> <refused> : records a stalled attempt in that folder; stall_set <folder> forgets it.
stall_set() {
    local tmp

    tmp="$(mktemp "$STATE_DIR/stall.tmp.XXXXXX")" || return 1
    F="$1" gawk -F'\t' '$1 != ENVIRON["F"]' "$STALL_FILE" 2>/dev/null >"$tmp"
    [[ -z "${2:-}" ]] || printf '%s\t%s\n' "$1" "$2" >>"$tmp"
    mv "$tmp" "$STALL_FILE"
}


# mbsync_complete <log> : whether this mbsync run reached its normal end with every error in it being a refused
# letter. A kill (exit code above 1) or a log tee could not write never counts.
mbsync_complete() {
    local refused errors

    (( TEE_RC == 0 )) || return 1
    # Before the exit code: a server refusing everything must fail the run even if mbsync exits 0.
    refused="$(grep -cE "$REFUSED_LINE" "$1")" || true
    if (( REFUSED_MAX > 0 && refused > REFUSED_MAX )); then
        log "ERROR: $refused refused letters in one attempt, more than REFUSED_MAX ($REFUSED_MAX); counted as a failure."
        return 1
    fi
    (( MBSYNC_RC == 0 )) && return 0
    (( MBSYNC_RC == 1 )) || return 1
    grep -qE '^Channels: [0-9]+ +Boxes: [0-9]+' "$1" || return 1
    errors="$(grep -vE "$MBSYNC_CHATTER" "$1" | grep -vE "$REFUSED_LINE|$UNFETCHABLE_WARNING" | grep -ciE "$MBSYNC_ERROR")" || true
    (( refused > 0 && errors == 0 ))
}


# refused_letters <log> : folder <TAB> uid of each refused letter; the folder comes from the last "Opening far side
# box" line before it.
refused_letters() {
    T="$REFUSED_LINE" gawk -v OFS='\t' '
        /^Opening far side box / { box = $0; sub(/^Opening far side box /, "", box); sub(/\.\.\.$/, "", box); next }
        $0 ~ ENVIRON["T"] { match($0, /UID FETCH [0-9]+/); print box, substr($0, RSTART + 10, RLENGTH - 10) }
    ' "$1"
}


# check_stall <session log> : after a session cut off by a dropped connection, parks the folder it was cut off in
# when it was stalled there PARK_AFTER times in a row (stall.tsv keeps the last stall per folder, across runs).
check_stall() {
    local box fails stored prev_fails never

    grep -qE "$CONNECTION_DROP" "$1" || return 0
    box="$(gawk '/^Opening far side box / { b = $0; sub(/^Opening far side box /, "", b); sub(/\.\.\.$/, "", b) } END { print b }' "$1")" \
        || return 1
    [[ -n "$box" ]] || return 0
    if grep -qxF -- "$box" "$PARKED_LIST" 2>/dev/null; then
        return 0
    fi
    fails="$(refused_letters "$1" | BOX="$box" gawk -F'\t' '$1 == ENVIRON["BOX"]' | wc -l)" || return 1

    # Without its directory the progress check below would count 0 and park a folder that is moving.
    if [[ ! -d "$MAILDIR/$box" ]]; then
        log "ERROR: no directory $MAILDIR/$box for folder $box; not parked (folder name and directory differ?)"
        stall_set "$box"
        return 0
    fi
    # Letters stored in that folder itself in this attempt (ctime: mbsync sets mtime to the arrival date).
    stored="$(find "$MAILDIR/$box/cur" "$MAILDIR/$box/new" -mindepth 1 -maxdepth 1 -type f -cnewer "$ATTEMPT_MARK" 2>/dev/null | wc -l)"

    if (( fails < PARK_FAILURES || fails <= PARK_RATIO * stored )); then
        stall_set "$box"
        return 0
    fi
    for never in "${NEVER_PARK[@]}"; do
        if [[ "$box" == "$never" ]]; then
            log "mbsync: attempt stalled in $box ($fails refused, $stored stored); $box is never parked"
            stall_set "$box"
            return 0
        fi
    done
    prev_fails="$(stall_get "$box")"
    if (( PARK_AFTER <= 1 )) || [[ -n "$prev_fails" ]]; then
        printf '%s\n' "$box" >>"$PARKED_LIST" || return 1
        stall_set "$box"
        if (( PARK_AFTER <= 1 )); then
            log "mbsync: parked $box: attempt stalled in it ($fails refused, $stored stored); see $PARKED_LIST"
        else
            log "mbsync: parked $box: two attempts in a row stalled in it ($prev_fails, then $fails refused, $stored stored); see $PARKED_LIST"
        fi
    else
        stall_set "$box" "$fails" || return 1
        log "mbsync: attempt stalled in $box ($fails refused, $stored stored); parked if the next one is too"
    fi
}


# rewind_unfetchable : lowers MaxPulledUid of each listed folder below its smallest listed UID. A folder with a
# pending journal is left alone: mbsync replays the journal over the state on start.
rewind_unfetchable() {
    local box min state n=0

    [[ -s "$UNFETCHABLE_LIST" ]] || return 0
    while IFS=$'\t' read -r box min; do
        state="$MAILDIR/$box/.mbsyncstate"
        if [[ ! -f "$state" || -e "$state.journal" ]]; then
            log "mbsync: no clean state for $box, its refused letters wait for the next retry"
            continue
        fi
        lower_max_pulled "$state" "$((min - 1))" || return 1
        n=$((n + 1))
    done < <(gawk -F'\t' '!($1 in m) || $2 < m[$1] { m[$1] = $2 } END { for (b in m) print b "\t" m[b] }' "$UNFETCHABLE_LIST")
    log "mbsync: asking again for the letters in $UNFETCHABLE_LIST ($n folders)"
}


# rewind_all : MaxPulledUid 0 in every folder state without a journal, so the coming run asks again for every
# letter mbsync has no record of, including refusals that were never listed.
rewind_all() {
    local state n=0

    while IFS= read -r -d '' state; do
        if [[ -e "$state.journal" ]]; then
            log "mbsync: $state has a pending journal, left as is; run rewind-all again after a complete run"
            continue
        fi
        lower_max_pulled "$state" 0 || return 1
        n=$((n + 1))
    done < <(find "$MAILDIR" -name .mbsyncstate -type f -print0)
    log "mbsync: MaxPulledUid set to 0 in $n folders"
}


# lower_max_pulled <state file> <uid> : sets MaxPulledUid to <uid> when it is higher; the record lines are not
# touched. Written in STATE_DIR and moved in place (same filesystem), so a kill leaves no stray file in the Maildir.
lower_max_pulled() {
    local tmp

    tmp="$(mktemp "$STATE_DIR/state.tmp.XXXXXX")" || return 1
    gawk -v max="$2" '/^MaxPulledUid [0-9]+$/ && $2 > max { $2 = max } { print }' "$1" >"$tmp" || return 1
    mv "$tmp" "$1"
}


# update_unfetchable : merges the refused letters of this run into UNFETCHABLE_LIST, moves the listed letters the
# folder state now has a record for to RECOVERED_LIST and writes the metric. Records still in a journal are not
# looked at. The list is replaced only when every step succeeded.
update_unfetchable() {
    local now run tmp recovered

    now="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    run="$(mktemp "$STATE_DIR/run.tmp.XXXXXX")" || return 1
    tmp="$(mktemp "$STATE_DIR/new.tmp.XXXXXX")" || return 1
    recovered="$(mktemp "$STATE_DIR/rec.tmp.XXXXXX")" || return 1
    touch "$UNFETCHABLE_LIST" || return 1

    refused_letters "$MBSYNC_LOG" | sort -u >"$run" || return 1

    gawk -F'\t' -v OFS='\t' -v now="$now" -v maildir="$MAILDIR" -v rec="$recovered" '
        function has_record(box, uid,    f, line, a) {
            if (!(box in loaded)) {
                loaded[box] = 1
                f = maildir "/" box "/.mbsyncstate"
                while ((getline line < f) > 0)
                    if (split(line, a, " ") >= 2 && a[1] ~ /^[0-9]+$/ && a[2] + 0 > 0)
                        paired[box SUBSEP a[1]] = 1
                close(f)
            }
            return (box SUBSEP uid) in paired
        }
        FILENAME == ARGV[1] { seen[$1 FS $2] = 1; next }
        ($1 FS $2) in seen { $4 = now; $5++; print; delete seen[$1 FS $2]; next }
        has_record($1, $2) { print $0, now >rec; next }
        { print }
        END { for (k in seen) { split(k, a, FS); print a[1], a[2], now, now, 1 } }
    ' "$run" "$UNFETCHABLE_LIST" | sort -t "$(printf '\t')" -k1,1 -k2,2n >"$tmp" || return 1
    mv "$tmp" "$UNFETCHABLE_LIST" || return 1

    if [[ -s "$recovered" ]]; then
        cat "$recovered" >>"$RECOVERED_LIST" || return 1
        log "mbsync: $(wc -l <"$recovered") letters from $UNFETCHABLE_LIST came through, see $RECOVERED_LIST"
    fi
    rm -f "$run" "$recovered"

    write_prom mail_backup_unfetchable.prom <<EOF
# HELP mail_backup_unfetchable_messages Letters the server refuses; list in $UNFETCHABLE_LIST.
# TYPE mail_backup_unfetchable_messages gauge
mail_backup_unfetchable_messages $(wc -l <"$UNFETCHABLE_LIST")
# HELP mail_backup_parked_folders Folders left out of mbsync; list in $PARKED_LIST.
# TYPE mail_backup_parked_folders gauge
mail_backup_parked_folders $(gawk 'NF' "$PARKED_LIST" 2>/dev/null | wc -l)
EOF
}


# snapshot <retention: yes|no>
snapshot() {
    # Always the same paths, even when empty: restic picks the parent snapshot by the exact path set.
    mkdir -p "$GONE_DIR" "$STATE_DIR"
    log "restic: snapshot of $MAILDIR $GONE_DIR $STATE_DIR"
    restic backup --quiet --host "$SNAPSHOT_HOST" --tag "$SNAPSHOT_TAG" "$MAILDIR" "$GONE_DIR" "$STATE_DIR"

    if [[ "$1" != yes ]]; then
        return 0
    fi

    log "restic: retention (daily $KEEP_DAILY, weekly $KEEP_WEEKLY, monthly $KEEP_MONTHLY)"
    restic forget --quiet --host "$SNAPSHOT_HOST" --tag "$SNAPSHOT_TAG" --group-by host,tags \
        --keep-daily "$KEEP_DAILY" --keep-weekly "$KEEP_WEEKLY" --keep-monthly "$KEEP_MONTHLY" --prune

    if [[ -n "$CHECK_WEEKDAY" && "$(date +%u)" == "$CHECK_WEEKDAY" ]]; then
        log "restic: weekly check, reading $CHECK_READ_SUBSET of the data"
        restic check --read-data-subset="$CHECK_READ_SUBSET"
    fi
}


# copy_offsite : sends the repository files COPY_TARGET does not have yet. Repository files never change once
# written, so adding new ones keeps the copy a valid repository (a superset: pruned packs stay there). Runs under
# the lock after the snapshot, so restic writes nothing meanwhile. rsync sorts the list: data/ and index/ go before
# snapshots/, so an interrupted copy never holds a snapshot whose data is missing. A failure does not fail the run.
copy_offsite() {
    local started list

    started="$(date +%s)"
    list="$(mktemp)" || return 1
    (cd "$RESTIC_REPOSITORY" && find . -type f ! -path './locks/*' | sed 's,^\./,,') >"$list" || { rm -f "$list"; return 1; }
    log "copy: restic repository to $COPY_TARGET ($(wc -l <"$list") files, those already there are skipped)"
    if ! rsync --recursive --times --ignore-existing --chmod=D700,F600 --files-from="$list" \
        -e "ssh -i '$COPY_KEY' -p $COPY_PORT -o BatchMode=yes -o StrictHostKeyChecking=yes -o 'UserKnownHostsFile=$COPY_KNOWN_HOSTS'" \
        "$RESTIC_REPOSITORY/" "$COPY_TARGET"; then
        rm -f "$list"
        return 1
    fi
    rm -f "$list"

    write_prom mail_backup_copy.prom <<EOF
# HELP mail_backup_copy_last_success_timestamp_seconds When the restic repository was last copied off-host.
# TYPE mail_backup_copy_last_success_timestamp_seconds gauge
mail_backup_copy_last_success_timestamp_seconds $(date +%s)
# HELP mail_backup_copy_last_duration_seconds How long the last off-host copy took.
# TYPE mail_backup_copy_last_duration_seconds gauge
mail_backup_copy_last_duration_seconds $(( $(date +%s) - started ))
EOF
    log "copy: done"
}


copy_failed() {
    log "ERROR: copy to $COPY_TARGET failed; the next run tries again."
    write_prom mail_backup_copy_failure.prom <<EOF || true
# HELP mail_backup_copy_last_failure_timestamp_seconds When the last off-host copy failed.
# TYPE mail_backup_copy_last_failure_timestamp_seconds gauge
mail_backup_copy_last_failure_timestamp_seconds $(date +%s)
EOF
}


# progress_ticker : runs in the background while mbsync works: every PROGRESS_INTERVAL seconds writes the sizes and
# mail_backup_progress_timestamp_seconds, so a dashboard follows a long download live and sees that it is moving.
# Stops when killed by sync_mail or when the script that started it is gone.
progress_ticker() {
    local parent=$$

    while kill -0 "$parent" 2>/dev/null; do
        write_sizes
        write_prom mail_backup_progress.prom <<EOF || true
# HELP mail_backup_progress_timestamp_seconds Last progress tick of a running mbsync (every PROGRESS_INTERVAL s).
# TYPE mail_backup_progress_timestamp_seconds gauge
mail_backup_progress_timestamp_seconds $(date +%s)
EOF
        sleep "$PROGRESS_INTERVAL"
    done
}


# write_sizes : letters, Maildir and repository size as they are now, into mail_backup_size.prom (and the globals
# LETTERS, MAILDIR_BYTES, REPO_BYTES). Called after every attempt and every snapshot, good or not, so a long first
# download shows its progress. A failed count must not fail the run: it becomes NaN.
write_sizes() {
    local counts

    # One walk of the Maildir for both numbers (letters: files in cur/ and new/; bytes: all files).
    counts="$(find "$MAILDIR" -type f -printf '%s %h\n' 2>/dev/null \
        | gawk '{ b += $1; if ($2 ~ /\/(cur|new)$/) n++ } END { print n + 0, b + 0 }')" || counts=""
    read -r LETTERS MAILDIR_BYTES <<<"$counts" || true
    REPO_BYTES="$(du -sb "$RESTIC_REPOSITORY" 2>/dev/null | cut -f1)" || REPO_BYTES=NaN
    [[ -n "${LETTERS:-}" ]] || LETTERS=NaN
    [[ -n "${MAILDIR_BYTES:-}" ]] || MAILDIR_BYTES=NaN
    [[ -n "$REPO_BYTES" ]] || REPO_BYTES=NaN

    # Earlier versions kept these in mail_backup.prom; the same metric in two files makes node_exporter drop the
    # whole textfile collector, so take them out of there first.
    if [[ -f "$METRICS_DIR/mail_backup.prom" ]] && grep -qE '^mail_backup_(letters|maildir_bytes|repository_bytes) ' "$METRICS_DIR/mail_backup.prom"; then
        grep -vE 'mail_backup_(letters|maildir_bytes|repository_bytes)' "$METRICS_DIR/mail_backup.prom" | write_prom mail_backup.prom || true
    fi

    write_prom mail_backup_size.prom <<EOF || true
# HELP mail_backup_letters Letters in the Maildir copy now (after the last mbsync attempt).
# TYPE mail_backup_letters gauge
mail_backup_letters ${LETTERS}
# HELP mail_backup_maildir_bytes Size of the Maildir copy now.
# TYPE mail_backup_maildir_bytes gauge
mail_backup_maildir_bytes ${MAILDIR_BYTES}
# HELP mail_backup_repository_bytes Size of the restic repository now.
# TYPE mail_backup_repository_bytes gauge
mail_backup_repository_bytes ${REPO_BYTES}
EOF
}


write_metrics() {
    local duration="$1"

    write_prom mail_backup.prom <<EOF
# HELP mail_backup_last_success_timestamp_seconds When the last mail backup (mbsync + restic snapshot) succeeded.
# TYPE mail_backup_last_success_timestamp_seconds gauge
mail_backup_last_success_timestamp_seconds $(date +%s)
# HELP mail_backup_last_duration_seconds How long the last good run took.
# TYPE mail_backup_last_duration_seconds gauge
mail_backup_last_duration_seconds ${duration}
EOF
    log "done: $LETTERS letters, Maildir $MAILDIR_BYTES bytes, repository $REPO_BYTES bytes, ${duration}s"
}


# init : creates the restic repository, once.
init() {
    check_secrets
    if [[ -f "$RESTIC_REPOSITORY/config" ]]; then
        log "restic: repository in $RESTIC_REPOSITORY already exists, nothing to do"
        return 0
    fi
    restic init
}


main() {
    local started synced=yes

    case "${1:-}" in
        init) init; return ;;
        ""|rewind-all|retry) ;;
        *) log "ERROR: unknown command '$1' (init, rewind-all, retry)"; exit 2 ;;
    esac

    exec 9>"$LOCK_FILE"
    if [[ "$WAIT_FOR_LOCK" == yes ]]; then
        flock 9
    elif ! flock -n 9; then
        # Not a failure: a long first download may still be running at the scheduled time.
        log "another backup run holds $LOCK_FILE, skipping this one."
        exit 0
    fi

    trap on_exit EXIT
    started="$(date +%s)"
    check_settings
    check_secrets
    check_repository
    case "${1:-}" in
        rewind-all) mkdir -p "$STATE_DIR"; rewind_all ;;
        retry) mkdir -p "$STATE_DIR"; rewind_unfetchable ;;
    esac
    sync_mail || synced=no
    snapshot "$synced"
    write_sizes
    if [[ -n "$COPY_TARGET" ]]; then
        copy_offsite || copy_failed
    fi
    if [[ "$synced" != yes ]]; then
        exit 1
    fi
    write_metrics "$(( $(date +%s) - started ))"
}


main "$@"
