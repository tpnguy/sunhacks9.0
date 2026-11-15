package config

import (
	"os"
	"path/filepath"
	"testing"
)

func TestLoadDotEnv(t *testing.T) {
	p := filepath.Join(t.TempDir(), ".env")
	content := "# comment\n\nexport DS_A=1\nDS_B=\"two words\"\nDS_C='x'\nDS_D=val # trailing\nDS_KEEP=fromfile\nbadline\n"
	if err := os.WriteFile(p, []byte(content), 0o600); err != nil {
		t.Fatal(err)
	}
	t.Setenv("DS_KEEP", "fromenv")
	for _, k := range []string{"DS_A", "DS_B", "DS_C", "DS_D"} {
		os.Unsetenv(k)
		t.Cleanup(func() { os.Unsetenv(k) })
	}
	if err := LoadDotEnv(p); err != nil {
		t.Fatal(err)
	}
	want := map[string]string{"DS_A": "1", "DS_B": "two words", "DS_C": "x", "DS_D": "val", "DS_KEEP": "fromenv"}
	for k, v := range want {
		if got := os.Getenv(k); got != v {
			t.Errorf("%s = %q, want %q", k, got, v)
		}
	}
}
