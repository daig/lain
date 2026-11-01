#!/usr/bin/env bash
# Runs vaenc once per line of option sets on stdin, printing the summary lines.
# Usage: ./vaenc-sweep.sh [seconds] < options.txt
set -u
cd "$(dirname "$0")"
secs=${1:-4}
while IFS= read -r line; do
    [[ -z "$line" || "$line" == \#* ]] && continue
    echo "== $line"
    # shellcheck disable=SC2086
    ./vaenc/vaenc --seconds "$secs" $line 2>&1 | grep -E 'loadavg|run:|normal:|AU mean|IDR|refine|sequence|failed'
done
