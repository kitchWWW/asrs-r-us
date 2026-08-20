#!/usr/bin/env python3
"""Streams the test set through a candidate recogniser and scores it.

The question this answers is narrow: does the recogniser write down the words
that were said, including the ones that name punctuation? The app converts
"colon" to ":" itself, in `TranscriptNormalizer` and in the rewrite prompt, so
a recogniser that helpfully converts it first is destroying the signal rather
than adding to it.

Three things are measured, in the order they decide the question:

  verbatim   -- of the spoken punctuation words known to be in an utterance,
                how many survive as words. 1.0 is the goal; Apple's
                SpeechTranscriber is the incumbent to beat.
  invention  -- punctuation marks per 100 words that the recogniser added on
                its own. 0 is the goal. Anything above it is text the rewrite
                model has to be told to ignore.
  delay      -- seconds between a word's audio ending and the recogniser
                committing to it, the same definition `recognizer/latency.swift`
                uses so the numbers are comparable. The working limit is a mean
                under one second.

A caveat on the reference, stated plainly: there is no hand-checked ground
truth for these 28 recordings. The reference is Apple's own transcript from
the session log, so the word-level agreement figure says "how far from the
incumbent", not "how accurate". The verbatim and invention columns do not
depend on the reference being right -- they are counted from the candidate's
own output -- which is why they are the ones the decision rests on.
"""

import argparse
import json
import os
import re
import sys
import time
import wave

import numpy as np

ROOT = os.path.dirname(os.path.abspath(__file__))
WAV = os.path.join(ROOT, "wav")
MODELS = os.path.join(ROOT, "models")

# The words the app expects to receive intact. Longest first so "question mark"
# is counted as one item rather than as a stray "mark".
SPOKEN = [
    "open parentheses", "close parentheses", "closed parentheses",
    "open parenthesis", "close parenthesis",
    "exclamation point", "question mark", "new paragraph",
    "open quote", "close quote", "new line",
    "semicolon", "colon", "period", "comma",
]
MARKS = re.compile(r"[.,;:!?()\"“”]")


def read_wav(path):
    with wave.open(path, "rb") as w:
        assert w.getframerate() == 16000 and w.getnchannels() == 1
        raw = w.readframes(w.getnframes())
    samples = np.frombuffer(raw, dtype=np.int16).astype(np.float32) / 32768.0
    return samples, len(samples) / 16000.0


def count_spoken(text):
    """Spoken punctuation words surviving as words, longest phrase first."""
    t = " " + re.sub(r"[^a-z ]", " ", text.lower()) + " "
    found = {}
    for phrase in SPOKEN:
        n = len(re.findall(r"(?<= )" + re.escape(phrase) + r"(?= )", t))
        if n:
            found[phrase] = n
            t = re.sub(r"(?<= )" + re.escape(phrase) + r"(?= )", " ", t)
    return found


def words(text):
    return re.findall(r"[a-z0-9']+", text.lower())


def wer(ref, hyp):
    r, h = words(ref), words(hyp)
    if not r:
        return None
    d = np.zeros((len(r) + 1, len(h) + 1), dtype=np.int32)
    d[:, 0] = np.arange(len(r) + 1)
    d[0, :] = np.arange(len(h) + 1)
    for i in range(1, len(r) + 1):
        for j in range(1, len(h) + 1):
            d[i, j] = min(d[i - 1, j] + 1, d[i, j - 1] + 1,
                          d[i - 1, j - 1] + (r[i - 1] != h[j - 1]))
    return d[len(r), len(h)] / len(r)


# --------------------------------------------------------------------------
# Engines. Each yields (final_text, [(word, audio_pos_seen, word_end_time)]).
# `audio_pos_seen` is how far into the audio the decoder had been fed when the
# word first appeared; `word_end_time` is when that word's audio actually
# ended. The difference is the delay the speaker feels.
# --------------------------------------------------------------------------

def run_sherpa(model_dir, samples, chunk=0.32):
    import sherpa_onnx
    files = os.listdir(model_dir)

    def pick(prefix):
        exact = [f for f in files
                 if f.startswith(prefix) and f.endswith(".onnx")
                 and ".int8." not in f]
        return os.path.join(model_dir, sorted(exact)[0])

    rec = sherpa_onnx.OnlineRecognizer.from_transducer(
        tokens=os.path.join(model_dir, "tokens.txt"),
        encoder=pick("encoder"), decoder=pick("decoder"), joiner=pick("joiner"),
        num_threads=4, sample_rate=16000, feature_dim=80,
        enable_endpoint_detection=False, decoding_method="greedy_search",
    )
    stream = rec.create_stream()
    step = int(16000 * chunk)
    seen, timeline = 0, []
    t0 = time.perf_counter()
    for start in range(0, len(samples), step):
        block = samples[start:start + step]
        stream.accept_waveform(16000, block)
        while rec.is_ready(stream):
            rec.decode_stream(stream)
        pos = (start + len(block)) / 16000.0
        res = json.loads(rec.get_result_as_json_string(stream))
        toks, stamps = res.get("tokens", []), res.get("timestamps", [])
        for i in range(seen, min(len(toks), len(stamps))):
            timeline.append((toks[i], pos, stamps[i]))
        seen = min(len(toks), len(stamps))
    stream.input_finished()
    while rec.is_ready(stream):
        rec.decode_stream(stream)
    elapsed = time.perf_counter() - t0
    res = json.loads(rec.get_result_as_json_string(stream))
    toks, stamps = res.get("tokens", []), res.get("timestamps", [])
    pos = len(samples) / 16000.0
    for i in range(seen, min(len(toks), len(stamps))):
        timeline.append((toks[i], pos, stamps[i]))
    return res.get("text", ""), timeline, elapsed


