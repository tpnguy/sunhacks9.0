package media

import (
	"context"
	"strings"
	"testing"

	"github.com/aws/aws-sdk-go-v2/aws"
	"github.com/aws/aws-sdk-go-v2/credentials"
	"github.com/aws/aws-sdk-go-v2/service/s3"
)

func TestDisabledIsNilSafe(t *testing.T) {
	m := New(nil, "")
	if m.Enabled() {
		t.Fatal("should be disabled")
	}
	u, err := m.PresignPut(context.Background(), "x")
	if u != "" || err != nil {
		t.Errorf("PresignPut = %q, %v", u, err)
	}
	if err := m.Delete(context.Background(), "x"); err != nil {
		t.Error(err)
	}
}

// Presigning is offline (no network), so this runs without AWS access.
func TestPresignOffline(t *testing.T) {
	c := s3.New(s3.Options{
		Region:      "us-west-2",
		Credentials: aws.NewCredentialsCache(credentials.NewStaticCredentialsProvider("AKIDEXAMPLE", "secret", "")),
	})
	m := New(c, "dubstudio-media-123")
	u, err := m.PresignPut(context.Background(), "abc")
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(u, "dubs/abc.mp4") || !strings.Contains(u, "X-Amz-Signature") {
		t.Errorf("bad url %s", u)
	}
	g, err := m.PresignGet(context.Background(), "abc")
	if err != nil || !strings.Contains(g, "response-content-type=video%2Fmp4") {
		t.Errorf("bad get url %s %v", g, err)
	}
}
