#!/usr/bin/env python3
"""DubStudio clip prep: download -> trim -> VAD -> clips.json.

Usage (from dubstudio/clips/):
    python3 -m venv .venv && .venv/bin/pip install silero-vad numpy soundfile
    .venv/bin/python prep.py                 # all stages, all clips
    .venv/bin/python prep.py fetch trim      # only some stages
    .venv/bin/python prep.py vad --clip tos-crush
    .venv/bin/python prep.py frames          # dump PNG frames to work/ for beat checking
    .venv/bin/python prep.py explore --clip notld-barbara   # VAD+energy over the whole padded source

Stages:
  fetch  - ffmpeg seeks inside the remote file over HTTP (range requests) and saves
           only a padded window [fetch_start, fetch_start+fetch_dur) to raw/<id>_src.mov
           (high-quality re-encode + PCM audio in .mov, so t=0 is exactly fetch_start).
  trim   - cuts [start, end) (absolute film time) into <id>.mp4: H.264 + AAC, <=1280 wide,
           ~2 Mbps, <=30 fps, +faststart. Original audio is kept.
  vad    - Silero VAD over the trimmed clip's audio -> speech windows, gaps < MERGE_GAP merged,
           windows < MIN_WIN dropped, then an RMS-energy sanity report. Writes work/<id>.vad.json.
           If a clip has `speech_windows_override`, that wins (hand-checked values).
  json   - writes clips.json (API.md shape) from config + VAD + hand-authored beats.
  install - (not in the default run) copies <id>.mp4 + clips.json to ../ios/DubStudio/Clips/.

All timestamps in CLIPS are absolute seconds in the source film; beats are relative to clip start.
"""
from __future__ import annotations

import argparse
import json
import subprocess
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
RAW = HERE / "raw"
WORK = HERE / "work"

MERGE_GAP = 0.30   # merge speech windows separated by less than this (s)
MIN_WIN = 0.25     # drop windows shorter than this (s)

TOS_URL = "https://download.blender.org/demo/movies/ToS/tears_of_steel_720p.mov"
TOS_ATTR = "Tears of Steel (CC-BY 3.0) (c) Blender Foundation | mango.blender.org"
NOTLD_URL = "https://archive.org/download/night_of_the_living_dead_dvd/Night.mp4"
HGF_URL = "https://archive.org/download/his_girl_friday/his_girl_friday.mp4"

