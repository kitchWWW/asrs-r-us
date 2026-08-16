#!/usr/bin/env python3
"""Scores the rewrite prompt against the hand-corrected transcripts.

The gold set is the answer key: every case carries a real transcript from the
session log and the rewrite Brian settled on by hand. `expected` is the only
column that matters -- `model_output` is a historical record of what the app
produced when the case was labelled, and goes stale the moment the prompt
changes.

Usage:
    python3 Evals/score.py                     # local llama-server, the app's default
    python3 Evals/score.py --engine bedrock    # Sonnet 5 through the AWS CLI
    python3 Evals/score.py --prompt old.txt    # score a prompt held in a file
    python3 Evals/score.py --all               # include cases not yet labelled

Only cases marked `approved` in the set are scored; `pending` ones have not
been reviewed yet, and `excluded` ones were thrown out as unfair tests.
"""

import argparse
import difflib
import json
import os
import re
import subprocess
import sys
import tempfile
import urllib.request

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
GOLD = os.path.join(ROOT, "Evals", "gold-set.json")
NORMALIZER = os.path.join(ROOT, "Sources", "Editing", "TranscriptNormalizer.swift")
PROFILE = os.path.join(ROOT, "Sources", "Support", "Profile.swift")

TOKEN = re.compile(r"\s+|\w+|[^\w\s]")


# --- the app's own pieces, borrowed ------------------------------------------

def build_tool(source, body, name):
    """Compiles one of the app's Swift files into a throwaway CLI."""
    out = os.path.join(tempfile.mkdtemp(), name)
    main = os.path.join(os.path.dirname(out), "main.swift")
    with open(main, "w") as f:
        f.write(body)
    proc = subprocess.run(["swiftc", "-O", "-o", out, source, main],
                          capture_output=True, text=True)
    if proc.returncode != 0:
        sys.exit(f"could not build {name}:\n{proc.stderr[:600]}")
    return out


NORM_MAIN = """
import Foundation
let data = FileHandle.standardInput.readDataToEndOfFile()
let inputs = try! JSONSerialization.jsonObject(with: data) as! [String]
let out = inputs.map { TranscriptNormalizer.normalize($0) }
FileHandle.standardOutput.write(try! JSONSerialization.data(withJSONObject: out))
"""

PROMPT_MAIN = "import Foundation\nprint(ProfileStore.basePrompt)\n"


def normalize(texts):
    tool = build_tool(NORMALIZER, NORM_MAIN, "norm")
    proc = subprocess.run([tool], input=json.dumps(texts).encode(), capture_output=True)
    return json.loads(proc.stdout)


def current_prompt():
    tool = build_tool(PROFILE, PROMPT_MAIN, "prompt")
    return subprocess.run([tool], capture_output=True, text=True).stdout


def user_turn(transcript):
    """The user message RewriteService.buildUserMessage assembles."""
    return (f"Live dictation transcript:\n<transcript>\n{transcript}\n</transcript>\n\n"
            "Rewrite the transcript. Output only the rewritten text.")


# --- engines ------------------------------------------------------------------

def run_local(system, text, port=8080):
    body = {
        "messages": [{"role": "system", "content": system},
                     {"role": "user", "content": user_turn(text)}],
        "temperature": 0, "max_tokens": 1200, "stream": False,
    }
    req = urllib.request.Request(f"http://127.0.0.1:{port}/v1/chat/completions",
                                 data=json.dumps(body).encode(),
                                 headers={"Content-Type": "application/json"})
    reply = json.load(urllib.request.urlopen(req, timeout=300))
    return reply["choices"][0]["message"]["content"].strip()


