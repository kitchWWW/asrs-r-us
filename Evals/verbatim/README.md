# Verbatim recogniser bench

The harness behind the recogniser choice. It is committed; nothing it reads or
writes is, because all of that is Brian's speech or derived from it -- the same
reason `Evals/gold-set.json` and the session log are not in the repo.

## Running it

The scripts need `sherpa-onnx`, `numpy` and `soundfile`. There is no venv here
on purpose -- `make asr-setup` already builds one for the sidecar, and a second
copy of the same packages is 80 MB for nothing:

```sh
V="$HOME/Library/Application Support/ASRs-R-US/asr/venv"
uv pip install --python "$V/bin/python" soundfile   # the extra bench needs
"$V/bin/python" bench.py nemo-conformer-1040ms
```

## Rebuilding the inputs

The scripts read a test set that is generated from the live corpus, so a fresh
checkout has nothing to run against until you make one:

- **`testset.json`** -- picked from `~/Library/Application Support/ASRs-R-US/`
  by correlating `sessions.jsonl` against `audio/` on timestamp, then selecting
  for coverage of the spoken punctuation words. Each entry carries the audio
  filename, the transcript, and which marks were spoken.
- **`wav/`** -- each recording as 16 kHz mono s16 (`ffmpeg -ac 1 -ar 16000`).
- **`models/`** -- `make asr-setup` puts the model in the app's support
  directory; point `MODELS` at it or copy it here.

## What each script measures

| script | answers |
|---|---|
| `bench.py` | verbatim fidelity, invented punctuation per 100 words, word delay, RTFx |
| `cadence.py` | updates and finals per minute, and whether a recogniser revises |
| `make_page.py` + `page.tpl.html` | renders a per-recording comparison page |

`make_page.py` expects one `results-<engine>.json` per recogniser in its
`ENGINES` list; only the shipped one is kept here, so trim that list or re-run
`bench.py` for whatever you are comparing.

## Numbers quoted in the app

These figures appear in comments and prompts, and this is where they came from:

- **0.00 invented marks per 100 words** (transducer) against **13.75** (Apple),
  and spoken punctuation words kept -- `bench.py`, 28 recordings.
- **0.86s mean word delay** for the transducer, **0.69s** for Apple -- `bench.py`,
  same set. Apple's figure originally came from an earlier Swift harness that
  has since been deleted; `bench.py` measures it the same way.
- **28.7 updates/min, 0 revisions** for the transducer -- `cadence.py`, which is
  what `RecognizerChoice.revisesText` and `debounceFloorMilliseconds` rest on.
- The measured mistranscriptions named in the prompt ("kama", "karma", "colin",
  "tama") come from aligning each recogniser's output against the Apple
  transcript per recording.
