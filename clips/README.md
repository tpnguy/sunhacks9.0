# clips/: LARPStudio seed clips

There are four dialogue clips of about 14 s each, with visible talking faces, 2 to 7 short lines each, and clear emotional beats. `clips.json` follows the shape in `../API.md`. The mp4s and `clips.json` are also copied into `../ios/DubStudio/Clips/`, where they ship in the app bundle.

| clip_id | Title | Source range (film time) | Lines |
|---|---|---|---|
| `tos-breakup` | Tears of Steel: The Breakup | 0:22.4 to 0:36.4 | "You're a jerk, Thom." / "Look Celia, we have to follow our passions..." / "Why don't you just admit you're freaked out by my robot hand?" / "I'm not freaked out by– it's..." |
| `tos-crush` | Tears of Steel: You Broke My Heart | 6:18.6 to 6:32.6 | "No!" / "Nooo!" / "You broke my heart." / "I know." / "You forgot me on Earth." / "I know." / "I should just crush you!" |
| `notld-barbara` | Night of the Living Dead: They're Coming to Get You | 5:55.5 to 6:09.8 | "Johnny." / "You're still afraid." / "Stop it now. I mean it." / "They're coming to get you, Barbara!" / "Stop it!" |
| `hgf-reno` | His Girl Friday: Six Weeks in Reno | 4:19.8 to 4:33.85 | "How long is it since we've seen each other?" / "Oh, well, let's see... six weeks in Reno, then Bermuda..." / "Seems like yesterday to me." / "Maybe it was yesterday, Hildy." |

## Credits and licenses

Show these in the app (the `attribution` field) and on the share page. CC-BY also requires credit **on the shared dub itself**. Burn in a lower-third such as `Clip: Tears of Steel (CC-BY Blender Foundation) — dubbed by @nick`. The lower-third also covers CC-BY's "indicate changes" requirement, because we replaced the audio and trimmed the clip.

### Tears of Steel (`tos-breakup`, `tos-crush`)
- **License:** Creative Commons Attribution 3.0 (CC-BY 3.0), https://creativecommons.org/licenses/by/3.0/
- **Attribution:** `Tears of Steel (CC-BY 3.0) (c) Blender Foundation | mango.blender.org`
- **Source file:** https://download.blender.org/demo/movies/ToS/tears_of_steel_720p.mov (official 720p, 1280×534, 24 fps, 372 MB; only the needed seconds are fetched over HTTP range requests)
- **Project page:** https://mango.blender.org/ · subtitles: https://download.blender.org/demo/movies/ToS/subtitles/TOS-en.srt
- **Note:** `download.blender.org/demo/movies/ToS/copyright.txt` puts the *Original Soundtrack* files (the separate OST downloads) under CC-BY-ND 3.0 with the credit "(C) Joram Letwory - www.tearsofsteel.org". We do not use the OST files. Our clips are excerpts of the film, which is CC-BY 3.0, and the film includes its mixed audio. The music is still audible in the in-app preview. **A human should confirm** that this reading is acceptable. If it is not, mute the preview audio for the ToS clips.

### Night of the Living Dead (1968) (`notld-barbara`)
- **License:** Public domain in the US. The original release carried no copyright notice, as the 1909 Act required. Internet Archive lists it as public domain (licenseurl `creativecommons.org/licenses/publicdomain/`).
- **Attribution (courtesy):** `Night of the Living Dead (1968, dir. George A. Romero) — public domain | archive.org`
- **Source:** https://archive.org/details/night_of_the_living_dead_dvd, file `Night.mp4` (640×480, h.264)

### His Girl Friday (1940) (`hgf-reno`)
- **License:** Public domain in the US. The copyright was not renewed. Internet Archive lists it as public domain (licenseurl `creativecommons.org/licenses/publicdomain/`). The underlying play, *The Front Page* (1928), has also been in the US public domain since 2024.
- **Attribution (courtesy):** `His Girl Friday (1940, dir. Howard Hawks) — public domain | archive.org`
- **Source:** https://archive.org/details/his_girl_friday, file `his_girl_friday.mp4` (640×480, h.264)

