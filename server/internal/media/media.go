// Package media issues S3 presigned URLs for dub videos. Video never streams
// through the Go server: the iPad PUTs straight to S3 and the share page gets a
// freshly signed GET on every visit (instance-role creds expire, so QR codes
// never contain a raw presigned URL).
package media

import (
	"bytes"
	"context"
	"errors"
	"io"
	"time"

	"github.com/aws/aws-sdk-go-v2/aws"
	"github.com/aws/aws-sdk-go-v2/service/s3"
	"github.com/aws/smithy-go"
)

const (
	PutExpiry = 1 * time.Hour
	GetExpiry = 1 * time.Hour
	// DubContentType must match the Content-Type header the iPad sends on the PUT.
	DubContentType = "video/mp4"
)

// DubKey is the S3 object key for a take's dub.
func DubKey(takeID string) string { return "dubs/" + takeID + ".mp4" }

// Media is S3 access for one bucket. A nil *Media means S3 is disabled
// (MEDIA_BUCKET empty); every method is nil-safe.
type Media struct {
	bucket  string
	client  *s3.Client
	presign *s3.PresignClient
}

// New returns nil when bucket is empty (S3 disabled).
func New(client *s3.Client, bucket string) *Media {
	if bucket == "" || client == nil {
		return nil
	}
	return &Media{bucket: bucket, client: client, presign: s3.NewPresignClient(client)}
}

// Enabled reports whether S3 features are on.
func (m *Media) Enabled() bool { return m != nil }

// PresignPut returns a presigned PUT URL for dubs/<take_id>.mp4, or "" if disabled.
func (m *Media) PresignPut(ctx context.Context, takeID string) (string, error) {
	if m == nil {
		return "", nil
	}
	req, err := m.presign.PresignPutObject(ctx, &s3.PutObjectInput{
		Bucket:      aws.String(m.bucket),
		Key:         aws.String(DubKey(takeID)),
		ContentType: aws.String(DubContentType),
	}, s3.WithPresignExpires(PutExpiry))
	if err != nil {
		return "", err
	}
	return req.URL, nil
}

// PresignGet returns a fresh presigned GET URL, or "" if disabled.
func (m *Media) PresignGet(ctx context.Context, takeID string) (string, error) {
	if m == nil {
		return "", nil
	}
	req, err := m.presign.PresignGetObject(ctx, &s3.GetObjectInput{
		Bucket:              aws.String(m.bucket),
		Key:                 aws.String(DubKey(takeID)),
		ResponseContentType: aws.String(DubContentType),
	}, s3.WithPresignExpires(GetExpiry))
	if err != nil {
		return "", err
	}
	return req.URL, nil
}

// Exists reports whether the dub object has been uploaded.
func (m *Media) Exists(ctx context.Context, takeID string) (bool, error) {
	if m == nil {
		return false, nil
	}
	_, err := m.client.HeadObject(ctx, &s3.HeadObjectInput{Bucket: aws.String(m.bucket), Key: aws.String(DubKey(takeID))})
	if err == nil {
		return true, nil
	}
	var apiErr smithy.APIError
	if errors.As(err, &apiErr) && (apiErr.ErrorCode() == "NotFound" || apiErr.ErrorCode() == "NoSuchKey") {
		return false, nil
	}
	return false, err
}

// Delete removes the dub object (no error if it doesn't exist).
func (m *Media) Delete(ctx context.Context, takeID string) error {
	if m == nil {
		return nil
	}
	_, err := m.client.DeleteObject(ctx, &s3.DeleteObjectInput{Bucket: aws.String(m.bucket), Key: aws.String(DubKey(takeID))})
	if _, derr := m.client.DeleteObject(ctx, &s3.DeleteObjectInput{Bucket: aws.String(m.bucket), Key: aws.String(DebugAudioKey(takeID))}); err == nil {
		err = derr
	}
	return err
}

// DebugAudioKey is where the raw player audio for a take is kept for debugging.
// It lives under dubs/ so the 7-day lifecycle rule and the instance role's
// least-privilege policy already cover it.
func DebugAudioKey(takeID string) string { return "dubs/" + takeID + ".take.m4a" }

// GetDebugAudio reads a take's raw audio back (used by the SQS re-score worker).
// Returns ErrNoAudio when the object is gone (deleted or expired).
func (m *Media) GetDebugAudio(ctx context.Context, takeID string) ([]byte, error) {
	if m == nil {
		return nil, ErrNoAudio
	}
	out, err := m.client.GetObject(ctx, &s3.GetObjectInput{Bucket: aws.String(m.bucket), Key: aws.String(DebugAudioKey(takeID))})
	if err != nil {
		var apiErr smithy.APIError
		if errors.As(err, &apiErr) && (apiErr.ErrorCode() == "NoSuchKey" || apiErr.ErrorCode() == "NotFound") {
			return nil, ErrNoAudio
		}
		return nil, err
	}
	defer out.Body.Close()
	return io.ReadAll(io.LimitReader(out.Body, 16<<20))
}

// ErrNoAudio means the take's audio object does not exist.
var ErrNoAudio = errors.New("take audio not found")

// PutDebugAudio stores the raw take audio (no-op when S3 is disabled).
func (m *Media) PutDebugAudio(ctx context.Context, takeID string, audio []byte, mime string) error {
	if m == nil {
		return nil
	}
	_, err := m.client.PutObject(ctx, &s3.PutObjectInput{
		Bucket: aws.String(m.bucket), Key: aws.String(DebugAudioKey(takeID)),
		Body: bytes.NewReader(audio), ContentType: aws.String(mime),
	})
	return err
}
