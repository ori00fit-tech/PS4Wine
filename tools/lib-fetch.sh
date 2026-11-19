# WinePS4 Enhanced: fetch(), sourced by tools/build-sysroot.sh and tools/compare-pkg.sh. Needs DL (the download folder)
# and DL_LOG (downloads.tsv) set by the script that sources it.
# fetch <file> <sha256> <url> [fallback url ...]: download once, checked against the pinned sha256. Every attempt is
# recorded in $PSB/logs/downloads.tsv (file, url, attempt, result, curl exit code, seconds): which mirror was used,
# how many retries it took, which ones failed (tools/build-manifest.sh reports them).
mkdir -p "$DL" "$(dirname "$DL_LOG")"; [ -f "$DL_LOG" ] || printf 'file\turl\tattempt\tresult\tcurl_exit\tseconds\n' > "$DL_LOG"
fetch() {
    local file="$1" sum="$2" url attempt rc t0; shift 2
    if [ -s "$DL/$file" ] && echo "$sum  $DL/$file" | sha256sum -c --status -; then
        printf '%s\t%s\t0\tcached\t0\t0\n' "$file" "-" >> "$DL_LOG"; return 0
    fi
    for url in "$@"; do
        for attempt in 1 2 3; do
            t0=$(date +%s); rc=0
            curl -sSfL --connect-timeout 30 --max-time 1800 -o "$DL/$file.part" "$url" || rc=$?
            if [ $rc = 0 ] && echo "$sum  $DL/$file.part" | sha256sum -c --status -; then
                mv -f "$DL/$file.part" "$DL/$file"
                printf '%s\t%s\t%s\tok\t0\t%s\n' "$file" "$url" "$attempt" $(( $(date +%s) - t0 )) >> "$DL_LOG"
                echo "fetched $file from $url (attempt $attempt), sha256 OK"; return 0
            fi
            [ $rc = 0 ] && rc=sha256
            printf '%s\t%s\t%s\tfailed\t%s\t%s\n' "$file" "$url" "$attempt" "$rc" $(( $(date +%s) - t0 )) >> "$DL_LOG"
            echo "download of $file from $url failed (attempt $attempt: $rc)" >&2
            rm -f "$DL/$file.part"; [ "$rc" = sha256 ] && break; sleep 5
        done
    done
    echo "no mirror gave $file with sha256 $sum" >&2; return 1
}
