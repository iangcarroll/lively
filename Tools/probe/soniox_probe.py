"""Benchmarks Soniox stt-rt-v5 two-way translation (one stream, EN<->ZH) on the
scripted conversation, with the same config Lively's SonioxTranscriber sends.

    python soniox_probe.py

Reports twice: final translation tokens (what stays on screen) and
provisional ones (what the app can show first). Key comes from
SONIOX_API_KEY or Tools/probe/.env.local and is never printed.
"""
import asyncio
import json
import os
import sys
import time
import wave

import websockets

from openai_probe import CHUNK_S, OUT, TAIL_SILENCE_S, report

HERE = os.path.dirname(os.path.abspath(__file__))
URL = "wss://stt-rt.soniox.com/transcribe-websocket"


def api_key():
    if os.environ.get("SONIOX_API_KEY"):
        return os.environ["SONIOX_API_KEY"].strip()
    path = os.path.join(HERE, ".env.local")
    if os.path.exists(path):
        for line in open(path):
            if line.startswith("SONIOX_API_KEY="):
                return line.split("=", 1)[1].strip()
    sys.exit("Set SONIOX_API_KEY or add it to Tools/probe/.env.local")


async def run(endpoint_delay_ms):
    meta = json.load(open(os.path.join(OUT, "conversation.json")))
    with wave.open(os.path.join(OUT, "conversation.wav")) as w:
        rate = w.getframerate()
        pcm = w.readframes(w.getnframes())

    key = api_key()
    log = []
    t0 = [time.monotonic()]
    clock = lambda: time.monotonic() - t0[0]
    seen_provisional = set()

    connect_started = time.monotonic()
    ws = await websockets.connect(URL, additional_headers={"Authorization": f"Bearer {key}"}, max_size=None)
    await ws.send(json.dumps({
        "model": "stt-rt-v5",
        "audio_format": "pcm_s16le",
        "sample_rate": rate,
        "num_channels": 1,
        "language_hints": ["en", "zh"],
        "enable_language_identification": True,
        "enable_endpoint_detection": True,
        "max_endpoint_delay_ms": endpoint_delay_ms,
        "translation": {"type": "two_way", "language_a": "en", "language_b": "zh"},
    }))
    print(f"connected in {time.monotonic() - connect_started:.2f}s (endpoint delay {endpoint_delay_ms} ms)")

    async def reader():
        async for raw in ws:
            msg = json.loads(raw)
            if "error_code" in msg:
                print(f"error {msg['error_code']}: {msg.get('error_message')}")
                log.append({"t": round(clock(), 3), "session": "soniox", "type": "error", "error": msg})
                return
            for tok in msg.get("tokens", []):
                text = tok.get("text", "")
                if text in ("<end>", "<fin>"):
                    if tok.get("is_final"):
                        log.append({"t": round(clock(), 3), "session": "soniox", "type": "endpoint"})
                    continue
                is_translation = tok.get("translation_status") == "translation"
                if tok.get("is_final"):
                    kind = "session.output_transcript.delta" if is_translation else "session.input_transcript.delta"
                    log.append({"t": round(clock(), 3), "session": "soniox", "type": kind, "text": text,
                                "lang": tok.get("language")})
                elif is_translation:
                    # Provisional tokens repeat until final; record first sighting of each position.
                    marker = (tok.get("start_ms"), text)
                    if marker not in seen_provisional:
                        seen_provisional.add(marker)
                        log.append({"t": round(clock(), 3), "session": "provisional",
                                    "type": "session.output_transcript.delta", "text": text})
            if msg.get("finished"):
                return

    reading = asyncio.create_task(reader())
    t0[0] = time.monotonic()
    chunk = int(rate * CHUNK_S) * 2
    audio = pcm + b"\x00\x00" * int(rate * TAIL_SILENCE_S)
    for i in range(0, len(audio), chunk):
        delay = t0[0] + i / 2 / rate - time.monotonic()
        if delay > 0:
            await asyncio.sleep(delay)
        await ws.send(audio[i:i + chunk])
    await ws.send("")  # end of audio
    try:
        await asyncio.wait_for(reading, 15)
    except asyncio.TimeoutError:
        pass
    await ws.close()

    path = os.path.join(OUT, f"soniox-{endpoint_delay_ms}-events.jsonl")
    with open(path, "w") as f:
        for e in log:
            f.write(json.dumps(e, ensure_ascii=False) + "\n")
    print(f"wrote {path} ({len(log)} events)\n")
    report(f"soniox final (endpoint {endpoint_delay_ms} ms)", meta["turns"], log, ["soniox"])
    print()
    provisional = [e for e in log if e["session"] == "provisional"]
    report(f"soniox provisional (endpoint {endpoint_delay_ms} ms)", meta["turns"], provisional, ["provisional"])


if __name__ == "__main__":
    asyncio.run(run(int(sys.argv[1]) if len(sys.argv) > 1 else 1000))
