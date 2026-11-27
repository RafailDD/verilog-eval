# Running VerilogEval against local Ollama models

This branch adds an unattended way to run VerilogEval v2 against local models
served by [Ollama](https://ollama.com), on iverilog 12 or 13, with no Python
packages to install. The NVIDIA dataset and grading are unchanged apart from
one testbench line needed for iverilog 13 (see [What changed](#what-changed)).

## What the benchmark does

VerilogEval is an automated exam for Verilog generation:

1. **156 small hardware tasks** (HDLBits-style: gates, muxes, counters, FSMs,
   an LFSR, a gshare predictor...), each with a human-written reference solution.
2. A script sends each task description to the LLM and saves the Verilog it writes.
3. A testbench simulates the model's `TopModule` next to the reference
   `RefModule` in iverilog on random stimulus and compares outputs cycle by
   cycle. Zero mismatches = pass; otherwise it's labelled as a compile failure
   or wrong output.
4. The score is the percentage of tasks passed (Pass@1).

The same problems come in two formats: `spec-to-rtl` (write the whole module
from a spec) and `code-complete-iccad2023` (complete the body under a given
module header). 0–4 solved examples can be prepended to the prompt.

It works best as a **floor test**: failing these textbook problems means a
model is not useful for RTL work; passing them only earns a harder test
(the problems are public and likely in training data).

## Requirements

Nothing to `pip` or `apt` install. You need:

- `bash`, `make`, `curl`, `timeout`, `git`
- `python3` (standard library only; no `python` command needed)
- `iverilog` 12.x or 13.x, plus its `vvp`
- Ollama running (default `http://localhost:11434`); the `ollama` CLI only if a
  model still has to be pulled

`run_local.sh` checks all of these before it runs anything.

## Quick start

```bash
git clone -b local-llm-ollama https://github.com/RafailDD/verilog-eval.git
cd verilog-eval

./selfcheck.sh                                    # reference solutions vs your iverilog
QUICK=1 SHOTS=0 ./run_local.sh qwen2.5-coder:7b   # 20-problem smoke test
./run_local.sh qwen2.5-coder:7b llama3.1:8b       # full run, 0 and 1 examples
```

Before trusting a run, open a few files under `runs/*/Prob*/` and check the
generated `*_sample01.sv` files look like real Verilog.

Interrupted? Rerun the same command: finished samples are kept.

## Settings

All optional, as environment variables:

| Variable | Default | Meaning |
|---|---|---|
| `TASK` | `spec-to-rtl` | or `code-complete-iccad2023`, or both space-separated |
| `SHOTS` | `"0 1"` | in-context examples to sweep (0–4) |
| `SAMPLES` / `TEMPERATURE` / `TOP_P` | `1` / `0` / `0.01` | paper's low-temperature setting; high-temperature is `20` / `0.85` / `0.95` |
| `QUICK` | `0` | `1` = first 20 problems only |
| `JOBS` | `1` | parallel requests; raise only if Ollama serves requests in parallel |
| `OLLAMA_HOST` | `http://localhost:11434` | |
| `OLLAMA_NUM_CTX` | `8192` | context window sent with every request |
| `VEVAL_THINK` | `off` | `off` / `on` / `default` for thinking models |
| `VEVAL_MAX_TOKENS` | `1024` | answer cap; raise (e.g. 8192) with `VEVAL_THINK=on` |
| `AUTO_PULL` | `1` | `ollama pull` missing models |

## Output

- `runs/<task>_<model>_shots<N>_n<S>/`: per-task prompts, answers, simulation
  logs, `summary.txt` / `summary.csv`
- `runs/results.csv`: one row per run, with pass % and failure categories
  (syntax error, other compile errors, timeout, output mismatch, ...)
- `runs/context_check.csv`: samples flagged by the truncation check

At the end of each run two tables are printed: the scores, then the
truncation check.

### Score ceiling

Some reference solutions fail the harness's own check, so no model can pass
them. On both iverilog 12.0 and 13.0:

- `spec-to-rtl`: **152/156** (Prob082, 099, 141, 156)
- `code-complete-iccad2023`: **153/156** (Prob082, 141, 156)

Prob099's spec-to-rtl reference has the wrong ports; the other three hit the
testbench's own time limit. `./selfcheck.sh <task>` recomputes the list on
your iverilog: it prints `known-bad` for these and ends with
`OK: matches the expected result`. Any problem marked `UNEXPECTED`
points to a setup issue.

### Is a failure caused by context size?

The prompts are small: about 260 tokens typical and ~1,060 max with 0
examples, ~2,560 max with 4 examples. Reference answers are at most ~560
tokens. Everything fits well inside 8K. The real risk is the answer
cap (`VEVAL_MAX_TOKENS`) cutting off chatty or thinking models.

`check_context.py` (run automatically, or on its own) reads the token counts
and stop reason Ollama returned for every request:

| Column | Meaning |
|---|---|
| `max_prompt` | largest prompt Ollama processed (its own token count) |
| `ctx_hit` | prompt + answer reached `num_ctx`: input may have been cut |
| `len_hit` | answer stopped at the cap (`done_reason=length`) |
| `no_code` | no usable module extracted |
| `no_counts` | Ollama returned no counts: can't verify those samples |
| `fail_by_trunc` | failures that also have one of the flags above |

If `fail_by_trunc` is 0, no failure in that run is due to context or length.

## iverilog 12 vs 13

The upstream README says iverilog 13 is unsupported. With the testbench fix on
this branch, reference results are identical on 12.0 and 13.0
(devel, `s20251012-44-g44611f830`). One difference remains for model answers:
code that uses a signal before declaring it compiles on 12 but not on 13
(13 follows the standard). Scores on 13 can therefore be slightly lower than
published 12 numbers; comparing models against each other on the same
iverilog is unaffected.

## What changed

| File | Change |
|---|---|
| `scripts/sv-generate` | `ollama/<model>` backend using only the Python standard library; sends `num_ctx` / thinking mode / answer cap; strips `<think>` text; logs token counts and `done_reason`; langchain imports made optional (langchain 1.x removed `langchain.schema`) |
| `scripts/sv-iv-analyze` | removed an unused import that crashes on langchain 1.x |
| `dataset_*/*_test.sv` | removed `tb_mismatch` from `$dumpvars`: it is used before being declared, which iverilog 13 rejects. Affects the waveform dump only, not grading |
| `run_local.sh` | new: preflight checks, model × shots sweep, `make SHELL=/bin/bash` (the Makefile breaks under dash), fallbacks for missing `python` / `column`, results table |
| `selfcheck.sh` | new: runs the reference solutions through the harness to find the score ceiling |
| `check_context.py` | new: truncation check |

The original OpenAI / NVIDIA NIM paths still work if their langchain packages
are installed; see the main [README](README.md).
