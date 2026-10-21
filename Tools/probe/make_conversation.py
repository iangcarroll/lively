"""Renders a scripted English/Mandarin conversation to one 24 kHz mono PCM16 WAV
with macOS `say`, plus a JSON file of turn timings, so every engine can be
benchmarked on identical audio.

    python3 make_conversation.py [out_dir]
"""
import json
import os
import subprocess
import sys
import tempfile
import wave

RATE = 24_000
GAP_S = 0.9

# (language, text). Includes the edge cases that matter for routing:
# very short turns, a mixed-language turn, and back-to-back same-language turns.
TURNS = [
    ("en", "Hi! Is this the right place for the bus to the airport?"),
    ("zh", "是的，就在这里。不过下一班车大概二十分钟以后才到。"),
    ("en", "Twenty minutes is fine. Do I pay on the bus or buy a ticket first?"),
    ("zh", "可以直接上车刷卡，也可以用微信或者支付宝扫码。"),
    ("en", "Okay."),
    ("zh", "好的。"),
    ("zh", "你是第一次来上海吗？我们去Starbucks坐一下吧。"),
    ("en", "Yes, it's my first time. I'm here for a conference at the Expo Center."),
    ("en", "Do you know if the metro runs late at night?"),
    ("zh", "地铁一般到晚上十一点左右，周末会晚一点。"),
]

VOICES = {"en": "Samantha", "zh": "Tingting"}


def render(text, voice, path):
    subprocess.run(
        ["say", "-v", voice, "-o", path, f"--data-format=LEI16@{RATE}", "--file-format=WAVE", text],
        check=True,
    )
    with wave.open(path) as w:
        assert w.getframerate() == RATE and w.getnchannels() == 1 and w.getsampwidth() == 2
        return w.readframes(w.getnframes())


def main():
    out_dir = sys.argv[1] if len(sys.argv) > 1 else os.path.join(os.path.dirname(__file__), "out")
    os.makedirs(out_dir, exist_ok=True)
    silence = b"\x00\x00" * int(RATE * GAP_S)
    pcm = bytearray(b"\x00\x00" * int(RATE * 0.5))
    turns = []
    with tempfile.TemporaryDirectory() as tmp:
        for i, (lang, text) in enumerate(TURNS):
            frames = render(text, VOICES[lang], os.path.join(tmp, f"{i}.wav"))
            start = len(pcm) / 2 / RATE
            pcm += frames
            end = len(pcm) / 2 / RATE
            turns.append({"index": i, "lang": lang, "text": text, "start": round(start, 3), "end": round(end, 3)})
            pcm += silence

    wav_path = os.path.join(out_dir, "conversation.wav")
    with wave.open(wav_path, "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(RATE)
        w.writeframes(bytes(pcm))
    with open(os.path.join(out_dir, "conversation.json"), "w") as f:
        json.dump({"rate": RATE, "duration": len(pcm) / 2 / RATE, "turns": turns}, f, ensure_ascii=False, indent=1)
    print(f"{wav_path}: {len(pcm) / 2 / RATE:.1f}s, {len(turns)} turns")


if __name__ == "__main__":
    main()
