#!/usr/bin/env python3
"""Turns an xcodebuild log into GitHub annotations and a step summary, so failures are readable from the API.
Usage: ci-report.py <log> [exit-status]"""
import os, re, sys

path = sys.argv[1]
status = int(sys.argv[2]) if len(sys.argv) > 2 else 0
raw = open(path, errors="replace").read().splitlines()
lines = [re.sub(r"^\S+T\S+Z ", "", ln).rstrip() for ln in raw]
patterns = re.compile(r"(error|Error|ERROR|Test Case .* (failed|passed)|Executed \d+ tests|Fatal|crash|\*\* (TEST|BUILD)|Assertion|XCTAssert|unexpected exit|Unable to|failed|Failed|Timed out|xctest)")
noise = re.compile(r"(warning:|note:|^\s*$|CompileSwift|SwiftCompile|Ld |ProcessInfoPlist|-- )")
keep = []
for ln in lines:
    if patterns.search(ln) and not noise.search(ln):
        keep.append(ln.strip()[:600])
seen, uniq = set(), []
for ln in keep:
    if ln not in seen:
        seen.add(ln); uniq.append(ln)

errors = [l for l in uniq if re.search(r"(error|Error|ERROR|failed|Failed|Fatal|crash|unexpected exit|Unable to|Timed out)", l)]
summary = [l for l in uniq if "Executed" in l or "** TEST" in l or "** BUILD" in l]
passed = sum(1 for l in uniq if "Test Case" in l and " passed" in l)
failed = sum(1 for l in uniq if "Test Case" in l and " failed" in l)

for ln in errors[:40]:
    m = re.match(r"(/[^:]+):(\d+):(\d+): error: (.*)", ln)
    if m:
        f = os.path.relpath(m.group(1), os.getcwd()) if m.group(1).startswith(os.getcwd()) else m.group(1)
        print(f"::error file={f},line={m.group(2)},col={m.group(3)}::{m.group(4)}")
    else:
        print(f"::error::{ln}")
for ln in summary[-6:]:
    print(f"::notice::{ln}")
print(f"::notice::test cases passed={passed} failed={failed} status={status}")
if status != 0:
    tail = [l for l in lines if l.strip()][-45:]
    for i in range(0, len(tail), 5):
        print("::error::TAIL " + " ⏎ ".join(t[:160] for t in tail[i:i + 5]))

if os.environ.get("GITHUB_STEP_SUMMARY"):
    with open(os.environ["GITHUB_STEP_SUMMARY"], "a") as fh:
        fh.write("### xcodebuild report\n\n```\n" + "\n".join(errors[:80] + summary) + "\n```\n")
print(f"report: {len(errors)} error lines, {len(summary)} summary lines, passed={passed} failed={failed}", file=sys.stderr)
