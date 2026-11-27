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
# Problems known to fail with the reference answer itself (iverilog 12.0 and
# 13.0): Prob099 spec-to-rtl has wrong ports; 082/141/156 hit the
# testbench's own time limit. These cap the best possible score.
case "$task" in
  spec-to-rtl)             known="Prob082_lfsr32 Prob099_m2014_q6c Prob141_count_clock Prob156_review2015_fancytimer" ;;
  code-complete-iccad2023) known="Prob082_lfsr32 Prob141_count_clock Prob156_review2015_fancytimer" ;;
  *)                       known="" ;;
esac
pass=$((n-${#fails[@]}))
echo "$task: $pass/$n reference solutions pass -> best possible score $pass/$n"
unexpected=0
for f in "${fails[@]}"; do
  if [[ " $known " == *" $f "* ]]; then
    echo "  known-bad $f"
  else
    echo "  UNEXPECTED $f"; unexpected=1
  fi
done
if [[ $unexpected == 0 ]]; then
  echo "OK: matches the expected result, your setup is fine."
else
  echo "WARNING: failures beyond the known list; check your iverilog setup."
  exit 1
fi