"Public domain" here means public domain in the **US** only. These films may still be under copyright in some other countries.

## How the data was made

1. **Scene picking:** we searched the official ToS English subtitles and the archive.org `.asr.srt` files for scenes with 2 to 4 punchy lines, then checked word timings with a local Whisper (`small.en`) pass. Whisper was a dev-only check and is not part of `prep.py`. Faces were confirmed on 1 fps contact sheets (`prep.py frames`).
2. **Encode:** H.264 High at about 2 Mbps (maxrate 2.5M), at most 1280 wide, at most 30 fps (ToS keeps its native 24, the archive films stay at 29.97), with AAC 128k stereo 48 kHz, `+faststart`, and the original audio kept. Each file is about 3.7 MB.
3. **Speech windows:** Silero VAD (threshold 0.5, 16 kHz mono from the trimmed clip). Gaps under 0.3 s are merged and windows under 0.25 s are dropped. We then compared the result against speech-band RMS energy and Whisper word timings:
   - `notld-barbara`: the raw Silero output is used unchanged.
   - `hgf-reno`: Silero is used, with the last window capped at 13.85 so it doesn't run into the next (cut) line.
   - `tos-crush`: **hand-set.** The score masks the dialogue. Silero found only 3 of the 7 lines and placed them late, so the windows were set from the energy and Whisper timings instead.
   - `tos-breakup`: Silero splits the speech at gaps under 0.3 s, so it merges into a single 1.04 to 13.68 window. The clip is one continuous argument (a "motor-mouth" clip), so its timing score mostly rewards starting on time and not stopping.
   - We also tried subtracting the ToS music+FX stem (`TOS_MUSIC+FX_NO_DIALOGUE.aif`) from the stereo mix to isolate the dialogue. It did not null out, because the stems don't match the release mix, so we abandoned that approach.
4. **Beats:** ⚠️ **These were written by hand by the prep agent, not by Gemini.** No API key was available when they were made. They are based on the subtitles, Whisper word timings and 1 fps frames. **Re-check them**, including timestamps, speaker attributions and emotion labels. Once a key exists, run `draft_beats.py` and compare its output with these beats. The speaker attributions that are least certain are "Seems like yesterday to me" in `hgf-reno` (we assumed Hildy) and the first "I know" in `tos-crush` (a quiet murmur).

Emotion labels used: `anger, panic, fear, sadness, joy, suspense, deadpan, sarcasm, mockery, smug, annoyance, charm` (plus `tenderness, confusion` in the draft schema).

## Re-running

```bash
cd clips
python3 -m venv .venv && .venv/bin/pip install silero-vad numpy soundfile google-genai
.venv/bin/python prep.py                     # fetch -> trim -> vad -> json  (~1 min; ~60 MB of padded source in raw/)
.venv/bin/python prep.py install             # copy mp4s + clips.json into ../ios/DubStudio/Clips/
.venv/bin/python prep.py explore --clip X    # VAD + energy over the padded source, to choose new ranges
.venv/bin/python prep.py frames              # 1 fps PNGs in work/frames/<id>/ for checking beats
.venv/bin/python draft_beats.py [clip_id]    # Gemini beat drafts (needs GEMINI_API_KEY in ../server/.env)
```

All the settings live in the `CLIPS` config at the top of `prep.py`: source URL, padded fetch window, trim range, VAD threshold, `speech_windows_override` and beats. To change a clip, edit that config and rerun `prep.py trim vad json install`. Times in `clips.json` are seconds from clip start. `raw/`, `work/` and `.venv/` are gitignored.

The server reads `../clips/clips.json` (`CLIPS_FILE`). If you change the clips, reseed the DynamoDB `dubstudio-clips` table as well.