def run_vosk(model_dir, samples, chunk=0.32):
    """Vosk, credited with its partial results.

    Scoring Vosk on finals alone would libel it: a final only lands at an
    endpoint, so a word spoken mid-sentence would look seconds late when the
    recogniser had in fact shown it much earlier. The partial hypothesis is
    what a dictation panel would actually display, so first appearance *there*
    is when the word arrived. Word end times still come from the final, which
    is the only place Vosk reports them.
    """
    from vosk import Model, KaldiRecognizer, SetLogLevel
    SetLogLevel(-1)
    rec = KaldiRecognizer(Model(model_dir), 16000)
    rec.SetWords(True)
    step = int(16000 * chunk)
    pcm = (samples * 32768.0).astype(np.int16)
    text_parts, finals = [], []
    first_seen = {}          # global word index -> audio position first shown
    committed = 0            # words already closed out by a final
    t0 = time.perf_counter()
    for start in range(0, len(pcm), step):
        block = pcm[start:start + step].tobytes()
        pos = min((start + step) / 16000.0, len(pcm) / 16000.0)
        done = rec.AcceptWaveform(block)
        if done:
            r = json.loads(rec.Result())
            text_parts.append(r.get("text", ""))
            got = r.get("result", [])
            for i, w in enumerate(got):
                first_seen.setdefault(committed + i, pos)
            finals += got
            committed += len(got)
        else:
            partial = json.loads(rec.PartialResult()).get("partial", "")
            for i in range(len(partial.split())):
                first_seen.setdefault(committed + i, pos)
    r = json.loads(rec.FinalResult())
    elapsed = time.perf_counter() - t0
    text_parts.append(r.get("text", ""))
    pos = len(pcm) / 16000.0
    got = r.get("result", [])
    for i, w in enumerate(got):
        first_seen.setdefault(committed + i, pos)
    finals += got
    timeline = [(w["word"], first_seen.get(i, pos), w["end"])
                for i, w in enumerate(finals)]
    return " ".join(p for p in text_parts if p), timeline, elapsed


ENGINES = {
    "zipformer-en":        ("sherpa", "sherpa-onnx-streaming-zipformer-en-2023-06-26"),
    "zipformer-20M":       ("sherpa", "sherpa-onnx-streaming-zipformer-en-20M-2023-02-17"),
    "nemo-conformer-80ms": ("sherpa", "sherpa-onnx-nemo-streaming-fast-conformer-transducer-en-80ms"),
    "nemo-conformer-1040ms": ("sherpa", "sherpa-onnx-nemo-streaming-fast-conformer-transducer-en-1040ms"),
    "vosk-small":          ("vosk", "vosk-model-small-en-us-0.15"),
    "vosk-0.22":           ("vosk", "vosk-model-en-us-0.22"),
}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("engine", choices=sorted(ENGINES))
    ap.add_argument("--limit", type=int, default=0)
    args = ap.parse_args()

    kind, sub = ENGINES[args.engine]
    model_dir = os.path.join(MODELS, sub)
    if not os.path.isdir(model_dir):
        sys.exit(f"model not downloaded: {model_dir}")

    cases = json.load(open(os.path.join(ROOT, "testset.json")))
    if args.limit:
        cases = cases[:args.limit]

    out, delays = [], []
    audio_total = wall_total = 0.0
    for c in cases:
        stem = os.path.splitext(c["audio"])[0]
        path = os.path.join(WAV, stem + ".wav")
        samples, seconds = read_wav(path)
        runner = run_sherpa if kind == "sherpa" else run_vosk
        text, timeline, elapsed = runner(model_dir, samples)
        audio_total += seconds
        wall_total += elapsed
        d = [pos - end for _, pos, end in timeline if pos >= end]
        delays += d
        out.append({
            "audio": c["audio"], "seconds": seconds, "elapsed": elapsed,
            "text": text,
            "expected_marks": c["marks"],
            "spoken_found": count_spoken(text),
            "n_words": len(words(text)),
            "n_marks": len(MARKS.findall(text)),
            "wer_vs_apple": wer(c["transcript"], text),
            "mean_delay": float(np.mean(d)) if d else None,
        })
        print(f"  {stem[:24]}  {seconds:6.1f}s  {elapsed:6.2f}s  "
              f"marks={len(MARKS.findall(text)):3d}  {text[:70]}")

    exp = sum(len(c["marks"]) for c in cases)
    got = sum(sum(o["spoken_found"].values()) for o in out)
    wers = [o["wer_vs_apple"] for o in out if o["wer_vs_apple"] is not None]
    nw = sum(o["n_words"] for o in out)
    summary = {
        "engine": args.engine,
        "files": len(out),
        "audio_seconds": audio_total,
        "wall_seconds": wall_total,
        "rtfx": audio_total / wall_total if wall_total else None,
        "spoken_expected": exp,
        "spoken_kept": got,
        "verbatim_recall": got / exp if exp else None,
        "marks_per_100_words": 100.0 * sum(o["n_marks"] for o in out) / nw if nw else None,
        "wer_vs_apple": float(np.mean(wers)) if wers else None,
        "delay_mean": float(np.mean(delays)) if delays else None,
        "delay_median": float(np.median(delays)) if delays else None,
        "delay_p90": float(np.percentile(delays, 90)) if delays else None,
    }
    json.dump({"summary": summary, "files": out},
              open(os.path.join(ROOT, f"results-{args.engine}.json"), "w"), indent=1)
    print(json.dumps(summary, indent=1))


if __name__ == "__main__":
    main()
