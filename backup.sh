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
# Big folders. mbsync writes a folder's state only when it finishes the folder. A folder too big for one session
# never finishes, and every attempt asks again, from the lowest UID, for all the letters refused before. After an
# attempt cut off in a folder, checkpoint_state does what mbsync does at the end of a folder: folds the journal into
# the state and moves MaxPulledUid up to where the attempt got to. The next attempt goes on from there.
#
# Parked folders, a fallback for a cut-off folder no checkpoint could be written for. It is parked (left out of
# mbsync) when PARK_AFTER attempts in a row (2 by default, or 1) were cut off in it with at least PARK_FAILURES
# refused letters and more than PARK_RATIO times as many as letters stored from it in that attempt. NEVER_PARK
# folders are not parked: the run fails instead. Remove its line from PARKED_LIST to take it back.
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
# Letters on the server per folder at the start of the last run: folder <TAB> messages (IMAP STATUS).
FOLDER_COUNTS="$STATE_DIR/folders.tsv"
# The folders mbsync lists, one per line (this run).
FOLDER_LIST="/tmp/mbsync-folders"
# The last stalled attempt per folder, waiting for a second one (PARK_AFTER=2): folder <TAB> refused letters.
STALL_FILE="$STATE_DIR/stall.tsv"
LOCK_FILE="/data/.backup.lock"
# Full mbsync -V output of the last run, all attempts and sessions (.g<i>: one session's attempt, while it runs).
MBSYNC_LOG="/data/.mbsync-last.log"
# mbsync configs, one per session: /tmp/mbsyncrc.<i> (.list: the one for listing the folders).
MBSYNC_RC_FILE="/tmp/mbsyncrc"
# Touched before each attempt: letters stored in it are the files changed after this.
ATTEMPT_MARK="/tmp/mbsync-attempt.mark"
# The last journal folded by a checkpoint, per folder; not in the snapshots.
JOURNAL_BACKUP_DIR="/data/.journals"
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

    # Every end of a run, good or not: with the start (mail_backup_run.prom) a dashboard tells a running backup.
    # Microseconds, as the start: a loop of runs starts the next one in the same second the last one ended.
    write_prom mail_backup_run_end.prom <<EOF || true
