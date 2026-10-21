"""Benchmarks gpt-realtime-translate on the scripted conversation.

Modes:
  dual    Two sessions (target en, target zh) both get all audio. Measures
          whether each stays quiet on speech already in its target language
          ("leaks"), and first-text latency.
  switch  One session. Watches the source transcript, guesses the language
          from its script, and flips the target with session.update so speech
          is always translated into the other language. Tests whether one
          connection can do both directions.

    OPENAI_API_KEY=... python openai_probe.py dual
    (or put OPENAI_API_KEY=... in Tools/probe/.env.local, which is gitignored)

The key is never printed. Raw events go to out/<mode>-events.jsonl.
"""
import asyncio
import base64
import json
import os
import statistics
import sys
import time
import wave

import websockets

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, "out")
URL = "wss://api.openai.com/v1/realtime/translations?model=gpt-realtime-translate"
CHUNK_S = 0.04
TAIL_SILENCE_S = 6.0
SEGMENT_GAP_S = 0.7
PREDICT_PAUSE_S = 0.9


def api_key():
    if os.environ.get("OPENAI_API_KEY"):
        return os.environ["OPENAI_API_KEY"].strip()
    path = os.path.join(HERE, ".env.local")
    if os.path.exists(path):
        for line in open(path):
            if line.startswith("OPENAI_API_KEY="):
                return line.split("=", 1)[1].strip()
    sys.exit("Set OPENAI_API_KEY or add it to Tools/probe/.env.local")


def script_lang(text):
    han = sum(1 for c in text if "一" <= c <= "鿿" or "㐀" <= c <= "䶿")
    latin = sum(1 for c in text if c.isascii() and c.isalpha())
    if han == 0 and latin == 0:
        return None
    return "zh" if han >= latin / 4 else "en"


class Session:
    def __init__(self, label, target, key, clock, log, transcribe=True):
        self.label, self.target, self.key, self.clock, self.log = label, target, key, clock, log
        self.transcribe = transcribe
        self.ws = None
        self.ready = asyncio.Event()
        self.closed = asyncio.Event()
        self.on_input = None  # callback(text_delta)

    def config(self, target):
        audio = {"output": {"language": target}}
        if self.transcribe:
            audio["input"] = {
                "transcription": {"model": "gpt-realtime-whisper"},
                "noise_reduction": {"type": "near_field"},
            }
        return {"type": "session.update", "session": {"audio": audio}}

    async def connect(self):
        self.ws = await websockets.connect(
            URL, additional_headers={"Authorization": f"Bearer {self.key}"}, max_size=None
        )
        await self.ws.send(json.dumps(self.config(self.target)))
        asyncio.create_task(self.reader())

    async def set_target(self, target):
        self.target = target
        self.record("client.set_target", target=target)
        await self.ws.send(json.dumps(self.config(target)))

    def record(self, kind, **fields):
        self.log.append({"t": round(self.clock(), 3), "session": self.label, "type": kind, **fields})

    async def reader(self):
        try:
            async for raw in self.ws:
                event = json.loads(raw)
                kind = event.get("type", "?")
                if kind == "session.created":
                    self.ready.set()
                    self.record(kind)
                elif kind == "session.output_audio.delta":
                    self.record(kind, bytes=len(base64.b64decode(event.get("delta", ""))))
                elif kind in ("session.output_transcript.delta", "session.input_transcript.delta"):
                    delta = event.get("delta", "")
                    self.record(kind, text=delta, target=self.target)
                    if kind == "session.input_transcript.delta" and self.on_input:
                        await self.on_input(delta)
                elif kind == "session.closed":
                    self.record(kind)
                    break
                elif kind == "error":
                    self.record(kind, error=event.get("error"))
                    print(f"[{self.label}] error: {json.dumps(event.get('error'), ensure_ascii=False)[:300]}")
                else:
                    self.record(kind, raw=json.dumps(event, ensure_ascii=False)[:300])
        except websockets.ConnectionClosed as e:
            self.record("socket.closed", code=e.code, reason=str(e.reason)[:200])
            print(f"[{self.label}] socket closed: {e.code} {e.reason}")
        finally:
            self.ready.set()
            self.closed.set()

    async def append(self, pcm):
        if self.ws and not self.closed.is_set():
            await self.ws.send(json.dumps({
                "type": "session.input_audio_buffer.append",
                "audio": base64.b64encode(pcm).decode(),
            }))

    async def close(self):
        if self.ws and not self.closed.is_set():
            await self.ws.send(json.dumps({"type": "session.close"}))
            try:
                await asyncio.wait_for(self.closed.wait(), 15)
            except asyncio.TimeoutError:
                pass
            await self.ws.close()


async def stream(sessions, pcm, rate, clock_start):
    chunk = int(rate * CHUNK_S) * 2
    audio = pcm + b"\x00\x00" * int(rate * TAIL_SILENCE_S)
    for i in range(0, len(audio), chunk):
        # Pace against an absolute schedule so audio time == wall time.
        due = clock_start + (i / 2 / rate)
        delay = due - time.monotonic()
        if delay > 0:
            await asyncio.sleep(delay)
        piece = audio[i:i + chunk]
        await asyncio.gather(*(s.append(piece) for s in sessions))


