package main

import (
	"encoding/json"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestShareProfiles(t *testing.T) {
	os.RemoveAll(profilesDir())
	defer os.RemoveAll(profilesDir())
	os.MkdirAll(profilesDir(), 0o755)
	mine := profileFile{Name: "Odyssey healer", Job: "WHM", From: "CharB", Saved: "x",
		Data: json.RawMessage(`{"job":"WHM","leader":"CharA","profile":"role=healer","menu":"m=heal"}`)}
	b, _ := json.Marshal(mine)
	os.WriteFile(profilePath("WHM", "Odyssey healer"), b, 0o644)

	dir := t.TempDir()
	dest := filepath.Join(dir, "for a friend")
	if err := exportProfile("WHM", "Odyssey healer", dest); err != nil {
		t.Fatal(err)
	}
	out, err := os.ReadFile(dest + shareExt)
	if err != nil {
		t.Fatalf("the export gets the .vgprofile.json ending: %v", err)
	}
	if strings.Contains(string(out), "CharB") || strings.Contains(string(out), "CharA") || !strings.Contains(string(out), "role=healer") {
		t.Errorf("an exported profile has the setup but not who it came from or the leader: %s", out)
	}
	// importing it back: a copy, never over your own
	p, err := importProfile(dest + shareExt)
	if err != nil || p.Name != "Odyssey healer (2)" || p.From != "imported" {
		t.Fatalf("import should add a copy named (2), got %+v %v", p, err)
	}
	if len(listProfiles()) != 2 {
		t.Error("both profiles are listed")
	}
	// bad files are refused
	bad := map[string]string{
		"notjson":  "hello",
		"badjob":   `{"name":"x","job":"whm!","data":{"job":"whm!"}}`,
		"badname":  `{"name":"../../evil","job":"WHM","data":{"job":"WHM"}}`,
		"mismatch": `{"name":"x","job":"WHM","data":{"job":"BLM"}}`,
		"nodata":   `{"name":"x","job":"WHM"}`,
	}
	for k, v := range bad {
		f := filepath.Join(dir, k+".json")
		os.WriteFile(f, []byte(v), 0o644)
		if _, err := importProfile(f); err == nil {
			t.Errorf("%s should be refused", k)
		}
	}
	// through the app: the dialogs return a path (or nothing when cancelled)
	h := testHub(t)
	saveDialog = func(string) string { return filepath.Join(dir, "via app") }
	openDialog = func() string { return filepath.Join(dir, "via app"+shareExt) }
	h.handleProfiles(httptest.NewRecorder(), httptest.NewRequest("GET", "/api/profiles?do=export&job=WHM&name=Odyssey+healer", nil))
	rec := httptest.NewRecorder()
	h.handleProfiles(rec, httptest.NewRequest("GET", "/api/profiles?do=import", nil))
	if !strings.Contains(rec.Body.String(), `"imported"`) || !strings.Contains(rec.Body.String(), "Odyssey healer (3)") {
		t.Errorf("Export then Import through the app, got %.200s", rec.Body.String())
	}
	openDialog = func() string { return "" }
	rec = httptest.NewRecorder()
	h.handleProfiles(rec, httptest.NewRequest("GET", "/api/profiles?do=import", nil))
	if strings.Contains(rec.Body.String(), "error") {
		t.Error("cancelling the window is not an error")
	}
}