# HELP mail_backup_run_finished_timestamp_seconds When the last backup run ended (good or not).
# TYPE mail_backup_run_finished_timestamp_seconds gauge
mail_backup_run_finished_timestamp_seconds ${EPOCHREALTIME/,/.}
EOF
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
    rm -f "$STATE_DIR"/*.tmp.* "$MBSYNC_LOG".g* "$MBSYNC_RC_FILE".* "$METRICS_DIR"/.mail_backup_* /tmp/netrc.* /tmp/curl.*
    : >"$MBSYNC_LOG"
    touch "$PARKED_LIST" "$STALL_FILE" || return 1

    list_folders || true
    count_server_messages || log "mbsync: could not get the message counts from the server; the per-folder counts keep the last ones"
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
            # Only a dropped connection is worth another attempt; any other error would just repeat.
            if grep -qE "$CONNECTION_DROP" "$glog"; then
                more=yes
                # The folder it was cut off in: a checkpoint, so the next attempt goes on from there; parking only
                # when that cannot be done.
                f="$(cut_folder "$glog")" || f=""
                if [[ -n "$f" ]] && checkpoint_state "$f"; then
                    stall_set "$f"
                else
                    check_stall "$glog" || log "ERROR: could not check session $((i + 1)) for a stalled folder."
                fi
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


# list_folders : FOLDER_LIST gets every folder mbsync lists on the server (parked ones too, EXTRA_PATTERNS applied),
# one per line, in mbsync's names (UTF-8, / between levels). Empty when the list cannot be had.
list_folders() {
    : >"$FOLDER_LIST"
    build_mbsyncrc "$MBSYNC_RC_FILE.list" "*" all || return 1
    # A list from a failed mbsync is not used.
    if ! mbsync -c "$MBSYNC_RC_FILE.list" -l mail >"$FOLDER_LIST.all" 2>/dev/null; then
        rm -f "$FOLDER_LIST.all"
        return 1
    fi
    gawk 'NF' "$FOLDER_LIST.all" >"$FOLDER_LIST" || : >"$FOLDER_LIST"
    rm -f "$FOLDER_LIST.all"
    [[ -s "$FOLDER_LIST" ]]
}


# count_server_messages : FOLDER_COUNTS gets the number of letters on the server in every folder of FOLDER_LIST,
# by IMAP STATUS over one connection (curl, one request per folder). mbsync names are turned back into the
# server's: its hierarchy delimiter instead of /, modified UTF-7 (RFC 3501) instead of UTF-8. The password goes to
# curl in a netrc file readable by root only, never on a command line. FOLDER_COUNTS is replaced only on success.
count_server_messages() {
    local netrc cfg answers delim pass user rc=0

    [[ -s "$FOLDER_LIST" ]] || return 1
    netrc="$(mktemp /tmp/netrc.XXXXXX)" || return 1
    cfg="$(mktemp /tmp/curl.XXXXXX)" || { rm -f "$netrc"; return 1; }
    answers="$(mktemp "$STATE_DIR/folders.tmp.XXXXXX")" || { rm -f "$netrc" "$cfg"; return 1; }
    pass="$(<"$IMAP_PASSWORD_FILE")"
    user="$IMAP_USER"
    # netrc strings in double quotes: backslash and quote escaped.
    pass="${pass//\\/\\\\}"
    user="${user//\\/\\\\}"
    printf 'machine %s login "%s" password "%s"\n' "$IMAP_HOST" "${user//\"/\\\"}" "${pass//\"/\\\"}" >"$netrc"
    pass=""

    # The delimiter: the answer to LIST "" "" is * LIST (...) "<delimiter>" "" (NIL: a flat namespace; a backslash
    # comes quoted as "\\").
    delim="$(curl -s --connect-timeout 30 --max-time 60 --netrc-file "$netrc" "imaps://$IMAP_HOST:$IMAP_PORT/" -X 'LIST "" ""' \
        | tr -d '\r' | sed -nE 's/^\* LIST \([^)]*\) "([\\][\\]|[^\\])".*/\1/p' | head -n 1)" || true
    [[ "$delim" != '\\' ]] || delim='\'

    # One curl run, one transfer per folder (curl config, "next" between them); curl keeps the connection.
    # The delimiter through the environment: gawk -v would eat a backslash.
    D="$delim" LC_ALL=C gawk -v url="imaps://$IMAP_HOST:$IMAP_PORT/" -v netrc="$netrc" -v map="$cfg.map" '
        BEGIN { for (i = 0; i < 256; i++) ord[sprintf("%c", i)] = i
                b64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+,"
                delim = ENVIRON["D"] }
        function flush(    out, i, n, v) {
            if (nb == 0) return ""
            out = "&"
            for (i = 0; i < nb; i += 3) {
                v = bytes[i] * 65536 + (i + 1 < nb ? bytes[i + 1] : 0) * 256 + (i + 2 < nb ? bytes[i + 2] : 0)
                out = out substr(b64, int(v / 262144) + 1, 1) substr(b64, int(v / 4096) % 64 + 1, 1)
                if (i + 1 < nb) out = out substr(b64, int(v / 64) % 64 + 1, 1)
                if (i + 2 < nb) out = out substr(b64, v % 64 + 1, 1)
            }
            nb = 0
            return out "-"
        }
        function unit(u) { bytes[nb++] = int(u / 256); bytes[nb++] = u % 256 }
        # UTF-8 -> modified UTF-7: printable ASCII as is (& as &-), anything else as base64 of UTF-16BE.
        function mutf7(s,    out, i, n, c, cp, k) {
            out = ""; nb = 0; n = length(s)
            for (i = 1; i <= n; i++) {
                c = ord[substr(s, i, 1)]
                if (c >= 32 && c <= 126) { out = out flush() (c == 38 ? "&-" : substr(s, i, 1)); continue }
                if (c >= 240) { cp = c % 8; k = 3 } else if (c >= 224) { cp = c % 16; k = 2 } else if (c >= 192) { cp = c % 32; k = 1 } else { cp = c; k = 0 }
                for (; k > 0 && i < n; k--) cp = cp * 64 + ord[substr(s, ++i, 1)] % 64
                if (cp >= 65536) { cp -= 65536; unit(55296 + int(cp / 1024)); unit(56320 + cp % 1024) } else unit(cp)
            }
            return out flush()
        }
        function q(s) { gsub(/[\\"]/, "\\\\&", s); return s }
        {
            name = $0
            # As a gsub replacement, & and \ would be special.
            rep = delim
            gsub(/[\\&]/, "\\\\&", rep)
            if (delim != "" && delim != "/") gsub(/\//, rep, name)
            enc = mutf7(name)
            print enc "\t" $0 > map
            # Timeouts are per transfer in curl: in every section.
            if (NR > 1) print "next"
            print "url = \"" q(url) "\""
            print "netrc-file = \"" q(netrc) "\""
            print "connect-timeout = 30"
            print "max-time = 60"
            print "request = \"" q("STATUS \"" q(enc) "\" (MESSAGES)") "\""
        }' "$FOLDER_LIST" >"$cfg" || rc=1

    # * STATUS <mailbox> (MESSAGES <n>), the mailbox quoted or not; back to the mbsync name through the map. curl
    # exits with the code of its last transfer only: the answers decide, a folder without one keeps no count.
    if (( rc == 0 )); then
        { timeout 900 curl -s -K "$cfg" || true; } | tr -d '\r' | gawk -v map="$cfg.map" '
            BEGIN { FS = "\t"; while ((getline line < map) > 0) { split(line, a, "\t"); name[a[1]] = a[2] } FS = " " }
            /^\* STATUS / && match($0, /\(MESSAGES [0-9]+\)/) {
                n = substr($0, RSTART + 10, RLENGTH - 11)
                box = substr($0, 10, RSTART - 11)
                if (box ~ /^".*"$/) { box = substr(box, 2, length(box) - 2); gsub(/\\\\/, "\001", box); gsub(/\\"/, "\"", box); gsub(/\001/, "\\", box) }
                if (box in name) print name[box] "\t" n
            }' | sort >"$answers" || rc=1
    fi
    rm -f "$netrc" "$cfg" "$cfg.map"
    if (( rc != 0 )) || [[ ! -s "$answers" ]]; then
        rm -f "$answers"
        return 1
    fi
    # Folders that got no answer this time keep their last count; folders no longer listed are dropped.
    touch "$FOLDER_COUNTS"
    gawk -F'\t' -v OFS='\t' '
        FILENAME == ARGV[1] { listed[$0] = 1; next }
        FILENAME == ARGV[2] { now[$1] = $2; print; next }
        ($1 in listed) && !($1 in now) { print }
    ' "$FOLDER_LIST" "$answers" "$FOLDER_COUNTS" | sort >"$answers.all" || { rm -f "$answers" "$answers.all"; return 1; }
    rm -f "$answers"
    mv "$answers.all" "$FOLDER_COUNTS"
}


# plan_groups : GROUP_PATTERNS, one mbsync Patterns value per session. PARALLEL=1: one session, all folders ("*").
# Otherwise the folders in FOLDER_LIST, parked ones left out, dealt round-robin in listing order (runs of similar
# folders end up in different sessions). If there is no list, one session. A folder name holding * or % works as a
# wildcard in Patterns and may match another group's folder: mbsync's folder lock then fails one of the two
# sessions, visibly.
plan_groups() {
    local names

    GROUP_PATTERNS=("*")
    (( PARALLEL > 1 )) || return 0
    if [[ ! -s "$FOLDER_LIST" ]]; then
        log "mbsync: could not list the folders; one session this run"
        return 0
    fi
    names="$(cat "$FOLDER_LIST")"
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


# build_mbsyncrc <file> <patterns> [all] : writes an mbsync config from the settings; Patterns is <patterns>, then
# EXTRA_PATTERNS, then !"<folder>" for each parked folder (the last match wins). With "all", parked folders are not
# left out (for listing every folder).
build_mbsyncrc() {
    local exclude=""

    if [[ "${3:-}" != all ]]; then
        exclude="$(gawk 'NF { gsub(/\\/, "\\\\\\\\"); gsub(/"/, "\\\""); printf " !\"%s\"", $0 }' "$PARKED_LIST")" || return 1
    fi
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


# cut_folder <session log> : the folder the session was in when it ended (the last one it opened).
cut_folder() {
    gawk '/^Opening far side box / { b = $0; sub(/^Opening far side box /, "", b); sub(/\.\.\.$/, "", b) } END { print b }' "$1"
}


# check_stall <session log> : after a session cut off by a dropped connection, parks the folder it was cut off in
# when it was stalled there PARK_AFTER times in a row (stall.tsv keeps the last stall per folder, across runs).
# Only for a folder no checkpoint could be written for.
check_stall() {
    local box fails stored prev_fails never

    grep -qE "$CONNECTION_DROP" "$1" || return 0
    box="$(cut_folder "$1")" || return 1
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


# checkpoint_state <folder> : after an attempt cut off in <folder>, does what mbsync does when it finishes a folder:
# folds the journal into the state file and moves MaxPulledUid up to where the attempt got to. Without this a
# folder too big for one session never gets its state written, and every
# attempt asks again, from the lowest UID, for all the letters refused before: after a few attempts the whole
# session goes on old refusals. Kept: the stored letters (pairs) with their flags. Dropped: letters queued but not
# reached; above MaxPulledUid they count as new and come next time.
#
# MaxPulledUid goes up to the end of the unbroken run of letters the attempt dealt with: below the lowest letter still
# queued, at most the highest stored or failed one (pipelined fetches may be answered out of order). Every letter
# that failed (refused, or any other failed fetch) up to there is added to UNFETCHABLE_LIST before the state is
# replaced: mbsync never asks for it again by itself, only retry does. Nothing is written when MaxPulledUid would not
# move and no letter was stored (a folder the server gives nothing from: parking decides). The old journal goes to
# JOURNAL_BACKUP_DIR. Returns 0 when a checkpoint was written, 1 otherwise.
checkpoint_state() {
    local box="$1" dir state journal tmp failed stats backup old new pairs before

    dir="$MAILDIR/$box"
    state="$dir/.mbsyncstate"
    journal="$state.journal"
    # mbsync replays a journal only while .mbsyncstate.new exists.
    [[ -f "$journal" && -f "$state.new" ]] || return 1
    if [[ "$(head -n 1 "$journal")" != 5 ]]; then
        log "mbsync: journal of $box is not version 5; no checkpoint"
        return 1
    fi
    tmp="$(mktemp "$STATE_DIR/state.tmp.XXXXXX")" || return 1
    failed="$(mktemp "$STATE_DIR/failed.tmp.XXXXXX")" || { rm -f "$tmp"; return 1; }
    # Replays the state file and the journal entries that matter for a pull-only channel: | (UID validities),
    # N (max UIDs), + (a letter queued), > (stored: far UID paired with its near UID), % (its flags then), * (flags of
    # a pair), - (entry gone: a failed fetch while not paired). Per far UID the last of queued / failed / stored
    # counts: each attempt queues the letters it has no record of again. A last line without a newline is a write cut
    # off by a kill; mbsync would refuse it, it is skipped (if it was a ">", that letter comes again, a duplicate).
    if ! stats="$(gawk -v sf="$state" -v out="$tmp" -v failed="$failed" '
        function letters(n,    s, i) {
            s = ""
            for (i = 1; i <= 6; i++) { if (n % 2) s = s substr("DFPRST", i, 1); n = int(n / 2) }
            return s
        }
        BEGIN {
            while ((getline line < sf) > 0) {
                if (line == "") { body = 1; continue }
                if (!body) {
                    split(line, h, " ")
                    if (h[1] == "FarUidValidity") fu = h[2]
                    else if (h[1] == "NearUidValidity") nu = h[2]
                    else if (h[1] == "MaxPulledUid") maxf = h[2] + 0
                    else if (h[1] == "MaxPushedUid") maxn = h[2] + 0
                    else extra = extra line "\n"
                    continue
                }
                n = split(line, r, " ")
                if (n < 2) continue
                if (r[2] + 0 > 0) { rest = line; sub(/^[0-9]+ [0-9]+ ?/, "", rest); pair[r[1] " " r[2]] = rest; st[r[1] + 0] = "s"; before++ }
                # A record without a near UID (not seen with a pull-only channel) is kept as it is.
                else keep = keep line "\n"
            }
            close(sf)
            oldmax = maxf + 0
        }
        FNR == 1 { next }
        RT == "" { next }
        $1 == "|" { fu = $2; nu = $3; next }
        $1 == "N" { if ($2 == 0) { if ($3 + 0 > maxf) maxf = $3 + 0 } else if ($3 + 0 > maxn) maxn = $3 + 0; next }
        $1 == "+" { if ($3 == 0 && st[$2 + 0] != "s") st[$2 + 0] = "q"; next }
        $1 == "%" { pflags[$2 " " $3] = $4; next }
        $1 == ">" { k = $2 " " $3; if ($3 != 0) delete pair[k]; if ($4 != 0) { pair[$2 " " $4] = letters(pflags[k] + 0); st[$2 + 0] = "s" }; next }
        $1 == "*" { k = $2 " " $3; if (k in pair) pair[k] = letters($4 + 0); next }
        $1 == "-" { if ($3 == 0) { if (st[$2 + 0] != "s") st[$2 + 0] = "f" } else delete pair[$2 " " $3]; next }
        END {
            if (fu == "" || nu == "") exit 1
            done = 0; low = ""
            for (u in st) {
                if (st[u] == "q") { if (low == "" || u + 0 < low) low = u + 0 }
                else if (u + 0 > done) done = u + 0
            }
            x = done
            if (low != "" && low - 1 < x) x = low - 1
            if (x < maxf) x = maxf
            # Failed, or (not expected) still queued below the new MaxPulledUid: listed for retry.
            for (u in st) if ((st[u] == "f" || st[u] == "q") && u + 0 <= x) print u > failed
            close(failed)
            np = 0
            for (k in pair) { split(k, p, " "); if (p[2] + 0 > maxn) maxn = p[2] + 0; np++ }
            printf "FarUidValidity %s\nNearUidValidity %s\nMaxPulledUid %d\nMaxPushedUid %d\n%s\n", fu, nu, x, maxn, extra > out
            # Closed before sort appends the records.
            close(out)
            cmd = "sort -n -k1,1 -k2,2 >> \"" out "\""
            for (k in pair) print k " " pair[k] | cmd
            printf "%s", keep | cmd
            close(cmd)
            print oldmax, x, np, before + 0
        }' "$journal")"; then
        rm -f "$tmp" "$failed"
        log "mbsync: could not fold the journal of $box; no checkpoint"
        return 1
    fi
    read -r old new pairs before <<<"$stats"
    if (( new == old && pairs == before )); then
        rm -f "$tmp" "$failed"
        return 1
    fi
    if ! add_unfetchable "$box" "$failed"; then
        rm -f "$tmp" "$failed"
        log "mbsync: could not list the failed letters of $box; no checkpoint"
        return 1
    fi
    rm -f "$failed"
    # As mbsync saves a state: the new one as .mbsyncstate.new, renamed over the state (one step; with .new gone the
    # journal is no longer replayed), then the journal set aside. A kill before the rename leaves state and journal
    # as they were. Outside the snapshots; only the last journal per folder is kept.
    mv "$tmp" "$state.new" || { rm -f "$tmp"; return 1; }
    mv "$state.new" "$state" || return 1
    backup="$JOURNAL_BACKUP_DIR/$box.journal"
    mkdir -p "$(dirname "$backup")" && mv "$journal" "$backup" || rm -f "$journal"
    log "mbsync: checkpoint of $box: MaxPulledUid $old -> $new, $pairs letters recorded; the next attempt goes on from there"
}


# add_unfetchable <folder> <file with UIDs> : adds those letters of the folder to UNFETCHABLE_LIST unless listed.
add_unfetchable() {
    local now tmp

    [[ -s "$2" ]] || return 0
    now="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    tmp="$(mktemp "$STATE_DIR/new.tmp.XXXXXX")" || return 1
    touch "$UNFETCHABLE_LIST" || return 1
    BOX="$1" gawk -F'\t' -v OFS='\t' -v now="$now" '
        FILENAME == ARGV[1] { seen[$1 FS $2] = 1; print; next }
        !((ENVIRON["BOX"] FS $1) in seen) { print ENVIRON["BOX"], $1, now, now, 1 }
    ' "$UNFETCHABLE_LIST" "$2" | sort -t "$(printf '\t')" -k1,1 -k2,2n >"$tmp" || return 1
    mv "$tmp" "$UNFETCHABLE_LIST"
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

    # A letter a checkpoint listed in this run already has its first attempt counted.
    gawk -F'\t' -v OFS='\t' -v now="$now" -v runstart="${RUN_START_ISO:-}" -v maildir="$MAILDIR" -v rec="$recovered" '
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
        ($1 FS $2) in seen { $4 = now; if ($3 < runstart || runstart == "") $5++; print; delete seen[$1 FS $2]; next }
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
    local out

    # A restic killed earlier (out of memory, a container stop) leaves its lock behind, and an exclusive one (prune)
    # makes every later run fail. We hold the run lock, so no restic of ours works now; restic unlock removes only
    # stale locks (an older one or a dead process on this host), not those of a live restic started by hand.
    if out="$(restic unlock 2>&1)"; then
        [[ "$out" != *"successfully removed 0 locks"* && -n "$out" ]] && log "restic: $out (left by a killed restic)"
    else
        log "restic: unlock failed: $out"
    fi
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
    local counts folders

    # One walk of the Maildir for all numbers (letters: files in cur/ and new/; bytes: all files). Per folder, into
    # mail_backup_folders.prom: letters here, on the server (FOLDER_COUNTS), refused (UNFETCHABLE_LIST), parked.
    folders="$(mktemp /tmp/folders.prom.XXXXXX)" || folders=/dev/null
    # find fails when a file goes away during the walk (mbsync moving tmp/ to new/): the counts still stand.
    counts="$({ find "$MAILDIR" -type f -printf '%s %h\n' 2>/dev/null || true; } \
        | gawk -v md="$MAILDIR/" -v out="$folders" -v counts="$FOLDER_COUNTS" -v refused="$UNFETCHABLE_LIST" -v parked="$PARKED_LIST" '
            function label(s) { gsub(/\\/, "\\\\", s); gsub(/"/, "\\\"", s); gsub(/\n/, "\\n", s); return s }
            {
                b += $1
                d = substr($0, index($0, " ") + 1)
                if (d ~ /\/(cur|new)$/) {
                    n++
                    f = substr(d, length(md) + 1, length(d) - length(md) - 4)
                    if (substr(d, 1, length(md)) == md) { here[f]++; seen[f] = 1 }
                }
            }
            END {
                FS = "\t"
                while ((getline line < counts) > 0) { split(line, a, "\t"); server[a[1]] = a[2]; seen[a[1]] = 1 }
                while ((getline line < refused) > 0) { split(line, a, "\t"); ref[a[1]]++; seen[a[1]] = 1 }
                while ((getline line < parked) > 0) if (line != "") { park[line] = 1; seen[line] = 1 }
                print "# HELP mail_backup_folder_letters Letters of the folder in the Maildir copy now." > out
                print "# TYPE mail_backup_folder_letters gauge" > out
                for (f in seen) printf "mail_backup_folder_letters{folder=\"%s\"} %d\n", label(f), here[f] > out
                print "# HELP mail_backup_folder_server_messages Letters of the folder on the server at the start of the last run (IMAP STATUS)." > out
                print "# TYPE mail_backup_folder_server_messages gauge" > out
                for (f in server) printf "mail_backup_folder_server_messages{folder=\"%s\"} %d\n", label(f), server[f] > out
                print "# HELP mail_backup_folder_refused Refused letters of the folder in the list for retry." > out
                print "# TYPE mail_backup_folder_refused gauge" > out
                for (f in seen) printf "mail_backup_folder_refused{folder=\"%s\"} %d\n", label(f), ref[f] > out
                print "# HELP mail_backup_folder_parked 1 if the folder is parked (left out of mbsync)." > out
                print "# TYPE mail_backup_folder_parked gauge" > out
                for (f in seen) printf "mail_backup_folder_parked{folder=\"%s\"} %d\n", label(f), (f in park) > out
                close(out)
                print n + 0, b + 0
            }')" || counts=""
    if [[ "$folders" != /dev/null ]]; then
        [[ -n "$counts" ]] && write_prom mail_backup_folders.prom <"$folders" || true
        rm -f "$folders"
    fi
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
    RUN_START_ISO="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    check_settings
    # The current run's start, for a dashboard showing how long a running backup takes. Microseconds: compared with
    # the previous run's end, which may fall in the same second.
    write_prom mail_backup_run.prom <<EOF || true
# HELP mail_backup_run_started_timestamp_seconds When the last (or the running) backup run started.
# TYPE mail_backup_run_started_timestamp_seconds gauge
mail_backup_run_started_timestamp_seconds ${EPOCHREALTIME/,/.}
EOF
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
