"""Compares text translators for the Voxtral pipeline: Mistral (what the app
uses today) against DeepSeek Flash through Cloudflare AI Gateway.

Each turn is sent the way MistralTranslator sends it: the same system prompt,
the previous 3 turns as user/assistant context, streaming, temperature 0.2,
max_tokens 400. Context uses the reference translations below so every model
sees identical history.

Measured per request:
  ttft   time from sending the request to the first translated token
  total  time until the stream ends
  chrF   character n-gram F-score against the reference (0-100). A rough
         signal only; read the side-by-side output in the report too.
  wrong  the output isn't in the target language (echo or leak)

    python3 translate_probe.py              # 3 trials, both models
    python3 translate_probe.py -n 5 --direct   # also DeepSeek without the gateway

Settings come from the environment or Tools/probe/.env.local (gitignored):
  MISTRAL_API_KEY
  MISTRAL_MODEL       default mistral-small-latest
  CF_ACCOUNT_ID, CF_GATEWAY_ID
  CF_AIG_TOKEN        only for an authenticated gateway
  DEEPSEEK_API_KEY    omit if the gateway stores the DeepSeek key itself
  DEEPSEEK_MODEL      default deepseek-flash, which DeepSeek points at its latest Flash

Keys are never printed. The report goes to out/translate-report.md and raw
results to out/translate-results.jsonl.
"""
import argparse
import json
import os
import statistics
import sys
import time
import urllib.error
import urllib.request
from collections import Counter

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, "out")

MISTRAL_URL = "https://api.mistral.ai/v1/chat/completions"
DEEPSEEK_URL = "https://api.deepseek.com/chat/completions"
GATEWAY_URL = "https://gateway.ai.cloudflare.com/v1/{account}/{gateway}/deepseek/chat/completions"

NAMES = {"en": "English", "zh": "Simplified Chinese"}

# (source language, text, reference translation). The first ten are the
# scripted conversation from make_conversation.py; the rest are the cases
# live transcripts produce: no punctuation, cut off mid-sentence, numbers,
# names and units.
TURNS = [
    ("en", "Hi! Is this the right place for the bus to the airport?", "你好！去机场的大巴是在这里坐吗？"),
    ("zh", "是的，就在这里。不过下一班车大概二十分钟以后才到。", "Yes, it's right here. But the next bus won't come for about twenty minutes."),
    ("en", "Twenty minutes is fine. Do I pay on the bus or buy a ticket first?", "二十分钟没问题。是上车付钱还是要先买票？"),
    ("zh", "可以直接上车刷卡，也可以用微信或者支付宝扫码。", "You can just tap your card on the bus, or scan the code with WeChat or Alipay."),
    ("en", "Okay.", "好的。"),
    ("zh", "好的。", "Okay."),
    ("zh", "你是第一次来上海吗？我们去Starbucks坐一下吧。", "Is this your first time in Shanghai? Let's go sit at Starbucks for a bit."),
    ("en", "Yes, it's my first time. I'm here for a conference at the Expo Center.", "是的，第一次来。我是来世博中心参加一个会议的。"),
    ("en", "Do you know if the metro runs late at night?", "你知道地铁晚上开到很晚吗？"),
    ("zh", "地铁一般到晚上十一点左右，周末会晚一点。", "The metro usually runs until around 11 p.m., a bit later on weekends."),
    ("en", "so my flight is at seven forty tomorrow morning from Pudong and I need to be there by like", "我的航班是明天早上七点四十从浦东起飞，我得在大概"),
    ("zh", "那你最好六点前出门因为早上这条线有点堵", "Then you'd better leave before six, because this route gets a bit congested in the morning."),
    ("en", "My colleague Dr. Wang said the taxi was about 180 yuan and took 45 minutes.", "我同事王医生说打车大概180块，用了45分钟。"),
    ("zh", "我叫李明，电话是一三九零一二三四五六七，有事给我打电话。", "My name is Li Ming, my number is 139 0123 4567. Call me if you need anything."),
    ("en", "Wait, sorry, what was the, um, the name of that station again?", "等等，不好意思，那个，那个站叫什么名字来着？"),
    ("zh", "就是那个……嗯……二号线的那个", "It's that... um... the one on Line 2"),
]

SYSTEM = (
    "You are a live interpreter between {source} and {target} in a spoken, face-to-face "
    "conversation. Translate the user's message into {target}. The text is a speech transcript and "
    "may be unpunctuated or end mid-sentence; translate it naturally, as a person would say it, and "
    "don't complete unfinished thoughts. Keep names, numbers and units exact. Reply with the "
    "translation only: no quotes, notes or romanization."
)


def load_env():
    env = {}
    path = os.path.join(HERE, ".env.local")
    if os.path.exists(path):
        for line in open(path):
            if "=" in line and not line.lstrip().startswith("#"):
                k, v = line.split("=", 1)
                env[k.strip()] = v.strip()
    env.update({k: v.strip() for k, v in os.environ.items()})
    return env


