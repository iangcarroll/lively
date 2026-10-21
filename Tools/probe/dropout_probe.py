"""Simulates a network dropout mid-conversation against Soniox stt-rt-v5 and
compares how ResilientSocket recovers held audio (ASIA_LATENCY.md §6.3).

    python dropout_probe.py [drop_at_s] [drop_for_s]     # default 11.5 9

The scripted conversation streams in real time. At drop_at the socket is cut
without ending the stream, as a dead network would. Audio keeps arriving and
is held. After drop_for (detection plus reconnect), recovery runs one of:

- replay:  the old behavior. One new socket gets the whole backlog in a
           burst, then live audio.
- catchup: Lively's behavior. Silence is trimmed out of the backlog. If more
           than 3 s of speech is left, a second socket replays it and ends,
           while live audio goes straight to a fresh socket.
- cap:     the fallback for engines without side streams. Trim, then replay
           only the last 5 s ahead of live audio.

For every turn it reports when its final translation arrived, relative to
when the speaker finished. Key comes from SONIOX_API_KEY or
Tools/probe/.env.local and is never printed.
"""
import asyncio
import json
import math
import os
import sys
import time
import wave

import websockets

from soniox_probe import URL, api_key
from openai_probe import OUT

CHUNK_S = 0.08  # MicCapture.chunkDuration
CATCH_UP_THRESHOLD_S = 3
MAX_REPLAY_S = 5


