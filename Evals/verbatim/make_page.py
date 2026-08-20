#!/usr/bin/env python3
"""Builds the comparison page from the benchmark results.

Rows are recordings, columns are recognisers, and every word a recogniser
disagreed with Apple about is highlighted. The diff is computed on normalised
words (case and punctuation stripped) but rendered over the original text, so
an invented comma shows up where it was actually inserted.
"""

import base64
import difflib
import html
import json
import os
import re

ROOT = os.path.dirname(os.path.abspath(__file__))

ENGINES = [
    ("apple",                 "Apple SpeechTranscriber", "incumbent"),
    ("nemo-conformer-80ms",   "NeMo FastConformer 80 ms", "streaming"),
    ("nemo-conformer-1040ms", "NeMo FastConformer 1040 ms", "streaming"),
    ("vosk-0.22",             "Vosk en-us 0.22", "streaming"),
    ("vosk-small",            "Vosk small en-us", "streaming"),
    ("zipformer-en",          "Zipformer en", "streaming"),
    ("zipformer-20M",         "Zipformer 20M", "streaming"),
    ("whisper-small.en",      "Whisper small.en", "not streaming"),
]

SPOKEN_RE = re.compile(
    r"\b(colons?|colin|collin|periods?|commas?|question mark|exclamation point|"
    r"open parenthes[ei]s|close[d]? parenthes[ei]s|open quote|close quote|"
    r"new paragraph|new line|semicolons?)\b", re.I)


def norm(w):
    return re.sub(r"[^a-z0-9']", "", w.lower())


def tokens(text):
    return re.findall(r"\S+", text or "")


def diff_html(ref_text, hyp_text):
    """Render hyp with words that differ from ref highlighted."""
    ref, hyp = tokens(ref_text), tokens(hyp_text)
    rn, hn = [norm(w) for w in ref], [norm(w) for w in hyp]
    sm = difflib.SequenceMatcher(a=rn, b=hn, autojunk=False)
    parts = []
    for tag, i1, i2, j1, j2 in sm.get_opcodes():
        chunk = hyp[j1:j2]
        if not chunk:
            continue
        text = html.escape(" ".join(chunk))
        text = SPOKEN_RE.sub(lambda m: f"<b>{m.group(0)}</b>", text)
        parts.append(text if tag == "equal" else f'<mark>{text}</mark>')
    return " ".join(parts)


def load(engine):
    p = os.path.join(ROOT, f"results-{engine}.json")
    if not os.path.exists(p):
        return None
    return json.load(open(p))


def main():
    cases = json.load(open(os.path.join(ROOT, "testset.json")))
    apple_text = {c["audio"]: c["transcript"] for c in cases}

    data, summaries = {}, {}
    for key, label, _ in ENGINES:
        if key == "apple":
            data[key] = dict(apple_text)
            continue
        r = load(key)
        if not r:
            continue
        data[key] = {f["audio"]: f.get("text", "") for f in r["files"]}
        summaries[key] = r["summary"]

    rows = []
    for i, c in enumerate(cases, 1):
        a = c["audio"]
        cells = []
        for key, label, _ in ENGINES:
            if key not in data:
                continue
            txt = data[key].get(a, "")
            body = (SPOKEN_RE.sub(lambda m: f"<b>{m.group(0)}</b>", html.escape(txt))
                    if key == "apple" else diff_html(apple_text[a], txt))
            cells.append(f'<td class="t"><div class="cell">{body or "<em>—</em>"}</div></td>')
        marks = ", ".join(sorted(set(c["marks"])))
        stem = os.path.splitext(a)[0]
        rows.append(
            f'<tr><th class="rowhead" scope="row">'
            f'<span class="n">{i:02d}</span>'
            f'<button class="play" data-clip="{html.escape(stem)}" type="button" '
            f'aria-label="Play recording {i:02d}">'
            f'<svg viewBox="0 0 16 16" aria-hidden="true" focusable="false">'
            f'<path class="tri" d="M5 3.4v9.2L13 8z"/>'
            f'<g class="bars"><rect x="4.6" y="3.4" width="2.4" height="9.2" rx="0.6"/>'
            f'<rect x="9" y="3.4" width="2.4" height="9.2" rx="0.6"/></g></svg>'
            f'<span class="dur">{c.get("seconds") or 0:.0f}s</span></button>'
            f'<span class="file">{html.escape(a)}</span>'
            f'<span class="meta">spoke: {html.escape(marks)}</span>'
            f'</th>{"".join(cells)}</tr>')

    heads = "".join(
        f'<th class="colhead"><span class="lab">{html.escape(l)}</span>'
        f'<span class="tag {"warn" if t=="not streaming" else ("inc" if t=="incumbent" else "ok")}">{t}</span></th>'
        for k, l, t in ENGINES if k in data)

    # summary table
    def fmt(v, spec="{:.2f}", dash="—"):
        return dash if v is None else spec.format(v)

    srows = []
    apple_marks = 13.75
    for key, label, tag in ENGINES:
        if key == "apple":
            srows.append(
                f'<tr class="inc"><td class="e">{label}</td><td>yes</td><td>—</td>'
                f'<td class="num">0.69</td><td class="num">60</td>'
                f'<td class="num bad">13.75</td><td class="num">— (reference)</td></tr>')
            continue
        s = summaries.get(key)
        if not s:
            continue
        stream = "no" if key.startswith("whisper") else "yes"
        mk = s.get("marks_per_100_words")
        srows.append(
            f'<tr><td class="e">{label}</td><td>{stream}</td>'
            f'<td class="num">{fmt(s.get("rtfx"), "{:.0f}×")}</td>'
            f'<td class="num">{fmt(s.get("delay_mean"))}</td>'
            f'<td class="num">{s.get("spoken_kept")}</td>'
            f'<td class="num {"good" if mk==0 else "bad"}">{fmt(mk)}</td>'
            f'<td class="num">{fmt(s.get("wer_vs_apple"), "{:.3f}")}</td></tr>')

    # Audio embedded as data URIs rather than fetched: the artifact CSP blocks
    # every external host, and 28 clips of speech at 20 kbps Opus come to about
    # 4 MB base64, which fits the page budget with room to spare.
    clips = {}
    for c in cases:
        stem = os.path.splitext(c["audio"])[0]
        src = os.path.join(ROOT, "opus", stem + ".opus")
        if os.path.exists(src):
            b64 = base64.b64encode(open(src, "rb").read()).decode("ascii")
            clips[stem] = "data:audio/ogg;codecs=opus;base64," + b64
    audio_js = "const CLIPS=" + json.dumps(clips) + ";"
    print(f"embedded {len(clips)} clips, {len(audio_js)/1e6:.2f} MB")

    tpl = open(os.path.join(ROOT, "page.tpl.html")).read()
    out = (tpl.replace("<!--HEADS-->", heads)
              .replace("<!--ROWS-->", "\n".join(rows))
              .replace("<!--SUMMARY-->", "\n".join(srows))
              .replace("/*AUDIO*/", audio_js))
    dest = os.path.join(ROOT, "comparison.html")
    open(dest, "w").write(out)
    print("wrote", dest, len(out), "bytes")


if __name__ == "__main__":
    main()
