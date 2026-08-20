#!/usr/bin/env python3
"""Does the recogniser lose the opening word, and does priming it help?

Brian reports the first word going missing, worst after a pause. The suspicion
is a cold encoder cache: a cache-aware streaming transducer decodes its first
chunk against zero-initialised state, and the sidecar resets that state for
every connection -- so the opening word is the one word decoded with no
context at all.

That is a guess until it is measured, so this replays the test set three ways:

  as-is    -- what the app does today
  silence  -- N seconds of digital silence prepended, so the cache is warm by
              the time speech starts. Free if it works: silence costs only
              decode time, and the app can feed it before the mic is live.
  noise    -- the same, but very quiet noise rather than true silence, in case
              the encoder treats an all-zero signal as a special case.

Scored on whether the reference's opening words survive, not on whole-transcript
WER, which would drown a single word in 700.
"""

import json
import os
import re
import sys

import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from bench import read_wav, MODELS, ROOT, WAV, words  # noqa: E402

MODEL = os.path.join(
    MODELS, "sherpa-onnx-nemo-streaming-fast-conformer-transducer-en-1040ms")


def transcribe(rec, samples, chunk=0.32):
    stream = rec.create_stream()
    step = int(16000 * chunk)
    for start in range(0, len(samples), step):
        stream.accept_waveform(16000, samples[start:start + step])
        while rec.is_ready(stream):
            rec.decode_stream(stream)
    stream.input_finished()
    while rec.is_ready(stream):
        rec.decode_stream(stream)
    return rec.get_result(stream)


def build():
    import sherpa_onnx
    names = os.listdir(MODEL)

    def pick(p):
        return os.path.join(MODEL, sorted(
            f for f in names
            if f.startswith(p) and f.endswith(".onnx") and ".int8." not in f)[0])

    return sherpa_onnx.OnlineRecognizer.from_transducer(
        tokens=os.path.join(MODEL, "tokens.txt"),
        encoder=pick("encoder"), decoder=pick("decoder"), joiner=pick("joiner"),
        num_threads=4, sample_rate=16000, feature_dim=80,
        enable_endpoint_detection=False, decoding_method="greedy_search",
    )


def opening(text, n):
    return words(text)[:n]


def main():
    rec = build()
    cases = json.load(open(os.path.join(ROOT, "testset.json")))

    variants = [
        ("as-is", lambda s: s),
        ("silence 0.5s", lambda s: np.concatenate([np.zeros(8000, np.float32), s])),
        ("silence 1.0s", lambda s: np.concatenate([np.zeros(16000, np.float32), s])),
        ("silence 2.0s", lambda s: np.concatenate([np.zeros(32000, np.float32), s])),
        ("noise 1.0s", lambda s: np.concatenate([
            (np.random.default_rng(0).standard_normal(16000) * 1e-4).astype(np.float32), s])),
    ]

    print(f"{'variant':14} {'1st word kept':>14} {'first 3 kept':>14}")
    print("-" * 46)
    detail = {}
    for label, transform in variants:
        first_hits = 0
        three_hits = 0
        rows = []
        for c in cases:
            stem = os.path.splitext(c["audio"])[0]
            samples, _ = read_wav(os.path.join(WAV, stem + ".wav"))
            text = transcribe(rec, transform(samples))
            ref = opening(c["transcript"], 3)
            hyp = opening(text, 3)
            if not ref:
                continue
            got_first = bool(hyp) and hyp[0] == ref[0]
            first_hits += got_first
            three_hits += (hyp[:3] == ref[:3])
            rows.append((stem, ref, hyp, got_first))
        n = len(rows)
        detail[label] = rows
        print(f"{label:14} {first_hits:>7}/{n:<6} {three_hits:>7}/{n:<6}")

    print("\nWhere 'as-is' lost the opening word:")
    for stem, ref, hyp, ok in detail["as-is"]:
        if ok:
            continue
        primed = next(r for r in detail["silence 1.0s"] if r[0] == stem)
        mark = "fixed by priming" if primed[3] else "still wrong"
        print(f"  ref {' '.join(ref):<28} got {' '.join(hyp):<28} {mark}")


if __name__ == "__main__":
    main()
