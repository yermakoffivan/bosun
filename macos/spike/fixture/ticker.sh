#!/bin/bash
# Continuous-output stand-in for a busy agent: spinner + timestamp line, ~5 times a second.
frames='|/-\'
i=0
while true; do
  printf '%s %s  tick %d  %s\n' "${frames:i%4:1}" "$(date +%H:%M:%S)" "$i" "$1"
  i=$((i+1))
  sleep 0.2
done
