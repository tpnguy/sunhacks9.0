"""Pretty-prints DubStudio server logs piped from `aws logs tail` (used by logs.sh)."""
import json
import sys

C, G, R, Y, X = "\033[1;36m", "\033[1;32m", "\033[1;31m", "\033[33m", "\033[0m"

for line in sys.stdin:
    _, _, rest = line.partition(" ")
    try:
        d = json.loads(rest)
    except ValueError:
        print(line.rstrip())
        continue
    m = d.get("msg", "")
    if m == "take_received":
        print(f"\n{C}▶ TAKE {d['take_id'][:8]}{X} {d['clip_id']} by {d['nickname']}")
        print(f"  audio : {d['audio_bytes']} bytes, mime={d['audio_mime']} -> gemini {d['gemini_mime']}")
        print(f"  sniff : {d['audio_sniff']}")
        print(f"  vad   : {d['vad_raw_count']} raw segs -> {d['vad_clean']}")
        print(f"  ref   : {d['speech_windows']}")
        print(f"  timing: {d['timing']}   (inspect audio: ./logs.sh --audio {d['take_id']})")
    elif m == "take_scored_detail":
        c = G if d["scored_by"] == "gemini" else R
        print(f"  {c}scored_by={d['scored_by']}{X} timing={d['timing']} emotion={d['emotion']} "
              f"comedy={d['comedy']} overall={d['overall']} ({d['ms']} ms)")
        print(f"  roast : {d['roast']}")
    elif "gemini" in m:
        print(f"  {Y}{m}{X} call={d.get('call', '')} attempt={d.get('attempt', '')}: {d.get('err', '')}")
    elif d.get("level") in ("WARN", "ERROR"):
        print(f"  {Y}{d['level']}{X} {m}: {d.get('err', '')}")
    sys.stdout.flush()
