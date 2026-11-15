package api

import "testing"

func m4a(payload int) []byte {
	b := []byte{0, 0, 0, 0x1c, 'f', 't', 'y', 'p', 'M', '4', 'A', ' '}
	b = append(b, make([]byte, 16)...)
	sz := payload + 8
	b = append(b, byte(sz>>24), byte(sz>>16), byte(sz>>8), byte(sz), 'm', 'd', 'a', 't')
	return append(b, make([]byte, payload)...)
}

func TestNoAudioReason(t *testing.T) {
	loud, quiet := -12.0, -60.0
	cases := []struct {
		name  string
		audio []byte
		peak  *float64
		want  bool
	}{
		{"empty mdat", m4a(0), nil, true},
		{"tiny mdat", m4a(500), &loud, true},
		{"real audio, no peak sent", m4a(100_000), nil, false},
		{"real audio, loud", m4a(100_000), &loud, false},
		{"real audio, silent", m4a(100_000), &quiet, true},
		{"non-mp4 passes through", []byte("RIFF....WAVEfmt "), nil, false},
	}
	for _, c := range cases {
		if got := noAudioReason(c.audio, c.peak) != ""; got != c.want {
			t.Errorf("%s: noAudio=%v, want %v (%q)", c.name, got, c.want, noAudioReason(c.audio, c.peak))
		}
	}
}