# ---------------------------------------------------------------------------
# CONFIG — chosen timestamps (absolute seconds in source), VAD tuning, beats.
# ---------------------------------------------------------------------------
CLIPS: list[dict] = [
    {
        "clip_id": "tos-breakup",
        "title": "Tears of Steel — The Breakup",
        "source_url": TOS_URL,
        "source_page": "https://mango.blender.org/",
        "fetch_start": 18.0, "fetch_dur": 30.0,
        "start": 22.4, "end": 36.4,
        "license": "CC-BY 3.0",
        "attribution": TOS_ATTR,
        "vad": {"threshold": 0.5},
        "beats": [
            {"t": 1.0, "desc": "Celia jabs her robot hand at him: \"You're a jerk, Thom.\"", "emotion": "anger"},
            {"t": 2.0, "desc": "Thom, all self-justifying: \"Look Celia, we have to follow our passions\"", "emotion": "smug"},
            {"t": 5.0, "desc": "Thom gets dreamy: \"...I just want to be awesome in space\"", "emotion": "joy"},
            {"t": 8.1, "desc": "Celia fires back: \"Why don't you just admit you're freaked out by my robot hand?\"", "emotion": "sarcasm"},
            {"t": 12.2, "desc": "Thom splutters a denial: \"I'm not freaked out by— it's...\"", "emotion": "panic"},
        ],
        # Hand-checked: Silero gives (1.04-7.86)(8.08-10.10)(10.22-12.08)(12.20-13.68); all gaps < 0.3 s
        # so it is one continuous argument. Kept merged (motor-mouth clip).
        "speech_windows_override": [[1.04, 13.68]],
    },
    {
        "clip_id": "tos-crush",
        "title": "Tears of Steel — You Broke My Heart",
        "source_url": TOS_URL,
        "source_page": "https://mango.blender.org/",
        "fetch_start": 375.0, "fetch_dur": 30.0,
        "start": 378.6, "end": 392.6,
        "license": "CC-BY 3.0",
        "attribution": TOS_ATTR,
        "vad": {"threshold": 0.5},
        "beats": [
            {"t": 0.0, "desc": "ERROR!!! screens flash red", "emotion": "suspense"},
            {"t": 0.6, "desc": "the scientist screams \"No!\"", "emotion": "panic"},
            {"t": 2.3, "desc": "a second, longer \"Nooo!\"", "emotion": "panic"},
            {"t": 5.0, "desc": "close-up on Celia: \"You broke my heart.\"", "emotion": "sadness"},
            {"t": 7.4, "desc": "Thom, eyes shut in the robot's grip: \"I know.\"", "emotion": "deadpan"},
            {"t": 8.6, "desc": "Celia: \"You forgot me on Earth.\"", "emotion": "anger"},
            {"t": 10.8, "desc": "Thom again: \"I know.\"", "emotion": "deadpan"},
            {"t": 11.9, "desc": "Celia snarls: \"I should just crush you!\"", "emotion": "anger"},
        ],
        # Hand-checked against speech-band energy + Whisper word timings. Silero (music bed) only found
        # 5.48-6.61 / 8.59-10.13 / 11.98-14.02 and missed both "No!"s and both "I know"s.
        "speech_windows_override": [[0.55, 1.15], [2.30, 3.80], [5.00, 6.30], [7.40, 7.85],
                                    [8.55, 9.90], [10.80, 11.20], [11.90, 13.80]],
    },
    {
        "clip_id": "notld-barbara",
        "title": "Night of the Living Dead — They're Coming to Get You",
        "source_url": NOTLD_URL,
        "source_page": "https://archive.org/details/night_of_the_living_dead_dvd",
        "fetch_start": 345.0, "fetch_dur": 40.0,
        "start": 355.5, "end": 369.8,
        "license": "Public Domain (US)",
        "attribution": "Night of the Living Dead (1968, dir. George A. Romero) — public domain | archive.org",
        "vad": {"threshold": 0.5},
        "beats": [
            {"t": 0.7, "desc": "Barbara warns him: \"Johnny.\"", "emotion": "annoyance"},
            {"t": 2.1, "desc": "Johnny teases: \"You're still afraid.\"", "emotion": "mockery"},
            {"t": 3.9, "desc": "Barbara: \"Stop it now. I mean it.\"", "emotion": "anger"},
            {"t": 5.5, "desc": "she turns away; Johnny grins and lets the silence hang", "emotion": "suspense"},
            {"t": 9.8, "desc": "Johnny's spooky voice: \"They're coming to get you, Barbara!\"", "emotion": "mockery"},
            {"t": 12.4, "desc": "cut to the empty graveyard", "emotion": "suspense"},
            {"t": 13.5, "desc": "Barbara, fed up: \"Stop it!\"", "emotion": "anger"},
        ],
    },
    {
        "clip_id": "hgf-reno",
        "title": "His Girl Friday — Six Weeks in Reno",
        "source_url": HGF_URL,
        "source_page": "https://archive.org/details/his_girl_friday",
        "fetch_start": 250.0, "fetch_dur": 40.0,
        "start": 259.8, "end": 273.85,
        "license": "Public Domain (US)",
        "attribution": "His Girl Friday (1940, dir. Howard Hawks) — public domain | archive.org",
        "vad": {"threshold": 0.5},
        "beats": [
            {"t": 0.4, "desc": "Walter, phone in hand, all charm: \"How long is it since we've seen each other?\"", "emotion": "charm"},
            {"t": 3.7, "desc": "Hildy, unimpressed: \"Oh, well, let's see...\"", "emotion": "deadpan"},
            {"t": 5.9, "desc": "Hildy counts it off: \"Six weeks in Reno, then Bermuda... about four months, I guess.\"", "emotion": "deadpan"},
            {"t": 10.1, "desc": "Hildy: \"Seems like yesterday to me.\"", "emotion": "sarcasm"},
            {"t": 12.4, "desc": "back to Walter, unbothered: \"Maybe it was yesterday, Hildy.\"", "emotion": "smug"},
        ],
        # Silero matches Whisper word timings; last window capped before the next line ("Been seeing me...").
        "speech_windows_override": [[0.38, 2.09], [3.70, 5.38], [5.85, 9.42], [10.14, 11.53], [12.41, 13.85]],
    },
]
# ---------------------------------------------------------------------------


