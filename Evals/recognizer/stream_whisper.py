#!/usr/bin/env python3
"""Simulates a streaming Whisper against the same clock the Apple modules were scored on.

At every `step` of audio, the model re-decodes what has been heard so far and
whatever it produces is what the user would see at that moment. A word's delay
is the first moment the transcript is long enough to contain it, minus the
moment that word's audio finished. Whisper pads every window to 30 seconds
internally, so decoding 4 seconds costs the same as decoding 20 -- which is
what makes re-decoding on every step affordable at all.
"""
import glob, json, os, statistics, subprocess, sys, time, wave

SP = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
MODELS = os.path.expanduser('~/Library/Application Support/ASRs-R-US/whisper')
CLI = subprocess.run(['brew', '--prefix'], capture_output=True, text=True).stdout.strip() + '/bin/whisper-cli'
MARKS = set('.,;:!?')
PWORDS = ['comma', 'period', 'colon', 'quote', 'parenthes', 'paren']
STEP = float(os.environ.get('STEP', '0.5'))


def duration(path):
    with wave.open(path) as w:
        return w.getnframes() / w.getframerate()


def slice_wav(src, seconds, dst):
    with wave.open(src) as w:
        rate = w.getframerate()
        frames = w.readframes(min(w.getnframes(), int(seconds * rate)))
        with wave.open(dst, 'wb') as o:
            o.setnchannels(w.getnchannels())
            o.setsampwidth(w.getsampwidth())
            o.setframerate(rate)
            o.writeframes(frames)


def decode(model, wav):
    t0 = time.time()
    r = subprocess.run([CLI, '-m', model, '-f', wav, '-nt', '-np', '-t', '8'],
                       capture_output=True, text=True)
    return r.stdout.strip(), time.time() - t0


def word_end_times(model, wav):
    """Whisper's own view of when each word's audio ends -- its reference clock.

    Scoring Whisper against Apple's word indices was wrong: the two tokenise
    differently (digits, contractions, addresses), so index N is not the same
    word, and the lag came out negative. Each system is now measured against
    its own alignment, which is the comparison that means something anyway:
    how long after a word was spoken did *this* system show it.
    """
    out = wav + '.ref'
    subprocess.run([CLI, '-m', model, '-f', wav, '-np', '-ml', '1', '-sow',
                    '-oj', '-of', out], capture_output=True, text=True)
    path = out + '.json'
    if not os.path.exists(path):
        return []
    data = json.load(open(path))
    os.remove(path)
    ends = []
    for seg in data.get('transcription', []):
        text = seg.get('text', '').strip()
        if not text:
            continue
        offs = seg.get('offsets', {})
        end = offs.get('to', 0) / 1000.0
        for _ in text.split():
            ends.append(end)
    return ends


def run(model_name, files, ends):
    model = os.path.join(MODELS, f'ggml-{model_name}.bin')
    tmp = os.path.join(SP, 'punct', '_win.wav')
    lags, marks, pwords, tokens, infer = [], 0, 0, 0, []
    finals = {}
    for wav in files:
        base = os.path.basename(wav).replace('.wav', '.flac')
        ref = word_end_times(model, wav)
        if not ref:
            continue
        total = duration(wav)
        first_seen, text = {}, ''
        t = STEP
        while t < total + STEP:
            slice_wav(wav, min(t, total), tmp)
            text, took = decode(model, tmp)
            infer.append(took)
            arrival = t + took          # audio available at t, decoded took later
            n = len(text.split())
            for i in range(1, n + 1):
                first_seen.setdefault(i, arrival)
            t += STEP
        for i, end in enumerate(ref, start=1):
            if i in first_seen:
                lag = first_seen[i] - end
                if -2 < lag < 30:
                    lags.append(lag)
        marks += sum(1 for ch in text if ch in MARKS)
        low = text.lower()
        pwords += sum(low.count(w) for w in PWORDS)
        tokens += len(text.split())
        finals[base] = text
    return lags, marks, pwords, tokens, infer, finals


if __name__ == '__main__':
    ends = json.load(open(os.path.join(SP, 'punct', 'word-ends.json')))
    files = sorted(glob.glob(os.path.join(SP, 'wav', '*.wav')))
    limit = int(os.environ.get('LIMIT', '0'))
    if limit:
        files = files[:limit]
    for name in sys.argv[1:]:
        lags, marks, pwords, tokens, infer, finals = run(name, files, ends)
        lags.sort()
        if not lags:
            print(f'{name}: no overlap'); continue
        pct = lambda p: lags[min(len(lags) - 1, int(p * len(lags)))]
        print(f'{name:<16} n={len(lags):4d}  mean {statistics.mean(lags):.2f}s  '
              f'median {pct(0.5):.2f}s  p90 {pct(0.9):.2f}s  '
              f'| marks {marks} ({marks / tokens * 100:.1f}/100w)  '
              f'punctuation-words {pwords}  '
              f'| decode median {statistics.median(infer):.2f}s')
        json.dump(finals, open(os.path.join(SP, 'punct', f'stream-{name}.json'), 'w'), indent=1)