async def run(mode):
    meta = json.load(open(os.path.join(OUT, "conversation.json")))
    with wave.open(os.path.join(OUT, "conversation.wav")) as w:
        rate = w.getframerate()
        pcm = w.readframes(w.getnframes())

    key = api_key()
    log = []
    t0 = [0.0]
    clock = lambda: time.monotonic() - t0[0]

    if mode == "dual":
        sessions = [Session("to-en", "en", key, clock, log), Session("to-zh", "zh", key, clock, log)]
    elif mode == "switch":
        sessions = [Session("single", "zh", key, clock, log)]
        s = sessions[0]
        state = {"text": "", "last": -1.0}

        async def on_input(delta):
            now = clock()
            if now - state["last"] > SEGMENT_GAP_S:
                state["text"] = ""
            state["last"] = now
            state["text"] += delta
            lang = script_lang(state["text"])
            if lang and lang == s.target:
                await s.set_target("en" if lang == "zh" else "zh")

        s.on_input = on_input
    elif mode == "predict":
        # Like switch, but conversations alternate: once the speaker pauses,
        # pre-flip the target so the next person's first words already go
        # the right way. The transcript check still corrects a wrong guess.
        sessions = [Session("single", "zh", key, clock, log)]
        s = sessions[0]
        state = {"text": "", "last": -1.0, "lang": None}

        async def on_input(delta):
            now = clock()
            if now - state["last"] > SEGMENT_GAP_S:
                state["text"] = ""
            state["last"] = now
            state["text"] += delta
            lang = script_lang(state["text"])
            if lang:
                state["lang"] = lang
                if lang == s.target:
                    await s.set_target("en" if lang == "zh" else "zh")

        async def predictor():
            while True:
                await asyncio.sleep(0.05)
                lang = state["lang"]
                # The speaker paused: expect the other person next.
                if lang and clock() - state["last"] > PREDICT_PAUSE_S and s.target != lang:
                    await s.set_target(lang)
                    state["lang"] = None

        s.on_input = on_input
        asyncio.get_event_loop().call_soon(lambda: asyncio.ensure_future(predictor()))
    else:
        sys.exit("mode must be dual, switch or predict")

    t0[0] = time.monotonic()
    connect_started = clock()
    await asyncio.gather(*(s.connect() for s in sessions))
    await asyncio.gather(*(asyncio.wait_for(s.ready.wait(), 10) for s in sessions))
    print(f"connected {len(sessions)} session(s) in {clock() - connect_started:.2f}s")

    t0[0] = time.monotonic()  # audio clock starts at first chunk
    for s in sessions:
        s.record("client.audio_start")
    await stream(sessions, pcm, rate, t0[0])
    await asyncio.gather(*(s.close() for s in sessions))

    path = os.path.join(OUT, f"{mode}-events.jsonl")
    with open(path, "w") as f:
        for e in log:
            f.write(json.dumps(e, ensure_ascii=False) + "\n")
    print(f"wrote {path} ({len(log)} events)\n")
    report(mode, meta["turns"], log, [s.label for s in sessions])


def segments(log, session, kind):
    """Groups deltas into segments separated by gaps."""
    out = []
    for e in log:
        if e["session"] != session or e["type"] != kind:
            continue
        if out and e["t"] - out[-1]["last"] <= SEGMENT_GAP_S:
            out[-1]["text"] += e.get("text", "")
            out[-1]["last"] = e["t"]
        else:
            out.append({"first": e["t"], "last": e["t"], "text": e.get("text", ""), "target": e.get("target")})
    return out


def turn_for(turns, t):
    owner = None
    for turn in turns:
        if turn["start"] <= t:
            owner = turn
    return owner


def report(mode, turns, log, labels):
    rows = {t["index"]: {"turn": t, "outputs": []} for t in turns}
    for label in labels:
        for seg in segments(log, label, "session.output_transcript.delta"):
            turn = turn_for(turns, seg["first"])
            if turn:
                rows[turn["index"]]["outputs"].append({**seg, "session": label})
        first_audio = {}
        for e in log:
            if e["session"] == label and e["type"] == "session.output_audio.delta":
                turn = turn_for(turns, e["t"])
                if turn and (label, turn["index"]) not in first_audio:
                    first_audio[(label, turn["index"])] = e["t"]

    correct_lat, leaks, missing = [], 0, 0
    print(f"=== {mode}: per turn (latency = first translated text minus end of speech; negative = while still speaking)")
    for idx, row in rows.items():
        t = row["turn"]
        want = "zh" if t["lang"] == "en" else "en"
        print(f"\n#{idx} [{t['lang']}] {t['text']}")
        good = [o for o in row["outputs"] if script_lang(o["text"]) == want]
        bad = [o for o in row["outputs"] if script_lang(o["text"]) != want]
        for o in row["outputs"]:
            lang = script_lang(o["text"])
            tag = "OK  " if lang == want else "LEAK"
            print(f"   {tag} {o['session']:>6} {o['first'] - t['end']:+.2f}s  {o['text'][:90]}")
        if good:
            correct_lat.append(min(o["first"] for o in good) - t["end"])
        else:
            missing += 1
            print("   MISSING translation")
        leaks += len(bad)

    switches = [e for e in log if e["type"] == "client.set_target"]
    print("\n=== summary")
    print(f"turns: {len(turns)}  translated: {len(turns) - missing}  missing: {missing}  leak segments: {leaks}")
    if correct_lat:
        print(f"first-text latency vs end of speech: median {statistics.median(correct_lat):+.2f}s, "
              f"best {min(correct_lat):+.2f}s, worst {max(correct_lat):+.2f}s")
    if mode == "switch":
        print(f"target switches sent: {len(switches)}")
    errors = [e for e in log if e["type"] in ("error", "socket.closed")]
    if errors:
        print(f"errors/closes: {len(errors)} (see events file)")
    other = sorted({e["type"] for e in log if e["type"] not in (
        "session.output_transcript.delta", "session.input_transcript.delta", "session.output_audio.delta",
        "session.created", "session.closed", "client.audio_start", "client.set_target")})
    if other:
        print(f"other event types seen: {', '.join(other)}")


if __name__ == "__main__":
    asyncio.run(run(sys.argv[1] if len(sys.argv) > 1 else "dual"))
