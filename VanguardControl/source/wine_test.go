package main

import (
	"os"
	"path/filepath"
	"testing"
)

// Ubuntu players (2026-10-27): Windower is found inside the Wine prefixes, and Wine paths map to Linux ones.
func TestWinePaths(t *testing.T) {
	if got := winePathToLinux("/home/me/.wine", `C:\Program Files (x86)\Windower4\Windower.exe`); filepath.ToSlash(got) != "/home/me/.wine/drive_c/Program Files (x86)/Windower4/Windower.exe" {
		t.Errorf("C: path: %q", got)
	}
	if got := winePathToLinux("/home/me/.wine", `Z:\home\me\Games\Windower4\Windower.exe`); got != "/home/me/Games/Windower4/Windower.exe" {
		t.Errorf("Z: path: %q", got)
	}
	if got := winePathToLinux("/x", "/already/linux"); got != "/already/linux" {
		t.Errorf("linux path: %q", got)
	}
}

func TestWineWindowerPlaces(t *testing.T) {
	home := t.TempDir()
	// a Lutris prefix with Windower in Program Files (x86)
	win := filepath.Join(home, "Games", "final-fantasy-xi", "drive_c", "Program Files (x86)", "Windower4")
	os.MkdirAll(win, 0o755)
	os.WriteFile(filepath.Join(win, "Windower.exe"), []byte("MZ"), 0o644)
	found := ""
	for _, c := range wineWindowerPlaces(home) {
		if isWindower(c) {
			found = c
			break
		}
	}
	if found != win {
		t.Fatalf("Windower in a Lutris prefix not found: got %q", found)
	}
	// Steam / Proton
	home2 := t.TempDir()
	win2 := filepath.Join(home2, ".steam", "steam", "steamapps", "compatdata", "123", "pfx", "drive_c", "Windower4")
	os.MkdirAll(filepath.Join(win2, "addons"), 0o755)
	os.MkdirAll(filepath.Join(win2, "plugins"), 0o755)
	found = ""
	for _, c := range wineWindowerPlaces(home2) {
		if isWindower(c) {
			found = c
			break
		}
	}
	if found != win2 {
		t.Fatalf("Windower in a Proton prefix not found: got %q", found)
	}
}
