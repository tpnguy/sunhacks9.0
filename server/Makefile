BIN        := bin
LINUX_BIN  := $(BIN)/dubstudio-server-linux-arm64
LDFLAGS    := -s -w

.PHONY: test vet run run-dynamo build build-linux seed seed-dry fmt clean sync-prompts

test:
	go vet ./...
	go test ./...

vet:
	go vet ./...

fmt:
	gofmt -w .

# Local dev: in-memory store, mock Gemini unless GEMINI_API_KEY is set in .env.
run:
	STORE=memory go run ./cmd/server

# Local against real AWS (needs credentials).
run-dynamo:
	go run ./cmd/server

build:
	go build -trimpath -ldflags '$(LDFLAGS)' -o $(BIN)/dubstudio-server ./cmd/server

# Graviton (t4g) EC2 binary.
build-linux:
	CGO_ENABLED=0 GOOS=linux GOARCH=arm64 go build -trimpath -ldflags '$(LDFLAGS)' -o $(LINUX_BIN) ./cmd/server
	CGO_ENABLED=0 GOOS=linux GOARCH=arm64 go build -trimpath -ldflags '$(LDFLAGS)' -o $(BIN)/seedclips-linux-arm64 ./cmd/seedclips
	@ls -lh $(LINUX_BIN)

seed:
	go run ./cmd/seedclips

seed-dry:
	go run ./cmd/seedclips -dry-run

clean:
	rm -rf $(BIN)

# Copy the system-prompt bodies (text between the first two '---' lines) from
# ../prompts/*.md into prompts/*.txt, which are go:embed'ed into the binary.
sync-prompts:
	awk '/^---$$/{n++; next} n==1' ../prompts/scorer.md  > prompts/scorer_system.txt
	awk '/^---$$/{n++; next} n==1' ../prompts/roaster.md > prompts/roaster_system.txt
	@wc -l prompts/*.txt
