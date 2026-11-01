#!/usr/bin/env bash
# Runs encbench synth once per line of option sets on stdin (or the file given), printing the summary
# lines. Usage: ./sweep.sh [seconds] < options.txt
set -u
cd "$(dirname "$0")"
secs=${1:-4}
bin=./target/release/encbench
while IFS= read -r line; do
    [[ -z "$line" || "$line" == \#* ]] && continue
    echo "== $line"
    # shellcheck disable=SC2086
    "$bin" synth --seconds "$secs" $line 2>&1 | grep -E 'loadavg|run:|cpu:|encode \(|push →|AU size|forced IDR|IRAP|sequence|^(Normal|Idr|Refine):|STALL|panicked'
done
