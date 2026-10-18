package main

import (
	"time"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"testing"
)

func TestNewer(t *testing.T) {
	cases := []struct {
		a, b string
		want bool
	}{{"1.1.0", "1.0.0", true}, {"1.10.0", "1.9.9", true}, {"1.1.0", "1.1.0", false}, {"1.0.9", "1.1.0", false}, {"2", "1.9.9", true}}
	for _, c := range cases {
		if newer(c.a, c.b) != c.want {
			t.Errorf("newer(%q, %q) should be %v", c.a, c.b, c.want)
		}
	}
}

func TestCheckUpdate(t *testing.T) {
	version := "9.9.9\n"
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/version.txt" {
			w.Write([]byte(version))
			return
		}
		http.NotFound(w, r)
	}))
	defer srv.Close()
	updateBase = srv.URL + "/"
	if v, err := checkUpdate(); err != nil || v != "9.9.9" {
		t.Errorf("a newer version on the page should be found, got %q %v", v, err)
	}
	version = panelVersion
	if v, _ := checkUpdate(); v != "" {
		t.Errorf("same version: no update, got %q", v)
	}
	updateBase = srv.URL + "/missing/"
	if v, err := checkUpdate(); err == nil || v != "" {
		t.Errorf("page not reachable: an error and no update, got %q %v", v, err)
	}
}

// The What's new tab must describe the version being built (every update adds its notes).
func TestWhatsNewMatchesVersion(t *testing.T) {
	b, err := webFS.ReadFile("web/whatsnew.json")
	if err != nil {
		t.Fatalf("whatsnew.json missing: %v", err)
	}
	var notes []struct {
		Version string   `json:"version"`
		Items   []string `json:"items"`
	}
	if err := json.Unmarshal(b, &notes); err != nil || len(notes) == 0 {
		t.Fatalf("whatsnew.json unreadable: %v", err)
	}
	if notes[0].Version != panelVersion || len(notes[0].Items) == 0 {
		t.Errorf("the first What's new entry is %q; it should describe %s", notes[0].Version, panelVersion)
	}
}

// The self-update when "<exe>.old.exe" is still in use (the running program, left there by the previous update):
// it used to fail with "Access is denied" on every try, so the app never updated again.
func TestSwapInWhenOldIsInUse(t *testing.T) {
	dir := t.TempDir()
	exe := filepath.Join(dir, "Vanguard Control.exe")
	os.WriteFile(exe, []byte("MZ current"), 0o755)
	os.WriteFile(oldPath(exe), []byte("MZ running from the last update"), 0o755)
	held, err := os.Open(oldPath(exe)) // Go opens without delete sharing: the file can't be removed or replaced
	if err != nil {
		t.Fatal(err)
	}
	defer held.Close()
	if err := swapIn(exe, []byte("MZ new version")); err != nil {
		t.Fatalf("the update should still go in, got %v", err)
	}
	if b, _ := os.ReadFile(exe); string(b) != "MZ new version" {
		t.Errorf("the new version is in place, got %q", b)
	}
	olds, _ := filepath.Glob(filepath.Join(dir, "Vanguard Control.old*.exe"))
	if len(olds) != 2 {
		t.Errorf("the running one moved aside under a fresh name, got %v", olds)
	}
	// normal case: nothing in the way
	os.WriteFile(filepath.Join(dir, "b.exe"), []byte("MZ b"), 0o755)
	if err := swapIn(filepath.Join(dir, "b.exe"), []byte("MZ b2")); err != nil {
		t.Fatal(err)
	}
	if b, _ := os.ReadFile(filepath.Join(dir, "b.old.exe")); string(b) != "MZ b" {
		t.Errorf("the usual .old.exe name when it's free, got %q", b)
	}
}

// The panel looks for a newer version every hour (it was every 6 hours, and his open window stayed several
// versions behind while new ones were published).
func TestUpdateEveryHour(t *testing.T) {
	if updateEvery != time.Hour {
		t.Fatalf("update check every %v, want 1h", updateEvery)
	}
}