def build_targets(env, direct):
    targets = []
    if env.get("MISTRAL_API_KEY"):
        targets.append({
            "label": "mistral",
            "url": MISTRAL_URL,
            "model": env.get("MISTRAL_MODEL", "mistral-small-latest"),
            "headers": {"Authorization": f"Bearer {env['MISTRAL_API_KEY']}"},
            "extra": {},
        })
    else:
        print("MISTRAL_API_KEY not set; skipping Mistral", file=sys.stderr)

    model = env.get("DEEPSEEK_MODEL", "deepseek-flash")
    # Live translation needs a fast first token, so turn reasoning off.
    extra = {"thinking": {"type": "disabled"}}
    if env.get("CF_ACCOUNT_ID") and env.get("CF_GATEWAY_ID"):
        headers = {}
        if env.get("DEEPSEEK_API_KEY"):
            headers["Authorization"] = f"Bearer {env['DEEPSEEK_API_KEY']}"
        if env.get("CF_AIG_TOKEN"):
            headers["cf-aig-authorization"] = f"Bearer {env['CF_AIG_TOKEN']}"
        targets.append({
            "label": "deepseek-gateway",
            "url": GATEWAY_URL.format(account=env["CF_ACCOUNT_ID"], gateway=env["CF_GATEWAY_ID"]),
            "model": model,
            # Bypass the gateway cache so repeated trials measure the model.
            "headers": {**headers, "cf-aig-skip-cache": "true"},
            "extra": extra,
        })
    else:
        print("CF_ACCOUNT_ID/CF_GATEWAY_ID not set; skipping DeepSeek via AI Gateway", file=sys.stderr)
    if direct:
        if env.get("DEEPSEEK_API_KEY"):
            targets.append({
                "label": "deepseek-direct",
                "url": DEEPSEEK_URL,
                "model": model,
                "headers": {"Authorization": f"Bearer {env['DEEPSEEK_API_KEY']}"},
                "extra": extra,
            })
        else:
            print("--direct needs DEEPSEEK_API_KEY; skipping", file=sys.stderr)
    if not targets:
        sys.exit("Nothing to run. See the settings at the top of translate_probe.py.")
    return targets


def messages_for(index):
    lang, text, _ = TURNS[index]
    target = "zh" if lang == "en" else "en"
    messages = [{"role": "system", "content": SYSTEM.format(source=NAMES[lang], target=NAMES[target])}]
    for _, prev_text, prev_ref in TURNS[max(0, index - 3):index]:
        messages.append({"role": "user", "content": prev_text})
        messages.append({"role": "assistant", "content": prev_ref})
    messages.append({"role": "user", "content": text})
    return messages, target


def translate(target, messages):
    body = {
        "model": target["model"],
        "messages": messages,
        "stream": True,
        "temperature": 0.2,
        "max_tokens": 400,
        **target["extra"],
    }
    request = urllib.request.Request(
        target["url"],
        data=json.dumps(body).encode(),
        headers={**target["headers"], "Content-Type": "application/json", "Accept": "text/event-stream"},
        method="POST",
    )
    start = time.perf_counter()
    ttft = None
    output, reasoning, served = "", "", None
    try:
        with urllib.request.urlopen(request, timeout=30) as response:
            for raw in response:
                line = raw.decode("utf-8", "replace").strip()
                if not line.startswith("data:"):
                    continue
                payload = line[5:].strip()
                if payload == "[DONE]":
                    break
                try:
                    chunk = json.loads(payload)
                except json.JSONDecodeError:
                    continue
                served = served or chunk.get("model")
                choices = chunk.get("choices") or []
                delta = choices[0].get("delta", {}) if choices else {}
                reasoning += delta.get("reasoning_content") or ""
                content = delta.get("content") or ""
                if content:
                    if ttft is None:
                        ttft = time.perf_counter() - start
                    output += content
    except urllib.error.HTTPError as e:
        detail = e.read().decode("utf-8", "replace")[:300]
        return {"error": f"HTTP {e.code}: {detail}"}
    except Exception as e:
        return {"error": f"{type(e).__name__}: {e}"}
    return {
        "ttft": ttft,
        "total": time.perf_counter() - start,
        "output": output.strip(),
        "served_model": served,
        "reasoning_chars": len(reasoning),
    }


def script_lang(text):
    han = sum(1 for c in text if "一" <= c <= "鿿" or "㐀" <= c <= "䶿")
    latin = sum(1 for c in text if c.isascii() and c.isalpha())
    if han == 0 and latin == 0:
        return None
    return "zh" if han >= latin / 4 else "en"