def trim_silence(chunks):
    """Port of ResilientSocket.trimSilence."""
    if not chunks:
        return []
    levels = [rms(c) for c in chunks]
    floor = sorted(levels)[len(levels) // 5]
    threshold = max(floor * 3, 0.0056)
    speech = [l > threshold for l in levels]
    if not any(speech):
        return []
    pad, max_pause = 3, 10
    keep = [False] * len(chunks)
    for i, s in enumerate(speech):
        if s:
            for j in range(max(0, i - pad), min(len(chunks), i + pad + 1)):
                keep[j] = True
    first = keep.index(True)
    last = len(keep) - 1 - keep[::-1].index(True)
    out, pause = [], 0
    for i in range(first, last + 1):
        if keep[i]:
            pause = 0
            out.append(chunks[i])
        else:
            pause += 1
            if pause <= max_pause - 2 * pad:
                out.append(chunks[i])
    return out


def rms(chunk):
    pcm, _ = chunk
    n = len(pcm) // 2
    if n == 0:
        return 0.0
    total = 0.0
    for i in range(n):
        v = int.from_bytes(pcm[2 * i:2 * i + 2], "little", signed=True) / 32767
        total += v * v
    return math.sqrt(total / n)


class Session:
    """One socket. Tracks which original audio time each sent chunk came from,
    so tokens can be mapped back to turns."""

    def __init__(self, name, rate, key, clock):
        self.name, self.rate, self.key, self.clock = name, rate, key, clock
        self.sent_times = []  # original audio time of each chunk sent
        self.segments = []  # {orig, done, text}
        self.open = None
        self.ws = None
        self.reader = None

    async def connect(self):
        self.ws = await websockets.connect(URL, additional_headers={"Authorization": f"Bearer {self.key}"}, max_size=None)
        await self.ws.send(json.dumps({
            "model": "stt-rt-v5",
            "audio_format": "pcm_s16le",
            "sample_rate": self.rate,
            "num_channels": 1,
            "language_hints": ["en", "zh"],
            "enable_language_identification": True,
            "enable_endpoint_detection": True,
            "max_endpoint_delay_ms": 1000,
            "translation": {"type": "two_way", "language_a": "en", "language_b": "zh"},
        }))
        self.reader = asyncio.create_task(self.read())

    async def send(self, chunk):
        pcm, orig = chunk
        self.sent_times.append(orig)
        await self.ws.send(pcm)

    def orig_time(self, stream_ms):
        i = min(int(stream_ms / 1000 / CHUNK_S), len(self.sent_times) - 1)
        return self.sent_times[max(i, 0)]

    async def read(self):
        try:
            async for raw in self.ws:
                msg = json.loads(raw)
                if "error_code" in msg:
                    print(f"  [{self.name}] error {msg['error_code']}: {msg.get('error_message')}")
                    return
                for tok in msg.get("tokens", []):
                    if not tok.get("is_final"):
                        continue
                    text = tok.get("text", "")
                    if text in ("<end>", "<fin>"):
                        self.open = None
                        continue
                    if tok.get("translation_status") == "translation":
                        target = self.open or (self.segments[-1] if self.segments else None)
                        if target:
                            target["done"] = self.clock()
                    elif self.open is None:
                        self.open = {"orig": self.orig_time(tok.get("start_ms", 0)), "done": None}
                        self.segments.append(self.open)
                if msg.get("finished"):
                    return
        except websockets.ConnectionClosed:
            return

    async def end(self):
        await self.ws.send("")

    async def cut(self):
        """A dead network: no end of stream, nothing more read."""
        self.reader.cancel()
        await self.ws.close()


async def run(strategy, drop_at, drop_for, pcm, rate, turns, key):
    t0 = time.monotonic()
    clock = lambda: time.monotonic() - t0
    chunk_bytes = int(rate * CHUNK_S) * 2
    audio = pcm + b"\x00\x00" * int(rate * 6)
    chunks = [(audio[i:i + chunk_bytes], i / 2 / rate) for i in range(0, len(audio), chunk_bytes)]

    sessions = []
    live = Session("live", rate, key, clock)
    await live.connect()
    sessions.append(live)
    t0 = time.monotonic()

    backlog, dropped, recovered = [], False, strategy == "none"
    i = 0
    while i < len(chunks):
        chunk = chunks[i]
        delay = t0 + chunk[1] - time.monotonic()
        if delay > 0:
            await asyncio.sleep(delay)
        i += 1
        now = clock()
        if not dropped and not recovered and now >= drop_at:
            dropped = True
            await live.cut()
        if not dropped or recovered:
            await live.send(chunk)
            continue
        backlog.append(chunk)
        if now < drop_at + drop_for:
            continue

        live = Session("live2", rate, key, clock)
        await live.connect()
        sessions.append(live)
        # Audio kept arriving while that connected.
        while i < len(chunks) and chunks[i][1] <= clock():
            backlog.append(chunks[i])
            i += 1
        held = len(backlog) * CHUNK_S
        if strategy == "replay":
            for c in backlog:
                await live.send(c)
            print(f"  held {held:.1f}s, replayed all of it")
        else:
            speech = trim_silence(backlog)
            seconds = len(speech) * CHUNK_S
            if strategy == "catchup" and seconds > CATCH_UP_THRESHOLD_S:
                catch = Session("catchup", rate, key, clock)
                await catch.connect()
                sessions.append(catch)
                for c in speech:
                    await catch.send(c)
                await catch.end()
                print(f"  held {held:.1f}s, {seconds:.1f}s of speech → catch-up socket")
            else:
                kept = speech[-int(MAX_REPLAY_S / CHUNK_S):]
                for c in kept:
                    await live.send(c)
                print(f"  held {held:.1f}s, {seconds:.1f}s of speech, replayed last {len(kept) * CHUNK_S:.1f}s")
        recovered = True

    await live.end()
    await asyncio.wait([s.reader for s in sessions if s.reader and not s.reader.done()] or [asyncio.sleep(0)], timeout=40)

    rows = []
    for turn in turns:
        dones = [seg["done"] for s in sessions for seg in s.segments
                 if seg["done"] is not None and turn["start"] - 0.3 <= seg["orig"] <= turn["end"]]
        rows.append(None if not dones else max(dones) - turn["end"])
    return rows


async def main():
    drop_at = float(sys.argv[1]) if len(sys.argv) > 1 else 11.5
    drop_for = float(sys.argv[2]) if len(sys.argv) > 2 else 9.0
    meta = json.load(open(os.path.join(OUT, "conversation.json")))
    with wave.open(os.path.join(OUT, "conversation.wav")) as w:
        rate = w.getframerate()
        pcm = w.readframes(w.getnframes())
    key = api_key()
    turns = meta["turns"]

    results = {}
    for strategy in ["none", "replay", "catchup", "cap"]:
        print(f"{strategy}:")
        results[strategy] = await run(strategy, drop_at, drop_for, pcm, rate, turns, key)

    print(f"\nDropout at {drop_at}s for {drop_for}s. Final translation time minus end of speech (s):")
    names = list(results)
    print("turn  span          " + "".join(f"{n:>9}" for n in names))
    for i, turn in enumerate(turns):
        cells = "".join(f"{'—':>9}" if results[n][i] is None else f"{results[n][i]:>+9.2f}" for n in names)
        print(f"{i:>4}  {turn['start']:5.1f}–{turn['end']:5.1f}  {cells}")
    after = [i for i, t in enumerate(turns) if t["start"] >= drop_at + drop_for]
    for n in names:
        lags = [results[n][i] for i in after if results[n][i] is not None]
        missing = sum(results[n][i] is None for i in range(len(turns)))
        mean = sum(lags) / len(lags) if lags else float("nan")
        print(f"{n:>8}: live turns after recovery mean {mean:+.2f}s, worst {max(lags, default=float('nan')):+.2f}s; "
              f"turns with no translation {missing}")


if __name__ == "__main__":
    asyncio.run(main())
