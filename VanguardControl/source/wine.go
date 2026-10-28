// Finding Windower inside Wine (Ubuntu / Linux players, his request 2026-10-27). Plain path work, no build tag, so the
// tests run on Windows too; platform_other.go uses it.
package main

import (
	"os"
	"path/filepath"
	"strings"
)

// winePathToLinux: "C:\Program Files (x86)\Windower4\Windower.exe" in prefix P -> P/drive_c/Program Files (x86)/...;
// "Z:\home\me\..." -> /home/me/...; a path that's already a Linux one stays.
func winePathToLinux(prefix, p string) string {
	if strings.HasPrefix(p, "/") {
		return p
	}
	if len(p) < 3 || p[1] != ':' {
		return ""
	}
	rest := strings.ReplaceAll(p[3:], `\`, "/")
	switch strings.ToLower(p[:1]) {
	case "z":
		return "/" + rest
	default:
		return filepath.Join(prefix, "drive_"+strings.ToLower(p[:1]), rest)
	}
}

// winePrefixes: the Wine prefixes on this PC (Wine, Lutris, Steam / Proton, Bottles, PlayOnLinux).
func winePrefixes(home string) []string {
	out := []string{}
	if p := os.Getenv("WINEPREFIX"); p != "" {
		out = append(out, p)
	}
	out = append(out, filepath.Join(home, ".wine"))
	for _, pat := range []string{
		filepath.Join(home, "Games", "*"),                                             // Lutris
		filepath.Join(home, ".local", "share", "lutris", "prefixes", "*"),
		filepath.Join(home, ".steam", "steam", "steamapps", "compatdata", "*", "pfx"), // Steam / Proton
		filepath.Join(home, ".local", "share", "Steam", "steamapps", "compatdata", "*", "pfx"),
		filepath.Join(home, ".local", "share", "bottles", "bottles", "*"), // Bottles
		filepath.Join(home, ".var", "app", "com.usebottles.bottles", "data", "bottles", "bottles", "*"),
		filepath.Join(home, ".PlayOnLinux", "wineprefix", "*"), // PlayOnLinux
	} {
		m, _ := filepath.Glob(pat)
		out = append(out, m...)
	}
	return out
}

// wineWindowerPlaces: Windower's usual folders inside every Wine prefix, and in the home folder.
func wineWindowerPlaces(home string) []string {
	var out []string
	names := []string{"Windower4", "Windower 4", "Windower"}
	for _, pfx := range winePrefixes(home) {
		c := filepath.Join(pfx, "drive_c")
		for _, base := range []string{filepath.Join(c, "Program Files (x86)"), filepath.Join(c, "Program Files"), c,
			filepath.Join(c, "Program Files (x86)", "PlayOnline"), filepath.Join(c, "Program Files", "PlayOnline")} {
			for _, n := range names {
				out = append(out, filepath.Join(base, n))
			}
		}
		users, _ := filepath.Glob(filepath.Join(c, "users", "*", "Desktop"))
		for _, u := range users {
			for _, n := range names {
				out = append(out, filepath.Join(u, n))
			}
		}
	}
	for _, base := range []string{home, filepath.Join(home, "Desktop"), filepath.Join(home, "Games")} {
		for _, n := range names {
			out = append(out, filepath.Join(base, n))
		}
	}
	return out
}

