"""Replays a recorded `dual` run through the client-side filter Lively would use
to merge two gpt-realtime-translate sessions into one conversation:

  1. Echo filter: drop a session's translated text while that same session's
     source transcript is already in the session's target language.
  2. Silence filter: drop translated text arriving more than IDLE_S after the
     session's source transcript last moved (kills hallucinations in silence).

    python dual_filter.py [out/dual-events.jsonl]
"""
import json
import os
import sys

from openai_probe import OUT, report, script_lang

IDLE_S = 2.0
# The current source sentence: input deltas within this gap belong together.
SOURCE_GAP_S = 0.9


def filtered(events):
    kept, dropped = [], []
    state = {}  # session -> {"text": current source sentence, "last": t}
    for e in events:
        s = e["session"]
        st = state.setdefault(s, {"text": "", "last": None})
        if e["type"] == "session.input_transcript.delta":
            if st["last"] is None or e["t"] - st["last"] > SOURCE_GAP_S:
                st["text"] = ""
            st["text"] += e["text"]
            st["last"] = e["t"]
            kept.append(e)
        elif e["type"] == "session.output_transcript.delta":
            target = "en" if s == "to-en" else "zh"
            idle = None if st["last"] is None else e["t"] - st["last"]
            # A translation can arrive before its own source text; if the last
            # source sentence has gone quiet, the language is unknown, so keep it.
            source_lang = script_lang(st["text"]) if idle is not None and idle <= SOURCE_GAP_S else None
            if idle is not None and idle > IDLE_S:
                dropped.append(("silence", e))
            elif source_lang == target:
                dropped.append(("echo", e))
            else:
                kept.append(e)
        else:
            kept.append(e)
    return kept, dropped


def main():
    path = sys.argv[1] if len(sys.argv) > 1 else os.path.join(OUT, "dual-events.jsonl")
    events = [json.loads(line) for line in open(path)]
    turns = json.load(open(os.path.join(OUT, "conversation.json")))["turns"]
    kept, dropped = filtered(events)
    print(f"dropped {len(dropped)} output deltas:")
    for reason, group in (("echo", "echo"), ("silence", "silence")):
        text = "".join(e["text"] for r, e in dropped if r == reason)
        print(f"  {reason:8} {text[:160]}")
    print()
    report("dual+filter", turns, kept, ["to-en", "to-zh"])


if __name__ == "__main__":
    main()