def chrf(hypothesis, reference, n=6, beta=2.0):
    """chrF on characters with whitespace removed, so it works for Chinese too."""
    hyp = "".join(hypothesis.lower().split())
    ref = "".join(reference.lower().split())
    precisions, recalls = [], []
    for k in range(1, n + 1):
        h = Counter(hyp[i:i + k] for i in range(len(hyp) - k + 1))
        r = Counter(ref[i:i + k] for i in range(len(ref) - k + 1))
        if not h or not r:
            continue
        overlap = sum((h & r).values())
        precisions.append(overlap / sum(h.values()))
        recalls.append(overlap / sum(r.values()))
    if not precisions:
        return 0.0
    p, r = statistics.mean(precisions), statistics.mean(recalls)
    if p == 0 and r == 0:
        return 0.0
    return 100 * (1 + beta ** 2) * p * r / (beta ** 2 * p + r)


def percentile(values, q):
    values = sorted(values)
    if not values:
        return None
    k = (len(values) - 1) * q
    lo, hi = int(k), min(int(k) + 1, len(values) - 1)
    return values[lo] + (values[hi] - values[lo]) * (k - lo)


def ms(seconds):
    return "–" if seconds is None else f"{seconds * 1000:.0f} ms"


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("-n", "--trials", type=int, default=3, help="requests per turn per model (default 3)")
    parser.add_argument("--direct", action="store_true", help="also call DeepSeek's API without the gateway")
    args = parser.parse_args()

    targets = build_targets(load_env(), args.direct)
    os.makedirs(OUT, exist_ok=True)

    # One untimed request each, so the first measured turn doesn't pay for DNS and TLS warmup.
    for target in targets:
        result = translate(target, messages_for(0)[0])
        if "error" in result:
            sys.exit(f"{target['label']} failed: {result['error']}")
        print(f"{target['label']}: served by {result['served_model']}")

    results = []
    with open(os.path.join(OUT, "translate-results.jsonl"), "w") as log:
        for trial in range(args.trials):
            for index, (lang, text, reference) in enumerate(TURNS):
                messages, target_lang = messages_for(index)
                # Alternate the order so neither model always goes first.
                order = targets if (trial + index) % 2 == 0 else list(reversed(targets))
                for target in order:
                    result = translate(target, messages)
                    result.update(label=target["label"], trial=trial, turn=index, target_lang=target_lang)
                    if "error" not in result:
                        result["chrf"] = chrf(result["output"], reference)
                        result["wrong_language"] = script_lang(result["output"]) not in (target_lang, None)
                    results.append(result)
                    log.write(json.dumps(result, ensure_ascii=False) + "\n")
                    status = result.get("error") or f"{ms(result['ttft'])}  {result['output']}"
                    print(f"[{trial}:{index:2}] {target['label']:17} {status}")

    write_report(targets, results)


def write_report(targets, results):
    lines = ["# Translation probe", "", f"{len(TURNS)} turns, {max(r['trial'] for r in results) + 1} trials.", ""]
    lines += ["| Model | Served as | Median TTFT | p90 TTFT | Median total | Mean chrF | Wrong language | Errors | Reasoning chars |",
              "|---|---|---|---|---|---|---|---|---|"]
    for target in targets:
        mine = [r for r in results if r["label"] == target["label"]]
        ok = [r for r in mine if "error" not in r]
        ttfts = [r["ttft"] for r in ok if r["ttft"] is not None]
        served = sorted({r["served_model"] for r in ok if r["served_model"]})
        lines.append(
            f"| {target['label']} | {', '.join(served) or target['model']} | {ms(statistics.median(ttfts) if ttfts else None)} "
            f"| {ms(percentile(ttfts, 0.9))} | {ms(statistics.median([r['total'] for r in ok]) if ok else None)} "
            f"| {statistics.mean([r['chrf'] for r in ok]):.1f} | {sum(r['wrong_language'] for r in ok)} "
            f"| {len(mine) - len(ok)} | {sum(r['reasoning_chars'] for r in ok)} |"
            if ok else f"| {target['label']} | {target['model']} | – | – | – | – | – | {len(mine)} | – |"
        )
    lines += ["", "## Side by side (trial 0)", ""]
    for index, (lang, text, reference) in enumerate(TURNS):
        lines += [f"**{index}. {lang} →** {text}", "", f"- reference: {reference}"]
        for target in targets:
            r = next((r for r in results if r["label"] == target["label"] and r["turn"] == index and r["trial"] == 0), None)
            if r is None:
                continue
            shown = r.get("error") or f"{r['output']}  _(chrF {r['chrf']:.0f}, {ms(r['ttft'])})_"
            lines.append(f"- {target['label']}: {shown}")
        lines.append("")
    path = os.path.join(OUT, "translate-report.md")
    with open(path, "w") as f:
        f.write("\n".join(lines))
    print(f"\nReport: {path}")


if __name__ == "__main__":
    main()