def run(cmd: list[str]) -> str:
    r = subprocess.run(cmd, capture_output=True, text=True)
    if r.returncode != 0:
        sys.exit(f"command failed: {' '.join(cmd)}\n{r.stderr[-2000:]}")
    return r.stdout


def src_path(c):
    return RAW / f"{c['clip_id']}_src.mov"


def out_path(c):
    return HERE / f"{c['clip_id']}.mp4"


def fetch(c):
    RAW.mkdir(exist_ok=True)
    p = src_path(c)
    if p.exists():
        print(f"[fetch] {p.name} exists, skipping")
        return
    print(f"[fetch] {c['clip_id']}: {c['fetch_start']}s +{c['fetch_dur']}s from {c['source_url']}")
    run(["ffmpeg", "-nostdin", "-loglevel", "error", "-y",
         "-ss", str(c["fetch_start"]), "-i", c["source_url"], "-t", str(c["fetch_dur"]),
         "-map", "0:v:0", "-map", "0:a:0",
         "-c:v", "libx264", "-crf", "16", "-preset", "fast", "-pix_fmt", "yuv420p",
         "-c:a", "pcm_s16le", str(p)])


def trim(c):
    s = c["start"] - c["fetch_start"]
    d = c["end"] - c["start"]
    print(f"[trim] {c['clip_id']}: {c['start']}–{c['end']} ({d:.2f}s)")
    run(["ffmpeg", "-nostdin", "-loglevel", "error", "-y",
         "-ss", f"{s:.3f}", "-i", str(src_path(c)), "-t", f"{d:.3f}",
         "-map", "0:v:0", "-map", "0:a:0",
         "-vf", "scale='min(1280,iw)':-2:flags=lanczos,setsar=1",
         "-fpsmax", "30",
         "-c:v", "libx264", "-profile:v", "high", "-preset", "slow", "-pix_fmt", "yuv420p",
         "-b:v", "2M", "-maxrate", "2.5M", "-bufsize", "4M",
         "-c:a", "aac", "-b:a", "128k", "-ac", "2", "-ar", "48000",
         "-movflags", "+faststart", str(out_path(c))])


def load_audio_16k(path: Path):
    import numpy as np
    raw = run_bytes(["ffmpeg", "-nostdin", "-loglevel", "error", "-i", str(path),
                     "-vn", "-ac", "1", "-ar", "16000", "-f", "s16le", "-"])
    return np.frombuffer(raw, dtype=np.int16).astype(np.float32) / 32768.0


def run_bytes(cmd):
    r = subprocess.run(cmd, capture_output=True)
    if r.returncode != 0:
        sys.exit(r.stderr.decode()[-2000:])
    return r.stdout


def silero_windows(wav, threshold=0.5, min_speech_ms=200, min_silence_ms=120, pad_ms=40):
    import torch
    from silero_vad import load_silero_vad, get_speech_timestamps
    model = load_silero_vad()
    ts = get_speech_timestamps(torch.from_numpy(wav), model, sampling_rate=16000,
                               threshold=threshold, min_speech_duration_ms=min_speech_ms,
                               min_silence_duration_ms=min_silence_ms, speech_pad_ms=pad_ms)
    return [(t["start"] / 16000, t["end"] / 16000) for t in ts]


def merge(wins, gap=MERGE_GAP, min_win=MIN_WIN):
    out = []
    for s, e in sorted(wins):
        if out and s - out[-1][1] < gap:
            out[-1][1] = max(out[-1][1], e)
        else:
            out.append([s, e])
    return [(s, e) for s, e in out if e - s >= min_win]


