#!/usr/bin/env python3
"""How often each recogniser changes its mind, and how often it commits.

The rewrite service fires on transcript changes and lets *finals* skip the
debounce entirely, on the reasoning that a final will not be revised so
rewriting it is not speculative. That reasoning is Apple-shaped. Before wiring
two more recognisers into the same path, this counts what they actually emit:

  updates/min   -- how often the visible text changes at all. This is what the
                   debounce has to absorb.
  finals/min    -- how often something arrives that would currently bypass the
                   debounce and bill a rewrite immediately.
  revisions     -- how often a recogniser took back text it had already shown.
                   Zero means the stream is append-only, which means "final" is
                   not a meaningful distinction and every update is safe to
                   treat as provisional.
"""

import json
import os
import sys

import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from bench import read_wav, MODELS, ROOT, WAV  # noqa: E402


def sherpa_cadence(model_dir, samples, endpointing, chunk=0.32):
    import sherpa_onnx
    files = os.listdir(model_dir)

    def pick(p):
        return os.path.join(model_dir, sorted(
            f for f in files if f.startswith(p) and f.endswith(".onnx")
            and ".int8." not in f)[0])

    rec = sherpa_onnx.OnlineRecognizer.from_transducer(
        tokens=os.path.join(model_dir, "tokens.txt"),
        encoder=pick("encoder"), decoder=pick("decoder"), joiner=pick("joiner"),
        num_threads=4, sample_rate=16000, feature_dim=80,
        enable_endpoint_detection=endpointing, decoding_method="greedy_search",
    )
    stream = rec.create_stream()
    step = int(16000 * chunk)
    updates = finals = revisions = 0
    previous = ""
    committed = ""
    for start in range(0, len(samples), step):
        stream.accept_waveform(16000, samples[start:start + step])
        while rec.is_ready(stream):
            rec.decode_stream(stream)
        text = rec.get_result(stream)
        if text != previous:
            updates += 1
            # A revision is the live text no longer extending what was shown.
            if previous and not text.startswith(previous):
                revisions += 1
            previous = text
        if endpointing and rec.is_endpoint(stream):
            if text:
                finals += 1
                committed += " " + text
            rec.reset(stream)
            previous = ""
    return updates, finals, revisions


def vosk_cadence(model_dir, samples, chunk=0.32):
    from vosk import Model, KaldiRecognizer, SetLogLevel
    SetLogLevel(-1)
    rec = KaldiRecognizer(Model(model_dir), 16000)
    pcm = (samples * 32768.0).astype(np.int16)
    step = int(16000 * chunk)
    updates = finals = revisions = 0
    previous = ""
    for start in range(0, len(pcm), step):
        if rec.AcceptWaveform(pcm[start:start + step].tobytes()):
            if json.loads(rec.Result()).get("text"):
                finals += 1
            previous = ""
        else:
            text = json.loads(rec.PartialResult()).get("partial", "")
            if text != previous:
                updates += 1
                if previous and not text.startswith(previous):
                    revisions += 1
                previous = text
    if json.loads(rec.FinalResult()).get("text"):
        finals += 1
    return updates, finals, revisions


def main():
    cases = json.load(open(os.path.join(ROOT, "testset.json")))[:12]
    configs = [
        ("nemo-1040ms  (no endpointing)", "sherpa",
         "sherpa-onnx-nemo-streaming-fast-conformer-transducer-en-1040ms", False),
        ("nemo-1040ms  (endpointing on)", "sherpa",
         "sherpa-onnx-nemo-streaming-fast-conformer-transducer-en-1040ms", True),
        ("vosk-0.22", "vosk", "vosk-model-en-us-0.22", None),
    ]
    print(f"{'configuration':32} {'upd/min':>9} {'final/min':>10} {'revisions':>10}")
    print("-" * 65)
    for label, kind, sub, ep in configs:
        model_dir = os.path.join(MODELS, sub)
        if not os.path.isdir(model_dir):
            print(f"{label:32} {'(model missing)':>31}")
            continue
        U = F = R = 0
        seconds = 0.0
        for c in cases:
            stem = os.path.splitext(c["audio"])[0]
            samples, secs = read_wav(os.path.join(WAV, stem + ".wav"))
            seconds += secs
            u, f, r = (sherpa_cadence(model_dir, samples, ep) if kind == "sherpa"
                       else vosk_cadence(model_dir, samples))
            U += u; F += f; R += r
        m = seconds / 60.0
        print(f"{label:32} {U/m:9.1f} {F/m:10.1f} {R:10d}")
    print(f"\n{len(cases)} recordings, {seconds/60:.1f} min of audio, 320 ms chunks")


if __name__ == "__main__":
    main()
