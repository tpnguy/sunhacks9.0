# LARPStudio server (Go)

## Clarifications and small deviations from API.md (read first)

All endpoints, field names, tables, GSIs and env vars from API.md are implemented as written. Where API.md was silent or ambiguous, this is what the server does:

1. **`scored_by` can be `"mock"`.** If `GEMINI_API_KEY` is empty, the server runs in mock mode and returns `"mock"`. With a key it is always `"gemini"` or `"fallback"`. Clients should only special-case `"fallback"`.
2. **What "widened by 0.2 s" means for timing.** Timing = `|player ∩ widen(ref, 0.2)| / |player ∪ ref|`. Widening decides which player speech counts, so up to 0.2 s early or late is free. The union uses the *raw* reference, so a perfectly timed take scores 100. Plain IoU against widened windows would cap a perfect 3 s line at 3/3.4 = 88. Numbers: on a 3 s line, raw IoU at 0.5 s late = 2.5/3.5 ≈ 0.71; the shipped score = 2.7/3.5 ≈ 0.77, i.e. 77. Player segments are merged and clamped to the clip duration. See `internal/timing/timing_test.go`.
3. **The `vad_segments` echoed in the POST /takes response are sanitised**: merged, sorted and clamped to the clip, which is what the score used. Draw the timing bar from these.
4. **The S3 presigned PUT signs `Content-Type: video/mp4`.** The iPad's PUT **must** send the header `Content-Type: video/mp4`, or S3 returns 403 SignatureDoesNotMatch. The URL is valid for 1 hour.
5. **The clips table is read with a Scan**, once at startup and every 5 minutes, into an in-memory catalog. The table has about 4 items, and requests never touch it. Leaderboards use only GSI Queries (`ScanIndexForward=false`, `Limit`), never Scans. Fallback chain: DynamoDB → `CLIPS_FILE` → embedded `testdata/clips.json`.
6. **Optional extra env vars** (all have defaults; API.md's list still works unchanged): `PLAYERS_TABLE` (dubstudio-players), `GEMINI_TIMEOUT_SECONDS` (15, per attempt), `GEMINI_FALLBACK_MODEL` (gemini-3.5-flash, used for the retry), `RESCORE_QUEUE_URL` (SQS re-score queue; empty = off), `GEMINI_THINKING_LEVEL` (low), `MAX_UPLOAD_BYTES` (5 MiB), `ENV_FILE` (.env).
7. **Errors** are JSON `{"error":"..."}` with 400 (bad meta, unknown clip_id, missing audio), 413 (body > 5 MiB), 404 (unknown take) or 500.
8. **`GET /d/{id}`** renders the HTML share page with a `<video>` whose `src` is a fresh presigned GET (API.md wording). It does not 302. If the dub is not in S3 yet it shows "Still uploading…" and refreshes every 5 s. If the iPad uploaded but never called `/takes/{id}/uploaded`, the page checks S3 with HeadObject and marks the take as uploaded itself.
9. **Fallback is per call.** If the scoring call fails, emotion = comedy = 5 and `scored_by` = `"fallback"`. If only the roast call fails, the scores stay `"gemini"` and the roast is a canned "judges are on a coffee break" line. Both cases count toward `fallback_used`.

## Run locally

```bash
cd server
cp .env.example .env        # leave GEMINI_API_KEY empty for mock mode
make run                    # STORE=memory, http://localhost:8080
make test                   # go vet + go test
```

Smoke test:

```bash
ffmpeg -f lavfi -i "sine=frequency=440:duration=4" -ac 1 -c:a aac take.m4a
curl -F 'meta={"clip_id":"tos-crush","nickname":"ban","player_id":"p1","vad_segments":[{"start":0.6,"end":1.2},{"start":2.2,"end":3.9}],"audio_mime":"audio/mp4"}' \
     -F 'audio=@take.m4a;type=audio/mp4' localhost:8080/takes
curl localhost:8080/leaderboard
open http://localhost:8080/board
```

## Build and deploy

- `make build-linux` produces `bin/dubstudio-server-linux-arm64` (Graviton t4g, static, CGO off) and `bin/seedclips-linux-arm64`.
- `make seed` (or `go run ./cmd/seedclips -file ../clips/clips.json -table dubstudio-clips`) PutItems every clip. `make seed-dry` only validates.
- `make sync-prompts` re-copies the system prompts from `../prompts/{scorer,roaster}.md` (the text between the first two `---` lines) into `prompts/*.txt`. Those files are `go:embed`'ed, so rebuild afterwards.
- Logs: plain JSON logs go to **stderr**. **stdout carries only CloudWatch EMF lines**: namespace `DubStudio`, dimension `Service=dubstudio-server`, metrics `scoring_latency_ms`, `gemini_timeout`, `fallback_used`, plus `rescore_success`, `rescore_retry`, `rescore_dropped` and `rescore_delay_ms` from the re-score worker, with `clip_id`, `take_id`, `scored_by` and `model` as properties.
- When `STORE=dynamo` (the default) or `MEDIA_BUCKET` is set, AWS credentials come from the default chain (the EC2 instance role).

### IAM the instance role needs
- `dynamodb:PutItem, GetItem, UpdateItem, DeleteItem, Query` on `dubstudio-takes` and `dubstudio-takes/index/*`
- `dynamodb:Scan, GetItem` on `dubstudio-clips` (plus `PutItem` for seedclips)
- `dynamodb:UpdateItem` on `dubstudio-players`
- `s3:PutObject, GetObject, DeleteObject` on `arn:aws:s3:::<bucket>/dubs/*`, and `s3:ListBucket` on the bucket. Without ListBucket, HeadObject on a missing key returns 403 instead of 404.

## Gemini

- Models: **`gemini-4-hydrogen`** (`GEMINI_MODEL`) for the first attempt; the retry switches to **`gemini-3.5-flash`** (`GEMINI_FALLBACK_MODEL`), which benchmarked as the most reliable on 2026-11-15.
- SDK: `google.golang.org/genai` v1.77.0, `Models.GenerateContent` with `ResponseMIMEType: application/json` and `ResponseJsonSchema`. The audio goes inline (`NewPartFromBytes`, mapped to `audio/m4a`, which is on the supported list at https://aistudio.google.com/docs/audio). Current docs show the newer Interactions API in their examples; GenerateContent is still fully supported by the SDK and simpler here.
- Scorer: temperature 0, seed 42, thinking level low. Schema `{emotion int 0–10, comedy int 0–10, emotion_reason, comedy_reason}`; reasons are ordered before scores.
- Roaster: temperature 1.1, schema `{roast}`. The user turn also includes the code-computed timing score and the player's VAD segments.
- Both calls run in parallel. Each attempt has a 15 s timeout, with 1 retry on the fallback model. Out-of-range scores, schema failures and empty roasts count as failures and trigger the retry, then the fallback.

## Async re-scoring (SQS)

When the scoring call falls back, `POST /takes` still answers immediately, and the take ID is sent to the SQS queue in `RESCORE_QUEUE_URL` (only if the raw audio was saved to S3). `internal/rescore` long-polls the queue one message at a time, re-runs the judge on the S3 audio and writes the scores with a conditional `UpdateItem` (`scored_by = "fallback"` and the take still exists), then sets `rescored_at`. If Gemini still fails, the message is left for redelivery after the 120 s visibility timeout; after 20 receives it goes to the dead-letter queue. The instance role needs `sqs:SendMessage, ReceiveMessage, DeleteMessage, ChangeMessageVisibility, GetQueueAttributes` on the queue.

New takes also get `expires_at` (now + 7 days, epoch seconds), so DynamoDB TTL deletes them on the same schedule as the S3 lifecycle rule.

## Layout

```
cmd/server        main: config → store/media/catalog → judge → HTTP
cmd/seedclips     clips.json → DynamoDB
internal/api      handlers + html/template pages (board, share, message)
internal/timing   merge / widen / IoU (+ tests)
internal/gemini   Judge (timeouts, retry, fallback), genai client, mock
internal/store    Store interface, DynamoDB + memory
internal/media    S3 presign PUT/GET, HeadObject, Delete
internal/metrics  CloudWatch EMF
internal/rescore  SQS queue + worker for async re-scoring of fallback takes
internal/catalog  clip cache with fallback chain
prompts/          embedded system prompts (copied from ../prompts)
testdata/         placeholder clips.json (embedded fallback)
```