def energy_report(wav, wins, hop=0.05):
    import numpy as np
    n = int(16000 * hop)
    frames = wav[: len(wav) // n * n].reshape(-1, n)
    db = 20 * np.log10(np.sqrt((frames ** 2).mean(1)) + 1e-9)
    floor = float(np.percentile(db, 10))
    lines = [f"  noise floor (p10) {floor:.1f} dBFS, peak {db.max():.1f} dBFS"]
    for s, e in wins:
        seg = db[int(s / hop): max(int(e / hop), int(s / hop) + 1)]
        lines.append(f"  {s:6.2f}–{e:6.2f}  ({e - s:4.2f}s)  mean {seg.mean():6.1f} dB  "
                     f"(+{seg.mean() - floor:4.1f} over floor)")
    return db, floor, "\n".join(lines)


def vad(c, path=None, label=None):
    WORK.mkdir(exist_ok=True)
    path = path or out_path(c)
    wav = load_audio_16k(path)
    dur = len(wav) / 16000
    raw_w = silero_windows(wav, **c.get("vad", {}))
    wins = merge(raw_w)
    _, _, rep = energy_report(wav, wins)
    print(f"[vad] {label or c['clip_id']} ({dur:.2f}s) raw={len(raw_w)} merged={len(wins)}\n{rep}")
    if label:  # explore mode: don't persist
        return
    final = c.get("speech_windows_override") or [(round(s, 2), round(e, 2)) for s, e in wins]
    if c.get("speech_windows_override"):
        print(f"  using hand-checked override: {final}")
    (WORK / f"{c['clip_id']}.vad.json").write_text(json.dumps(
        {"silero": [(round(s, 2), round(e, 2)) for s, e in wins], "final": final}, indent=1))


def explore(c):
    print(f"[explore] source window starts at film t={c['fetch_start']}s")
    vad(c, path=src_path(c), label=c["clip_id"] + " (src)")


def frames(c, every=1.0):
    d = WORK / "frames" / c["clip_id"]
    d.mkdir(parents=True, exist_ok=True)
    run(["ffmpeg", "-nostdin", "-loglevel", "error", "-y", "-i", str(out_path(c)),
         "-vf", f"fps=1/{every},scale=480:-2", str(d / "f_%02d.png")])
    print(f"[frames] {d}")


def probe_duration(p: Path) -> float:
    return float(run(["ffprobe", "-v", "error", "-show_entries", "format=duration",
                      "-of", "default=nk=1:nw=1", str(p)]).strip())


def write_json(clips):
    out = []
    for c in clips:
        v = json.loads((WORK / f"{c['clip_id']}.vad.json").read_text())
        out.append({
            "clip_id": c["clip_id"],
            "title": c["title"],
            "video_file": f"{c['clip_id']}.mp4",
            "duration": round(probe_duration(out_path(c)), 2),
            "speech_windows": [{"start": s, "end": e} for s, e in v["final"]],
            "beats": c["beats"],
            "license": c["license"],
            "attribution": c["attribution"],
        })
    (HERE / "clips.json").write_text(json.dumps(out, indent=2, ensure_ascii=False) + "\n")
    print(f"[json] wrote clips.json ({len(out)} clips)")


def install(clips):
    """Copy trimmed mp4s + clips.json into the iOS bundle folder (folder reference in project.yml)."""
    import shutil
    dst = HERE.parent / "ios" / "DubStudio" / "Clips"
    dst.mkdir(parents=True, exist_ok=True)
    for c in clips:
        shutil.copy2(out_path(c), dst / out_path(c).name)
    shutil.copy2(HERE / "clips.json", dst / "clips.json")
    print(f"[install] copied {len(clips)} clips + clips.json -> {dst}")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("stages", nargs="*", default=["fetch", "trim", "vad", "json"])
    ap.add_argument("--clip", help="only this clip_id")
    a = ap.parse_args()
    sel = [c for c in CLIPS if not a.clip or c["clip_id"] == a.clip]
    for st in a.stages:
        if st in ("json", "install"):
            (write_json if st == "json" else install)(CLIPS)
            continue
        fn = {"fetch": fetch, "trim": trim, "vad": vad, "explore": explore, "frames": frames}[st]
        for c in sel:
            fn(c)


if __name__ == "__main__":
    main()
