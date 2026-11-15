# Spoken roast — TTS style (Tier 1)

Model: current Gemini Flash TTS (`gemini-3.8-flash-tts`; the older `gemini-3.1-flash-tts-preview` is legacy — confirm in https://aistudio.google.com/docs/models before use). Single speaker; pick a low, measured prebuilt voice (try `Charon`, `Orus` or `Algenib`) and lock it so every roast sounds like the same judge. Output is PCM 24 kHz; the server wraps it as WAV.

Prepend this style line to the roast text (the model reads the instruction as direction, not as words to speak):

```
Say this as a stern, unimpressed talent-show judge delivering a verdict: low and deliberate, a short pause before the final few words, a hint of a sigh, never shouting, never laughing: {roast}
```

Guidelines:
- One judge persona, generic — not an imitation of any real person's voice.
- Keep it under ~6 s of audio (roasts are ≤ 25 words).
- If TTS fails or takes > 4 s, show the text roast only; never block the scorecard on audio.
