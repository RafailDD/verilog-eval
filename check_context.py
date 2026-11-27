#!/usr/bin/env python3
"""check_context.py [runs_dir] — did any result suffer from truncation?

Reads every *-sv-generate.log written by the patched sv-generate and, per run,
reports:
  max_prompt   largest prompt actually processed by Ollama (tokens)
  ctx_hit      prompt+answer reached num_ctx -> input may have been cut off
  len_hit      answer stopped at max_tokens (done_reason=length) -> cut-off answer
  no_code      nothing usable extracted (no 'endmodule' in the sample)
  no_counts    Ollama returned no token counts (can't verify these samples)
  fail_by_trunc  failed samples that also have ctx_hit or len_hit
  fail_no_code   failed samples with no_code but no truncation: the model
                 answered, but not in a form the harness could extract

If fail_by_trunc is 0, no failure in that run can be blamed on context size.
Writes runs/context_check.csv with one row per flagged sample.
Requires only Python 3 (no extra packages).
"""
import csv, glob, os, re, sys

runs = sys.argv[1] if len(sys.argv) > 1 else os.path.join(os.path.dirname(os.path.abspath(__file__)), "runs")

def num(pat, text, default=None):
    m = re.search(pat, text, re.M)
    return m.group(1) if m else default

flagged, summary = [], []
for d in sorted(glob.glob(os.path.join(runs, "*_n*"))):
    if not os.path.isdir(d):
        continue
    status = {}
    sc = os.path.join(d, "summary.csv")
    if os.path.exists(sc):
        with open(sc) as f:
            for row in csv.reader(f):
                if len(row) > 4 and row[0].startswith("Prob"):
                    for i, code in enumerate(row[4].strip()):
                        status[(row[0], i + 1)] = code
    st = dict(n=0, max_prompt=0, ctx_hit=0, len_hit=0, no_code=0, no_counts=0, fail_by_trunc=0,
              fail_no_code=0)
    for log in glob.glob(os.path.join(d, "Prob*", "*-sv-generate.log")):
        txt = open(log, errors="replace").read()
        m = re.search(r"(Prob\d+_\w+?)_sample(\d+)-sv-generate\.log$", os.path.basename(log))
        prob, smp = m.group(1), int(m.group(2))
        sv = log.replace("-sv-generate.log", ".sv")
        code = open(sv, errors="replace").read() if os.path.exists(sv) else ""
        pt = int(num(r"^prompt_tokens = (\d+)", txt, 0))
        rt = int(num(r"^resp_tokens\s+= (\d+)", txt, 0))
        reason = num(r"^done_reason\s+= (\S+)", txt, "unknown")
        ctx = num(r"^num_ctx\s+= (\d+)", txt)
        mx = int(num(r"^max_tokens\s+= (\d+)", txt, 0))
        st["n"] += 1
        st["max_prompt"] = max(st["max_prompt"], pt)
        flags = []
        if pt == 0:
            st["no_counts"] += 1; flags.append("no_counts")
        if ctx and pt and pt + rt >= int(ctx) - 8:
            st["ctx_hit"] += 1; flags.append("ctx_hit")
        if reason == "length" or (mx and rt >= mx):
            st["len_hit"] += 1; flags.append("len_hit")
        if "endmodule" not in code:
            st["no_code"] += 1; flags.append("no_code")
        res = status.get((prob, smp), "?")
        trunc = any(f in flags for f in ("ctx_hit", "len_hit"))
        if res != ".":
            if trunc:
                st["fail_by_trunc"] += 1
            elif "no_code" in flags:
                st["fail_no_code"] += 1
        if flags:
            flagged.append(dict(run=os.path.basename(d), problem=prob, sample=smp, result=res,
                                prompt_tokens=pt, resp_tokens=rt, done_reason=reason,
                                num_ctx=ctx, max_tokens=mx, flags="+".join(flags)))
    if st["n"]:
        summary.append((os.path.basename(d), st))

print("\nContext / truncation check")
print("%-52s %5s %10s %7s %7s %7s %9s %13s %12s" % ("run", "n", "max_prompt", "ctx_hit", "len_hit",
      "no_code", "no_counts", "fail_by_trunc", "fail_no_code"))
for name, s in summary:
    print("%-52s %5d %10d %7d %7d %7d %9d %13d %12d" % (name, s["n"], s["max_prompt"], s["ctx_hit"],
          s["len_hit"], s["no_code"], s["no_counts"], s["fail_by_trunc"], s["fail_no_code"]))
out = os.path.join(runs, "context_check.csv")
with open(out, "w", newline="") as f:
    w = csv.DictWriter(f, fieldnames=["run", "problem", "sample", "result", "prompt_tokens",
                                      "resp_tokens", "done_reason", "num_ctx", "max_tokens", "flags"])
    w.writeheader(); w.writerows(flagged)
print(f"\nFlagged samples listed in: {out}")
if any(s["fail_by_trunc"] for _, s in summary):
    print("Some failures coincide with truncation: raise OLLAMA_NUM_CTX / VEVAL_MAX_TOKENS and rerun those.")
else:
    print("No failure is due to context size or the answer cap.")
if any(s["fail_no_code"] for _, s in summary):
    print("fail_no_code > 0: the model answered but no Verilog module could be extracted "
          "(format problem, not truncation). See the *-sv-generate.log of the samples in the csv.")
