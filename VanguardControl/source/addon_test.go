package main

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func fakeWindower(t *testing.T) string {
	dir := t.TempDir()
	os.WriteFile(filepath.Join(dir, "Windower.exe"), []byte("MZ"), 0o644)
	os.MkdirAll(filepath.Join(dir, "addons"), 0o755)
	os.MkdirAll(filepath.Join(dir, "plugins"), 0o755)
	return dir
}

func TestBundledAddon(t *testing.T) {
	v := bundledVersion()
	if v == "" || !strings.Contains(v, ".") {
		t.Fatalf("the exe should carry the addon with a version, got %q", v)
	}
	b, _ := addonFS.ReadFile("addon/Vanguard.lua")
	if !strings.Contains(string(b), "repo = 'Daviant123/Vanguard'") {
		t.Errorf("the built-in addon should update from Daviant123/Vanguard")
	}
	sup, _ := addonFS.ReadFile("addon/vg_support.lua")
	if !strings.Contains(string(sup), "CharB|CharC") {
		t.Errorf("character names in the built-in addon should be replaced with CharA / CharB / CharC")
	}
}

func TestIsWindower(t *testing.T) {
	if !isWindower(fakeWindower(t)) {
		t.Error("a folder with Windower.exe is a Windower folder")
	}
	if isWindower(t.TempDir()) || isWindower("") {
		t.Error("an empty folder is not")
	}
}

func TestInstallAddonKeepsSettings(t *testing.T) {
	w := fakeWindower(t)
	data := filepath.Join(w, "addons", "Vanguard", "data")
	os.MkdirAll(data, 0o755)
	os.WriteFile(filepath.Join(data, "settings.xml"), []byte("<keep me/>"), 0o644)
	os.WriteFile(filepath.Join(w, "addons", "Vanguard", "Vanguard.lua"), []byte("_addon.version = '0.0.1'"), 0o644)
	n, err := installAddon(w)
	if err != nil || n < 10 {
		t.Fatalf("install wrote %d files, err %v", n, err)
	}
	if got := installedVersion(w); got != bundledVersion() {
		t.Errorf("installed version %q, want %q", got, bundledVersion())
	}
	if b, _ := os.ReadFile(filepath.Join(data, "settings.xml")); string(b) != "<keep me/>" {
		t.Error("the settings folder must never be touched")
	}
	if _, err := os.Stat(filepath.Join(w, "addons", "Vanguard", "vg_update.lua")); err != nil {
		t.Error("every addon file should be there")
	}
}

func TestAutoload(t *testing.T) {
	w := fakeWindower(t)
	if hasAutoload(w) {
		t.Fatal("no init.txt yet")
	}
	if err := addAutoload(w); err != nil || !hasAutoload(w) {
		t.Fatalf("init.txt should be made with lua load vanguard (%v)", err)
	}
	p := initPath(w)
	os.WriteFile(p, []byte("bind f12 input /heal\r\nlua l vanguard"), 0o644)
	addAutoload(w)
	b, _ := os.ReadFile(p)
	if strings.Count(strings.ToLower(string(b)), "vanguard") != 1 || !strings.Contains(string(b), "bind f12") {
		t.Errorf("an existing load line is kept, nothing doubled, other lines untouched: %q", b)
	}
	os.WriteFile(p, []byte("lua load steward"), 0o644)
	addAutoload(w)
	b, _ = os.ReadFile(p)
	if string(b) != "lua load steward\r\nlua load vanguard\r\n" {
		t.Errorf("added on its own line after what's there: %q", b)
	}
}

func TestEnsureAddonNeverDowngrades(t *testing.T) {
	w := fakeWindower(t)
	h := &hub{chars: map[string]*character{}}
	saveConfig(panelConfig{Windower: w})
	defer os.Remove(configPath())
	newerLua := "_addon.version = '99.0.0'"
	os.MkdirAll(filepath.Join(w, "addons", "Vanguard"), 0o755)
	os.WriteFile(filepath.Join(w, "addons", "Vanguard", "Vanguard.lua"), []byte(newerLua), 0o644)
	h.ensureAddon(false)
	if installedVersion(w) != "99.0.0" {
		t.Error("a newer addon on disk (e.g. from //vg update) is left alone")
	}
	os.WriteFile(filepath.Join(w, "addons", "Vanguard", "Vanguard.lua"), []byte("_addon.version = '0.1.0'"), 0o644)
	h.ensureAddon(false)
	if installedVersion(w) != bundledVersion() {
		t.Error("an older addon is updated to the one in the exe")
	}
	os.RemoveAll(filepath.Join(w, "addons", "Vanguard"))
	os.RemoveAll(filepath.Join(w, "scripts"))
	h.ensureAddon(false)
	if installedVersion(w) != bundledVersion() || !hasAutoload(w) {
		t.Error("not installed yet: installed and set to load at game start")
	}
}
