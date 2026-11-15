#!/usr/bin/env python3
"""Ask Gemini to draft beats for each trimmed clip (video understanding), for human correction.

    .venv/bin/pip install google-genai
    .venv/bin/python draft_beats.py                 # all clips in clips.json
    .venv/bin/python draft_beats.py tos-crush       # one clip

Reads GEMINI_API_KEY (and optional GEMINI_MODEL) from the environment or ../server/.env.
Writes work/<clip_id>.beats_draft.json and prints a side-by-side with the hand-authored beats
in clips.json. It never overwrites clips.json: copy what you agree with into prep.py's CONFIG
(beats live there) and re-run `prep.py json`. Gemini samples video at ~1 fps, so check every `t`.
"""
from __future__ import annotations

import json
import os
import re
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
PROMPT_MD = HERE.parent / "prompts" / "beats_draft.md"
DEFAULT_MODEL = "gemini-4-hydrogen"  # current stable Flash per https://aistudio.google.com/docs/models (Nov 2026)


def load_env():
    env = HERE.parent / "server" / ".env"
    if env.exists():
        for line in env.read_text().splitlines():
            m = re.match(r"\s*([A-Z_][A-Z0-9_]*)\s*=\s*(.*?)\s*$", line)
            if m and not line.lstrip().startswith("#"):
                os.environ.setdefault(m.group(1), m.group(2).strip('"').strip("'"))


def load_prompt():
    md = PROMPT_MD.read_text()
    prompt = md.split("\n---\n")[1].strip()          # text between the first two '---' rules
    schema = json.loads(re.search(r"```json\n(.*?)```", md, re.S).group(1))
    return prompt, schema


def main():
    load_env()
    key = os.environ.get("GEMINI_API_KEY")
    if not key:
        sys.exit("GEMINI_API_KEY not set (env or ../server/.env)")
    from google import genai
    from google.genai import types

    client = genai.Client(api_key=key)
    model = os.environ.get("GEMINI_MODEL") or DEFAULT_MODEL
    prompt_t, schema = load_prompt()
    clips = json.loads((HERE / "clips.json").read_text())
    only = set(sys.argv[1:])
    (HERE / "work").mkdir(exist_ok=True)

    for c in clips:
        if only and c["clip_id"] not in only:
            continue
        wins = ", ".join(f"{w['start']:.2f}–{w['end']:.2f}" for w in c["speech_windows"])
        prompt = prompt_t.replace("{speech_windows}", wins).replace("{duration}", f"{c['duration']:.2f}")
        video = (HERE / c["video_file"]).read_bytes()  # ~4 MB: inline is fine (< 20 MB request limit)
        resp = client.models.generate_content(
            model=model,
            contents=[types.Part.from_bytes(data=video, mime_type="video/mp4"), prompt],
            config=types.GenerateContentConfig(
                temperature=0.2,
                response_mime_type="application/json",
                response_schema=schema,
            ),
        )
        draft = json.loads(resp.text)["beats"]
        (HERE / "work" / f"{c['clip_id']}.beats_draft.json").write_text(json.dumps(draft, indent=2))
        print(f"\n== {c['clip_id']} ({model})")
        print("  GEMINI DRAFT:")
        for b in draft:
            print(f"    {b['t']:5.1f}  {b['emotion']:<10} {b['desc']}")
        print("  HAND-AUTHORED (clips.json):")
        for b in c["beats"]:
            print(f"    {b['t']:5.1f}  {b['emotion']:<10} {b['desc']}")


if __name__ == "__main__":
    main()
