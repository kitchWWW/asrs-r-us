#!/usr/bin/env python3
"""Moves the audio behind every annotated case into the protected set.

A correction in `gold-set.json` is the expensive half of an eval case: the
transcript can be regenerated from audio at any time, the answer cannot. So the
recording it refers to stops being expendable, and this walks it out of the
ordinary corpus -- where it is subject to the 5 GB ceiling and random thinning
-- into `annotated/`, which the eviction pass cannot see.

Idempotent: promoting something already promoted is a no-op, so this is safe to
run after every round of corrections.

    python3 Evals/promote-gold.py            # promote everything labelled
    python3 Evals/promote-gold.py --dry-run  # say what it would move
    python3 Evals/promote-gold.py --all      # include cases still pending
"""

import argparse
import json
import os
import shutil

SUPPORT = os.path.expanduser('~/Library/Application Support/ASRs-R-US')
AUDIO = os.path.join(SUPPORT, 'audio')
ANNOTATED = os.path.join(SUPPORT, 'annotated')
LOG = os.path.join(SUPPORT, 'sessions.jsonl')
GOLD = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'gold-set.json')


def sessions_by_transcript():
    """The log keyed by what was said, which is how a gold case identifies itself."""
    out = {}
    with open(LOG) as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                record = json.loads(line)
            except json.JSONDecodeError:
                continue
            text = (record.get('transcript') or '').strip()
            if text:
                out[text] = record
    return out


def find_audio(stem):
    """A recording is a .flac for a second and a .caf from then on."""
    for folder in (ANNOTATED, AUDIO):
        for ext in ('caf', 'flac', 'wav'):
            path = os.path.join(folder, f'{stem}.{ext}')
            if os.path.exists(path):
                return path, folder
    return None, None


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--dry-run', action='store_true')
    ap.add_argument('--all', action='store_true',
                    help='include cases that have not been reviewed yet')
    args = ap.parse_args()

    os.makedirs(ANNOTATED, exist_ok=True)
    gold = json.load(open(GOLD))['cases']
    cases = gold if args.all else [c for c in gold if c.get('status') == 'approved']
    log = sessions_by_transcript()

    moved = already = missing = unrecorded = 0
    for case in cases:
        record = log.get(case['transcript'].strip())
        stem = (record or {}).get('audioFile')
        if not stem:
            unrecorded += 1
            continue
        stem = os.path.splitext(stem)[0]
        path, folder = find_audio(stem)
        if path is None:
            missing += 1
            print(f'  {case["id"]}: {stem} is referenced but no longer on disk')
            continue
        if folder == ANNOTATED:
            already += 1
            continue
        print(f'  {case["id"]}: {os.path.basename(path)} -> annotated/')
        if not args.dry_run:
            shutil.move(path, os.path.join(ANNOTATED, os.path.basename(path)))
        moved += 1

    print(f'\n{len(cases)} case(s) considered')
    print(f'  {moved} promoted{" (dry run)" if args.dry_run else ""}')
    print(f'  {already} already protected')
    print(f'  {missing} evicted before they could be protected')
    print(f'  {unrecorded} predate audio recording, so there is nothing to protect')


if __name__ == '__main__':
    main()
