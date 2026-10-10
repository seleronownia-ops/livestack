#!/usr/bin/env python3
"""Turns an xcodebuild log into GitHub annotations and a step summary, so failures are readable from the API."""
import os, re, sys

path = sys.argv[1]
lines = open(path, errors="replace").read().splitlines()
keep = []
patterns = re.compile(r"(error:|Test Case .* (failed|passed)|Executed \d+ tests|Fatal error|crashed|\*\* TEST|Assertion|XCTAssert|Restarting after unexpected exit|Timed out)")
for ln in lines:
    ln = re.sub(r"^\S+T\S+Z ", "", ln)  # strip the runner timestamp
    if patterns.search(ln) and "warning:" not in ln:
        keep.append(ln.strip()[:600])

# compress: one line per unique message, keep order
seen, uniq = set(), []
for ln in keep:
    if ln not in seen:
        seen.add(ln); uniq.append(ln)

errors = [l for l in uniq if "error:" in l or "failed" in l or "Fatal" in l or "crashed" in l]
summary = [l for l in uniq if "Executed" in l or "** TEST" in l]

for ln in errors[:40]:
    m = re.match(r"(/[^:]+):(\d+):(\d+): error: (.*)", ln)
    if m:
        f = os.path.relpath(m.group(1), os.getcwd()) if m.group(1).startswith(os.getcwd()) else m.group(1)
        print(f"::error file={f},line={m.group(2)},col={m.group(3)}::{m.group(4)}")
    else:
        print(f"::error::{ln}")
for ln in summary[-6:]:
    print(f"::notice::{ln}")

if os.environ.get("GITHUB_STEP_SUMMARY"):
    with open(os.environ["GITHUB_STEP_SUMMARY"], "a") as fh:
        fh.write("### xcodebuild report\n\n```\n" + "\n".join(errors[:80] + summary) + "\n```\n")
print(f"report: {len(errors)} error lines, {len(summary)} summary lines", file=sys.stderr)
