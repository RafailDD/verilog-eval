#!/usr/bin/env bash
#=========================================================================
# run_local.sh — run VerilogEval v2 against local Ollama models, unattended
#=========================================================================
#
# Usage:
#   ./run_local.sh qwen2.5-coder:7b llama3.1:8b deepseek-coder-v2:16b
#
# Requires (checked before anything runs) — nothing to pip/apt install:
#   - bash, make, timeout, curl
#   - python3 (standard library only)
#   - iverilog 12.x or 13.x
#   - Ollama running (default http://localhost:11434); the `ollama` CLI only
#     if a model still has to be pulled
#   - this branch checked out (patched scripts/sv-generate + testbench fix)
#
# Settings (environment variables, defaults shown):
#   TASK=spec-to-rtl      or code-complete-iccad2023, or "spec-to-rtl code-complete-iccad2023"
#   SHOTS="0 1"           in-context examples to sweep (0..4)
#   SAMPLES=1 TEMPERATURE=0 TOP_P=0.01   paper's low-temperature setting
#                         (high-temp setting: SAMPLES=20 TEMPERATURE=0.85 TOP_P=0.95)
#   QUICK=0               QUICK=1 runs only the first 20 problems (smoke test)
#   JOBS=1                parallel make jobs (raise only if OLLAMA_NUM_PARALLEL>1)
#   OLLAMA_HOST=http://localhost:11434
#   OLLAMA_NUM_CTX=8192   context window forced on every request
#   VEVAL_THINK=off       off|on|default — reasoning mode for thinking models
#   VEVAL_MAX_TOKENS=1024 raise (e.g. 8192) if you set VEVAL_THINK=on
#   AUTO_PULL=1           `ollama pull` missing models automatically
#
# Output:
#   runs/<task>_<model>_shots<N>_n<S>/   per-run samples, logs, summary.txt/csv
#   runs/results.csv                     one line per run, with failure categories
#
# Interrupted? Just rerun the same command: finished samples are kept (make).
#=========================================================================

set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUNS="$REPO/runs"

TASK="${TASK:-spec-to-rtl}"
SHOTS="${SHOTS:-0 1}"
SAMPLES="${SAMPLES:-1}"
TEMPERATURE="${TEMPERATURE:-0}"
TOP_P="${TOP_P:-0.01}"
QUICK="${QUICK:-0}"
JOBS="${JOBS:-1}"
AUTO_PULL="${AUTO_PULL:-1}"
export OLLAMA_HOST="${OLLAMA_HOST:-http://localhost:11434}"
export OLLAMA_NUM_CTX="${OLLAMA_NUM_CTX:-8192}"
export VEVAL_THINK="${VEVAL_THINK:-off}"
export VEVAL_MAX_TOKENS="${VEVAL_MAX_TOKENS:-1024}"

die() { echo "ERROR: $*" >&2; exit 1; }

