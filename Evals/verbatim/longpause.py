#!/usr/bin/env python3
"""Does a long silence swallow the word that follows it?

Brian's report is specific: not the first word of a session, but the first word
after being quiet for a while, with the recogniser already running. The session
log backs it up -- 24.3 seconds recorded for seven words, then an immediate
re-dictation of the same sentence with "let's" restored.

The earlier `firstword.py` looked at half a second to two seconds of lead-in and
found nothing, which is why this exists: the real gap is fifteen to thirty
seconds. Two shapes are tested, because they fail for different reasons if they
fail at all:

  lead   -- silence before any speech, the "opened the panel and thought about
            it" case.
  gap    -- speech, then a long silence, then more speech. This is the one the
            report describes, and the word measured is the first one *after*
            the gap, not the first of the file.

Digital zero and quiet noise are both tried. Real microphone silence is never
all-zero, and a log-mel front end can treat an exactly-zero frame very
differently from a nearly-zero one, so testing only zeros would risk
reproducing a bug the app cannot actually hit -- or missing one it can.
"""

import json
import os
import sys

import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from bench import read_wav, MODELS, ROOT, WAV, words  # noqa: E402

MODEL = os.path.join(
    MODELS, "sherpa-onnx-nemo-streaming-fast-conformer-transducer-en-1040ms")
RNG = np.random.default_rng(7)


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


def quiet(seconds, kind):
    n = int(16000 * seconds)
    if kind == "zeros":
        return np.zeros(n, np.float32)
    return (RNG.standard_normal(n) * 3e-4).astype(np.float32)


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


def main():
    rec = build()
    cases = json.load(open(os.path.join(ROOT, "testset.json")))
    # Long files only: a `gap` test needs speech on both sides of the silence.
    cases = [c for c in cases if (c.get("seconds") or 0) >= 20][:12]
    clips = []
    for c in cases:
        stem = os.path.splitext(c["audio"])[0]
        samples, _ = read_wav(os.path.join(WAV, stem + ".wav"))
        clips.append((stem, samples, words(c["transcript"])))
    print(f"{len(clips)} recordings, 20s or longer\n")

    print("LEAD-IN: silence before any speech. Scored on the opening word.")
    print(f"{'pad':>6}  {'zeros':>12}  {'quiet noise':>12}")
    for seconds in [0, 5, 10, 20, 30]:
        line = []
        for kind in ["zeros", "noise"]:
            hits = 0
            for _, samples, ref in clips:
                pad = quiet(seconds, kind) if seconds else np.zeros(0, np.float32)
                hyp = words(transcribe(rec, np.concatenate([pad, samples])))
                hits += bool(hyp) and bool(ref) and hyp[0] == ref[0]
            line.append(f"{hits:>4}/{len(clips):<3}")
        print(f"{seconds:>5}s  {line[0]:>12}  {line[1]:>12}")

    print("\nGAP: 4s of speech, then silence, then the rest.")
    print("Scored on whether every reference word still appears, in order.")
    print(f"{'gap':>6}  {'zeros':>12}  {'quiet noise':>12}")
    for seconds in [0, 5, 10, 20, 30]:
        line = []
        for kind in ["zeros", "noise"]:
            kept = total = 0
            for _, samples, ref in clips:
                head, tail = samples[:16000 * 4], samples[16000 * 4:]
                pad = quiet(seconds, kind) if seconds else np.zeros(0, np.float32)
                hyp = words(transcribe(rec, np.concatenate([head, pad, tail])))
                # Longest common subsequence would be exact; a set check over
                # the words after the cut is enough to see a word vanish.
                after = ref[len(words(transcribe(rec, head))):]
                kept += sum(1 for x in after if x in hyp)
                total += len(after)
            line.append(f"{100.0 * kept / max(1, total):>10.1f}%")
        print(f"{seconds:>5}s  {line[0]:>12}  {line[1]:>12}")


if __name__ == "__main__":
    main()