def run_bedrock(system, text, model="us.anthropic.claude-sonnet-5",
                region="us-east-1", profile="personal"):
    body = {
        "anthropic_version": "bedrock-2023-05-31", "max_tokens": 1200,
        # Matches BedrockClient: thinking off, since the rewrite never shows it.
        "thinking": {"type": "disabled"},
        "system": [{"type": "text", "text": system}],
        "messages": [{"role": "user", "content": user_turn(text)}],
    }
    tmp = tempfile.mkdtemp()
    req_path, out_path = os.path.join(tmp, "req.json"), os.path.join(tmp, "out.json")
    with open(req_path, "w") as f:
        json.dump(body, f)
    proc = subprocess.run(
        ["aws", "bedrock-runtime", "invoke-model", "--profile", profile,
         "--region", region, "--model-id", model, "--body", f"fileb://{req_path}",
         "--cli-binary-format", "raw-in-base64-out", out_path],
        capture_output=True, text=True)
    if proc.returncode != 0:
        sys.exit(f"bedrock call failed:\n{proc.stderr[:400]}")
    with open(out_path) as f:
        reply = json.load(f)
    return "".join(b.get("text", "") for b in reply["content"]).strip()


# --- scoring ------------------------------------------------------------------

def tokens(s):
    return [t for t in TOKEN.findall(s or "") if not t.isspace()]


def similarity(expected, got):
    """Token overlap, 0-1. Partial credit so a near-miss is not a zero."""
    return difflib.SequenceMatcher(None, tokens(expected), tokens(got),
                                   autojunk=False).ratio()


def diff_line(expected, got, limit=5):
    a, b = TOKEN.findall(got or ""), TOKEN.findall(expected or "")
    sm = difflib.SequenceMatcher(None, a, b, autojunk=False)
    parts = []
    for tag, i1, i2, j1, j2 in sm.get_opcodes():
        if tag == "equal":
            continue
        mine, want = "".join(a[i1:i2]), "".join(b[j1:j2])
        parts.append(f"{mine.strip()!r}→{want.strip()!r}")
    extra = len(parts) - limit
    shown = " ".join(parts[:limit])
    return shown + (f" (+{extra} more)" if extra > 0 else "")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--engine", choices=["local", "bedrock"], default="local")
    ap.add_argument("--prompt", help="score a prompt from a file instead of the source")
    ap.add_argument("--all", action="store_true", help="include unlabelled cases")
    ap.add_argument("--gold", default=GOLD)
    args = ap.parse_args()

    gold = json.load(open(args.gold))
    cases = [c for c in gold["cases"]
             if args.all or c.get("status") == "approved"]
    if not cases:
        sys.exit("no labelled cases in the set yet")

    system = open(args.prompt).read() if args.prompt else current_prompt()
    # Re-normalize rather than trusting the stored copy: the normalizer is part
    # of what is under test, and the stored text was produced by an older one.
    fresh = normalize([c["transcript"] for c in cases])

    runner = run_local if args.engine == "local" else run_bedrock
    exact, total = 0, 0.0
    rows = []
    for case, text in zip(cases, fresh):
        got = runner(system, text)
        want = case["expected"]
        score = similarity(want, got)
        hit = got.strip() == want.strip()
        exact += hit
        total += score
        rows.append((case["id"], hit, score, diff_line(want, got), got))

    rows.sort(key=lambda r: r[2])
    print(f"\n{args.engine} · {len(cases)} cases · prompt "
          f"{'from ' + args.prompt if args.prompt else 'from Profile.swift'}\n")
    for cid, hit, score, diff, _ in rows:
        flag = "PASS" if hit else "    "
        print(f"{flag} {cid:5} {score:5.0%}  {diff}")
    print(f"\nexact matches {exact}/{len(cases)} · mean similarity {total/len(cases):.1%}")

    out = os.path.join(ROOT, "Evals", f"last-run-{args.engine}.json")
    with open(out, "w") as f:
        json.dump([{"id": r[0], "exact": r[1], "similarity": r[2], "got": r[4]}
                   for r in rows], f, indent=1)
    print(f"outputs written to {os.path.relpath(out, ROOT)}")


if __name__ == "__main__":
    main()
