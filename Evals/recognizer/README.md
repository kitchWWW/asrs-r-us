# Recognizer benchmarks

Scores a speech recogniser on the two things that turned out to matter, using
the session recordings in `~/Library/Application Support/ASRs-R-US/audio/`:

- **How late the words are.** `latency.swift` runs each recording twice. The
  first pass is offline with `audioTimeRange` attributes, which says when each
  word's audio *ends*. The second plays the file at wall-clock speed and notes
  when the recogniser first commits to that word. The gap is what you feel
  while dictating. The working limit is a mean under one second.
- **What it does to punctuation.** `real.swift` counts marks per 100 words and
  how many spoken punctuation words ("comma", "period", "colon") survive as
  words rather than being silently converted.

`stream_whisper.py` scores a streaming Whisper the same way: at every step it
re-decodes what has been heard so far, and a word's delay is the first moment
the transcript is long enough to contain it. Whisper is measured against its
own word timestamps rather than Apple's, because the two tokenise differently
and matching by word index made the lag come out negative.

## Running

    # word-level latency, one line per configuration
    swiftc -O -parse-as-library -o /tmp/latency latency.swift feed.swift
    /tmp/latency ~/Library/Application\ Support/ASRs-R-US/audio/*.flac

    # punctuation fidelity across configurations
    swiftc -O -parse-as-library -o /tmp/real real.swift feed.swift
    /tmp/real ~/Library/Application\ Support/ASRs-R-US/audio/*.flac

    # streaming Whisper (needs `brew install whisper-cpp` and a ggml model)
    STEP=0.5 python3 stream_whisper.py small.en

## Findings so far

24 recordings, ~700 words, on an M5 Pro:

| configuration | mean word delay | median | p90 |
|---|---|---|---|
| SpeechTranscriber + fastResults | 0.69s | 0.68s | 1.22s |
| SpeechTranscriber, volatile only | 2.00s | 2.07s | 3.45s |

`fastResults` costs a little accuracy -- 10 spoken punctuation words kept
against 12 over the same corpus -- and buys 1.3 seconds per word. It stays on.
