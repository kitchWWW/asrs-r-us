#!/usr/bin/env python3
"""Streaming speech recognition over a websocket, for recognisers that cannot
run in-process.

The app talks to exactly one protocol here, and this script adapts whichever
engine is behind it. That is the whole reason it exists rather than the two
projects' own servers: sherpa-onnx ships a C++ websocket server and Vosk ships
a Python one, they speak different protocols, and neither reports results the
way `DictationEngine` wants them. One adapter that both engines plug into keeps
the Swift side honest -- it sees one recogniser interface, not two.

Several engines are loaded at once and chosen per connection, so the app can
fan the same microphone out to all of them and hand every reading to the
rewrite model. Independent recognisers make independent mistakes -- one hears
"comma", another "karma", a third "colin" -- and three disagreeing transcripts
tell the model far more than one confident wrong one.

Protocol, from the client's side:

    connect  ws://127.0.0.1:<port>
    send     {"sample_rate": 16000, "engine": "sherpa"}   one JSON text frame
    send     <binary>                        int16 mono PCM, any chunk size
    send     "DONE"                          flush and close the utterance
    receive  {"text": "...", "final": false} on every change

`GET /health` on the same port answers 200 once a model is loaded, so the
supervising Swift side can tell "still loading a 1.8 GB model" from "wedged"
using the same health-poll it already uses for llama-server.

Run:
    asr_server.py --port 8765 \
        --engine sherpa=<dir> --engine vosk=<dir>
"""

import argparse
import asyncio
import http
import json
import os
import sys

import numpy as np
import websockets


class SherpaModel:
    """sherpa-onnx streaming transducer.

    Endpoint detection is deliberately off. The transducer is append-only --
    measured over 6.5 minutes of real dictation it revised its output zero
    times -- so a "final" would tell the app nothing that the current text does
    not already say, while costing a rewrite that skips the debounce. Every
    result is therefore reported as provisional and the debounce governs all of
    them. See `Evals/verbatim/cadence.py`.
    """

    revises = False

    def __init__(self, model_dir):
        import sherpa_onnx
        names = os.listdir(model_dir)

        def pick(prefix):
            found = sorted(f for f in names
                           if f.startswith(prefix) and f.endswith(".onnx")
                           and ".int8." not in f)
            if not found:
                raise SystemExit(f"no {prefix}*.onnx in {model_dir}")
            return os.path.join(model_dir, found[0])

        self.rec = sherpa_onnx.OnlineRecognizer.from_transducer(
            tokens=os.path.join(model_dir, "tokens.txt"),
            encoder=pick("encoder"), decoder=pick("decoder"), joiner=pick("joiner"),
            num_threads=4, sample_rate=16000, feature_dim=80,
            enable_endpoint_detection=False, decoding_method="greedy_search",
        )

    def session(self):
        return SherpaSession(self.rec)


class SherpaSession:
    """One utterance. The recogniser itself is shared; only the stream is not,
    which is what lets several connections decode at once."""

    def __init__(self, rec):
        self.rec = rec
        self.stream = rec.create_stream()

    def feed(self, pcm16):
        samples = pcm16.astype(np.float32) / 32768.0
        self.stream.accept_waveform(16000, samples)
        while self.rec.is_ready(self.stream):
            self.rec.decode_stream(self.stream)
        return self.rec.get_result(self.stream), False

    def flush(self):
        self.stream.input_finished()
        while self.rec.is_ready(self.stream):
            self.rec.decode_stream(self.stream)
        return self.rec.get_result(self.stream), True


class VoskModel:
    """Vosk, which genuinely distinguishes partial from final.

    Unlike the transducer above, Vosk does take text back -- 20 revisions over
    the same 6.5 minutes -- so its finals mean something and are reported as
    such. Word confidences ride along on finals; they are passed through for
    whoever wants them and ignored by the app today.
    """

    revises = True

    def __init__(self, model_dir):
        from vosk import Model, KaldiRecognizer, SetLogLevel
        SetLogLevel(-1)
        self._model = Model(model_dir)
        self._KaldiRecognizer = KaldiRecognizer

    def session(self):
        return VoskSession(self._KaldiRecognizer(self._model, 16000))


