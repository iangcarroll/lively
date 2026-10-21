# Translation engine benchmark: 2026-10-20

The audio is the 10-turn scripted EN/ZH conversation from `make_conversation.py`: 45 s, macOS Samantha/Tingting voices, clean audio, streamed in real time.

**Latency** is the time from the end of each turn's speech to the first correct translated text, as a median. A negative number means the translation started while the person was still speaking.

| Engine / mode | Translated | Leaks (wrong-language or echoed output) | Made-up text in silence | Median latency | Slowest turn | Connections | Cost |
|---|---|---|---|---|---|---|---|
| **Soniox `stt-rt-v5` two-way** | **10/10** | **0** | none | −1.51 s | **+0.34 s** | 1 | $0.12/hr |
| OpenAI `gpt-realtime-translate`, two sessions, raw | 7/10* | 5 | yes | −3.06 s | +0.07 s | 2 | ~$4/hr |
| OpenAI, two sessions + client filter (`dual_filter.py`) | 9/10 | 1 (2 chars) | trimmed | −3.06 s | +0.07 s | 2 | ~$4/hr |
| OpenAI, one session, switch target on detected language | 8/10 | 0 | none | −1.17 s | +0.24 s | 1 | ~$2/hr |
| OpenAI, one session, pre-flip target on pause | 7/10 | 1 | invented sentences | −3.03 s | −2.53 s | 1 | ~$2/hr |

\* In the raw two-session run, one turn's translation was counted inside the previous turn's echo, so the real count is about 8/10.

## Observations

**OpenAI, two sessions**
- The →English session never spoke over English.
- The →中文 session often echoed Chinese input back in Chinese.
- During trailing silence it invented a sentence ("啊真好我累了…").
- The filter removes these echoes by checking the language of the same session's source transcript, and drops output that comes more than 2 s after that source text stops. Filtering by content overlap failed, because a Chinese translation of English legitimately shares characters with recent Chinese speech on the same topic.

**OpenAI, one session switching target**
- Changing the target with `session.update` mid-session works.
- The switch fires about 1 s into each turn, so the opening words of a turn are lost or garbled ("是的，就在这里" dropped; "在车上" came out as "在Busradar上").

**OpenAI, pre-flipping the target on a pause**
- This produced invented translations ("Cast iron is usually…", "为了公平起见"). Don't use it.

**Soniox**
- Translations arrive only as final tokens, one per sentence or clause. There are no provisional translation tokens.
- Translation quality was the best of all runs: proper punctuation, the "Okay"/"好的" turns handled, and the Starbucks code-switch handled.
- `max_endpoint_delay_ms` of 500 vs 1000 made no difference: median −1.52 s vs −1.51 s.
- Header auth (`Authorization: Bearer`), which is what the app uses, works.

## Caveats

- These are synthetic TTS voices in clean audio, with no noise, accents, overlapping speech or bad networks. Re-run with a real recording before deciding.
- One run per mode, so expect variance of a few hundred ms.

## Reproduce

```bash
python3 make_conversation.py
python openai_probe.py dual|switch|predict
python dual_filter.py
python soniox_probe.py [endpoint_ms]
```

These need `websockets`. Keys go in `.env.local`, which is gitignored.
