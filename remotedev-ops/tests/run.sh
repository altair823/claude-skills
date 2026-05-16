#!/usr/bin/env bash
# tests/run.sh — run every tests/test_*.sh. Each prints its own tally;
# this aggregates exit codes.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
rc=0
for t in "$DIR"/test_*.sh; do
  echo "== ${t##*/} =="
  bash "$t" || rc=1
done
exit $rc
