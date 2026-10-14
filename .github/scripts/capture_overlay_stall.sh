#!/usr/bin/env bash
# Diagnostic only: sample the actual app once after XCTest reports missing idle.
set -u
log="$1"
output="$2"
stop="$3"
mkdir -p "$output"
while [[ ! -e "$stop" ]]; do
  if [[ -f "$log" ]] && grep -Fq 'App event loop idle notification not received' "$log"; then
    date -u > "$output/observed-at.txt"
    pgrep -x ZenAgent > "$output/app-pids.txt" || true
    while read -r app_pid; do
      [[ "$app_pid" =~ ^[0-9]+$ ]] || continue
      /usr/bin/sample "$app_pid" 2 -file "$output/app-$app_pid.sample.txt" \
        > "$output/app-$app_pid.sample-command.txt" 2>&1 || true
    done < "$output/app-pids.txt"
    exit 0
  fi
  sleep 1
done
