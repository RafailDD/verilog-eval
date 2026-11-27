#!/usr/bin/env bash
# selfcheck.sh [task] — feed each problem's reference solution in as the "DUT"
# and run it exactly like the harness does. Any problem listed as FAIL here
# can't be passed by any model on your iverilog build; it caps the max score.
# Requires: bash, iverilog 12.x or 13.x, timeout.
set -uo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
task="${1:-spec-to-rtl}"
ds="$REPO/dataset_$task"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
fails=(); n=0
while read -r p; do
  [[ -z "$p" ]] && continue
  n=$((n+1))
  sed 's/RefModule/TopModule/' "$ds/${p}_ref.sv" > "$tmp/dut.sv"
  log="$tmp/$p.log"
  if iverilog -Wall -Winfloop -Wno-timescale -g2012 -s tb -o "$tmp/sim" \
       "$tmp/dut.sv" "$ds/${p}_test.sv" "$ds/${p}_ref.sv" >"$log" 2>&1 \
     && (cd "$tmp" && timeout 30 ./sim >>"$log" 2>&1) \
     && grep -q '^Mismatches: 0 in' "$log" && ! grep -q 'TIMEOUT' "$log"; then
    :
  else
    fails+=("$p")
  fi
done < "$ds/problems.txt"
echo "$task: $((n-${#fails[@]}))/$n reference solutions pass the harness check"
for f in "${fails[@]}"; do echo "  FAIL $f"; done
