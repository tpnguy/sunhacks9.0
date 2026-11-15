# Beats draft — prompt (offline clip prep, `clips/draft_beats.py`)

Call settings: model `GEMINI_MODEL` (gemini-3.8-flash), temperature 0.2, JSON schema below. Input: the trimmed clip video (inline or Files API URI) + this prompt + the clip's VAD speech windows.

---

You are preparing a ~15-second film clip for a voice-over party game. Players will watch it muted and improvise the dialogue; an AI judge then checks whether their delivery matched the scene's emotional beats.

List the clip's **beats**: the moments where a performer's delivery should change. A beat is a line starting, a reaction, a cut, a gesture, or a meaningful silence.

For each beat give:
- `t`: seconds from the clip start (one decimal). Align line beats to the start of the matching speech window below; you sample video at ~1 fps, so prefer the audio for timing.
- `desc`: ≤ 15 words — who does what, quoting the line if one is spoken (e.g. `Celia snarls: "I should just crush you!"`).
- `emotion`: exactly one of `anger, panic, fear, sadness, joy, suspense, deadpan, sarcasm, mockery, smug, annoyance, charm, tenderness, confusion`.

Rules: 4–8 beats, sorted by `t`, all within `[0, duration]`. Describe only what is on screen or audible; don't invent plot. Name characters only if they are named on screen or in the dialogue.

Speech windows (seconds): {speech_windows}
Clip duration: {duration} s

Return JSON only.

---

## Response schema
```json
{
  "type": "object",
  "properties": {
    "beats": {
      "type": "array",
      "items": {
        "type": "object",
        "properties": {
          "t": {"type": "number"},
          "desc": {"type": "string"},
          "emotion": {"type": "string", "enum": ["anger","panic","fear","sadness","joy","suspense","deadpan","sarcasm","mockery","smug","annoyance","charm","tenderness","confusion"]}
        },
        "required": ["t", "desc", "emotion"]
      }
    }
  },
  "required": ["beats"]
}
```
