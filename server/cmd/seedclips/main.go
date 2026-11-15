// Command seedclips loads clips/clips.json into the DynamoDB clips table.
//
//	go run ./cmd/seedclips -file ../clips/clips.json -table dubstudio-clips -region us-west-2
//	go run ./cmd/seedclips -dry-run   # validate + print, no AWS calls
package main

import (
	"context"
	"flag"
	"fmt"
	"log"
	"os"
	"time"

	awsconfig "github.com/aws/aws-sdk-go-v2/config"
	"github.com/aws/aws-sdk-go-v2/service/dynamodb"

	"github.com/dubstudio/server/internal/catalog"
	"github.com/dubstudio/server/internal/model"
	"github.com/dubstudio/server/internal/store"
)

func main() {
	file := flag.String("file", envOr("CLIPS_FILE", "../clips/clips.json"), "path to clips.json")
	table := flag.String("table", envOr("CLIPS_TABLE", "dubstudio-clips"), "DynamoDB clips table")
	region := flag.String("region", envOr("AWS_REGION", "us-west-2"), "AWS region")
	dry := flag.Bool("dry-run", false, "validate and print, don't write")
	flag.Parse()

	b, err := os.ReadFile(*file)
	if err != nil {
		log.Fatalf("read %s: %v", *file, err)
	}
	clips, err := catalog.Parse(b)
	if err != nil {
		log.Fatalf("parse %s: %v", *file, err)
	}
	if len(clips) == 0 {
		log.Fatalf("%s has no clips", *file)
	}
	for _, c := range clips {
		if err := validate(c); err != nil {
			log.Fatalf("clip %q: %v", c.ClipID, err)
		}
	}
	if *dry {
		for _, c := range clips {
			fmt.Printf("ok  %-24s %5.1fs  %d windows  %d beats  %s\n", c.ClipID, c.Duration, len(c.SpeechWindows), len(c.Beats), c.Title)
		}
		return
	}

	ctx, cancel := context.WithTimeout(context.Background(), 60*time.Second)
	defer cancel()
	cfg, err := awsconfig.LoadDefaultConfig(ctx, awsconfig.WithRegion(*region))
	if err != nil {
		log.Fatalf("aws config: %v", err)
	}
	db := dynamodb.NewFromConfig(cfg)
	for _, c := range clips {
		if err := store.PutClip(ctx, db, *table, c); err != nil {
			log.Fatalf("put %s: %v", c.ClipID, err)
		}
		fmt.Printf("put %s → %s\n", c.ClipID, *table)
	}
	fmt.Printf("seeded %d clips into %s (%s)\n", len(clips), *table, *region)
}

func validate(c model.Clip) error {
	if c.Duration <= 0 {
		return fmt.Errorf("duration must be > 0")
	}
	if len(c.SpeechWindows) == 0 {
		return fmt.Errorf("no speech_windows (timing score would always be 0)")
	}
	for _, w := range c.SpeechWindows {
		if w.End <= w.Start || w.Start < 0 || w.End > c.Duration+0.5 {
			return fmt.Errorf("bad speech window %+v", w)
		}
	}
	return nil
}

func envOr(k, def string) string {
	if v := os.Getenv(k); v != "" {
		return v
	}
	return def
}