class VoskSession:

    def __init__(self, rec):
        self.rec = rec
        self.rec.SetWords(True)
        self.settled = ""

    def _join(self, tail):
        return (self.settled + " " + tail).strip() if self.settled else tail

    def feed(self, pcm16):
        if self.rec.AcceptWaveform(pcm16.tobytes()):
            piece = json.loads(self.rec.Result()).get("text", "")
            if piece:
                self.settled = self._join(piece)
            return self.settled, True
        tail = json.loads(self.rec.PartialResult()).get("partial", "")
        return self._join(tail), False

    def flush(self):
        piece = json.loads(self.rec.FinalResult()).get("text", "")
        if piece:
            self.settled = self._join(piece)
        return self.settled, True


ENGINES = {"sherpa": SherpaModel, "vosk": VoskModel}


async def serve(models, port):
    """Serve every loaded model on one port, chosen per connection.

    No global lock any more. It was there when one engine instance held the
    only decoding stream; now each connection gets its own session over a
    shared, read-only model, so three connections can decode the same audio at
    once -- which is the entire point of loading more than one.
    """

    async def handler(websocket):
        session = None
        last = None
        try:
            async for message in websocket:
                if isinstance(message, bytes):
                    if session is None:
                        # Audio before the handshake names an engine. Refusing
                        # loudly beats silently transcribing with whichever
                        # model happened to be first in the dictionary.
                        await websocket.close(1002, "send the config frame first")
                        return
                    pcm = np.frombuffer(message, dtype=np.int16)
                    if pcm.size == 0:
                        continue
                    text, final = await asyncio.to_thread(session.feed, pcm)
                else:
                    control = message.strip()
                    if control == "DONE":
                        if session is None:
                            continue
                        text, final = await asyncio.to_thread(session.flush)
                        await websocket.send(json.dumps({"text": text, "final": True}))
                        session = models[engine_name].session()
                        last = None
                        continue

                    try:
                        config = json.loads(control)
                    except ValueError:
                        continue
                    # The sample rate is validated rather than honoured: the
                    # models are fixed at 16 kHz, and silently resampling would
                    # hide a real mistake on the client side.
                    rate = config.get("sample_rate")
                    if rate and int(rate) != 16000:
                        await websocket.close(1003, f"expected 16000 Hz, got {rate}")
                        return
                    engine_name = config.get("engine") or next(iter(models))
                    if engine_name not in models:
                        await websocket.close(
                            1003, f"unknown engine {engine_name!r}; have {sorted(models)}")
                        return
                    session = models[engine_name].session()
                    continue

                # Only speak when something changed. The app debounces anyway,
                # but a frame per chunk regardless of content is pure noise on
                # the wire and in the log.
                if (text, final) != last:
                    last = (text, final)
                    await websocket.send(json.dumps({"text": text, "final": final}))
        except websockets.ConnectionClosed:
            pass

    async def health(connection, request):
        if request.path == "/health":
            return connection.respond(http.HTTPStatus.OK, "ok\n")
        return None

    async with websockets.serve(handler, "127.0.0.1", port, process_request=health,
                                max_size=None):
        print(f"asr_server ready: engines={sorted(models)} port={port}", flush=True)
        await asyncio.Future()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--engine", action="append", required=True, metavar="NAME=DIR",
                    help="repeatable, e.g. --engine sherpa=/path --engine vosk=/path")
    ap.add_argument("--port", type=int, default=8765)
    args = ap.parse_args()

    models = {}
    for spec in args.engine:
        name, _, path = spec.partition("=")
        if name not in ENGINES:
            sys.exit(f"unknown engine {name!r}; known: {sorted(ENGINES)}")
        if not os.path.isdir(path):
            sys.exit(f"model directory not found for {name}: {path}")
        print(f"loading {name} from {path}", flush=True)
        models[name] = ENGINES[name](path)

    try:
        asyncio.run(serve(models, args.port))
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