[[ $# -ge 1 ]] || die "give at least one Ollama model name, e.g. ./run_local.sh qwen2.5-coder:7b"

#-------------------------------------------------------------------------
# Preflight
#-------------------------------------------------------------------------

for tool in make timeout iverilog vvp python3 curl; do
  command -v "$tool" >/dev/null || die "'$tool' not found on PATH"
done

# (iverilog -V exits non-zero without input files, hence '|| true')
ivline="$( (iverilog -V 2>&1 || true) | head -1)"
ivver="$(sed -n 's/.*version \([0-9]*\).*/\1/p' <<<"$ivline")"
case "$ivver" in
  12) ;;
  13) if grep -q "tb_mismatch ," "$REPO"/dataset_*/*_test.sv; then
        die "iverilog 13 needs the testbench fix (commit \"Make testbenches compile on iverilog 13\")"
      fi ;;
  *)  die "iverilog 12.x or 13.x required, found: $ivline" ;;
esac

# The NVIDIA scripts start with '#!/usr/bin/env python'; many systems only
# have 'python3'. A private shim makes 'python' resolve, without installing.
mkdir -p "$REPO/.shim"
ln -sf "$(command -v python3)" "$REPO/.shim/python"
# configure pipes through 'column -t' (cosmetic alignment only). Where
# 'column' is missing it silently writes no sample count, so SAMPLES>1
# would quietly run 1 sample. A pass-through stand-in avoids that.
if ! command -v column >/dev/null; then
  printf '#!/bin/sh\ncat\n' > "$REPO/.shim/column"; chmod +x "$REPO/.shim/column"
fi
export PATH="$REPO/.shim:$PATH"

grep -q "local-llm patch" "$REPO/scripts/sv-generate" \
  || die "scripts/sv-generate is not patched — run: git apply local-llm.patch"

curl -sf "$OLLAMA_HOST/api/tags" >/dev/null || die "Ollama not reachable at $OLLAMA_HOST"

for m in "$@"; do
  if ! curl -sf "$OLLAMA_HOST/api/tags" | python3 -c "
import json,sys; names={x['name'] for x in json.load(sys.stdin)['models']}
m=sys.argv[1]; sys.exit(0 if (m in names or m+':latest' in names) else 1)" "$m"; then
    if [[ "$AUTO_PULL" == "1" ]]; then
      command -v ollama >/dev/null || die "model $m missing and no 'ollama' CLI to pull it"
      echo ">> pulling $m"; ollama pull "$m" || die "could not pull $m"
    else
      die "model $m not present in Ollama (ollama pull $m)"
    fi
  fi
done

mkdir -p "$RUNS"

#-------------------------------------------------------------------------
# Sweep
#-------------------------------------------------------------------------

for task in $TASK; do
  problems_arg=()
  if [[ "$QUICK" == "1" ]]; then
    head -20 "$REPO/dataset_$task/problems.txt" > "$RUNS/problems_quick_$task.txt"
    problems_arg=(--with-problems="$RUNS/problems_quick_$task.txt")
  fi

  for m in "$@"; do
    for s in $SHOTS; do
      tag="$(echo "$m" | tr '/:' '__')"
      q=""; [[ "$QUICK" == "1" ]] && q="_quick"
      dir="$RUNS/${task}_${tag}_shots${s}_n${SAMPLES}${q}"
      mkdir -p "$dir"
      echo
      echo "=== $task | $m | shots=$s | n=$SAMPLES | T=$TEMPERATURE | ctx=$OLLAMA_NUM_CTX | think=$VEVAL_THINK | iverilog $ivver ==="
      (
        cd "$dir"
        if [[ ! -f Makefile ]]; then
          "$REPO/configure" --with-task="$task" --with-model="ollama/$m" \
            --with-examples="$s" --with-samples="$SAMPLES" \
            --with-temperature="$TEMPERATURE" --with-top-p="$TOP_P" \
            "${problems_arg[@]}" > configure.log 2>&1 \
            || { cat configure.log; exit 1; }
        fi
        grep -q "_num_samples *= *$SAMPLES\b" samples.mk \
          || { echo "ERROR: samples.mk has no sample count ($dir/samples.mk)"; exit 1; }
        # SHELL=/bin/bash matters: the Makefile uses '&>' and '[[ ]]', which
        # silently misbehave under dash (Ubuntu's /bin/sh).
        start=$(date +%s)
        make SHELL=/bin/bash -j"$JOBS" 2>&1 | tail -n 3
        echo "elapsed_s=$(( $(date +%s) - start ))" >> timing.txt
      )
    done
  done
done

#-------------------------------------------------------------------------
# Collect
#-------------------------------------------------------------------------

python3 - "$RUNS" <<'PY'
import csv, glob, os, re, sys
runs = sys.argv[1]
# Failure codes written by scripts/sv-iv-analyze (see count_failures.py)
names = {".": "pass", "S": "syntax_err", "e": "explicit_cast", "0": "sized_zero",
         "n": "no_sens_list", "w": "wire_assign", "m": "unknown_module",
         "p": "unbound_signal", "c": "unbound_clk", "C": "compile_other",
         "T": "timeout", "r": "async_reset_mismatch", "R": "output_mismatch"}
rows = []
for d in sorted(glob.glob(os.path.join(runs, "*_n*"))):
    st, sc = os.path.join(d, "summary.txt"), os.path.join(d, "summary.csv")
    if not os.path.exists(st):
        continue
    m = re.search(r"pass_rate\s*=\s*([\d.]+)", open(st).read())
    counts = {}
    with open(sc) as f:
        for r in csv.reader(f):
            for code in r[4:]:
                for ch in code:
                    counts[ch] = counts.get(ch, 0) + 1
    row = {"run": os.path.basename(d), "pass_rate_%": m.group(1) if m else ""}
    for k, v in names.items():
        row[v] = counts.get(k, 0)
    row["other"] = sum(v for k, v in counts.items() if k not in names)
    rows.append(row)
if rows:
    with open(os.path.join(runs, "results.csv"), "w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=list(rows[0].keys()))
        w.writeheader(); w.writerows(rows)
    print("\n%-58s %8s %6s %7s %7s" % ("run", "pass%", "pass", "compile", "wrong"))
    for r in rows:
        comp = sum(r[k] for k in ("syntax_err","explicit_cast","sized_zero","no_sens_list",
                                  "wire_assign","unknown_module","unbound_signal",
                                  "unbound_clk","compile_other"))
        print("%-58s %8s %6d %7d %7d" % (r["run"], r["pass_rate_%"], r["pass"], comp,
                                          r["output_mismatch"] + r["async_reset_mismatch"] + r["timeout"]))
    print(f"\nWritten: {os.path.join(runs, 'results.csv')}")
PY

# Truncation check (context window / max_tokens)
python3 "$REPO/check_context.py" "$RUNS"
