// The panel looks after the Vanguard addon itself (user request 2026-10-15: "the exe should handle the bulk of
// the work"): it finds the Windower folder, installs the addon that is built into this exe into
// Windower\addons\Vanguard, makes it load at game start (scripts\init.txt), keeps it up to date (a newer panel
// carries a newer addon) and reloads the characters that still run an older copy. Settings (addons\Vanguard\data)
// are never touched.
package main

import (
	"embed"
	"encoding/json"
	"io/fs"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strings"
	"sync"
	"time"
)

//go:embed addon
var addonFS embed.FS

var versionRe = regexp.MustCompile(`_addon\.version\s*=\s*'([\d.]+)'`)
var autoloadRe = regexp.MustCompile(`(?im)^\s*lua\s+(load|l)\s+vanguard\s*$`)

type panelConfig struct {
	Windower  string `json:"windower"`
	AutoAddon *bool  `json:"auto_addon,omitempty"` // install / reload the addon by itself (default on)
}

var cfgMu sync.Mutex

func configPath() string {
	exe, _ := os.Executable()
	return filepath.Join(filepath.Dir(exe), "vanguard_control.json")
}

func loadConfig() panelConfig {
	var c panelConfig
	if b, err := os.ReadFile(configPath()); err == nil {
		json.Unmarshal(b, &c)
	}
	return c
}

func saveConfig(c panelConfig) {
	b, _ := json.MarshalIndent(c, "", "  ")
	os.WriteFile(configPath(), b, 0o644)
}

func (c panelConfig) auto() bool { return c.AutoAddon == nil || *c.AutoAddon }

// bundledVersion is the addon version built into this exe.
func bundledVersion() string {
	b, err := addonFS.ReadFile("addon/Vanguard.lua")
	if err != nil {
		return ""
	}
	if m := versionRe.FindSubmatch(b); m != nil {
		return string(m[1])
	}
	return ""
}

func installedVersion(windower string) string {
	b, err := os.ReadFile(filepath.Join(windower, "addons", "Vanguard", "Vanguard.lua"))
	if err != nil {
		return ""
	}
	if m := versionRe.FindSubmatch(b); m != nil {
		return string(m[1])
	}
	return "?"
}

// isWindower: a folder with Windower.exe (or the addons + plugins folders Windower makes).
func isWindower(dir string) bool {
	if dir == "" {
		return false
	}
	if st, err := os.Stat(filepath.Join(dir, "Windower.exe")); err == nil && !st.IsDir() {
		return true
	}
	a, err1 := os.Stat(filepath.Join(dir, "addons"))
	p, err2 := os.Stat(filepath.Join(dir, "plugins"))
	return err1 == nil && err2 == nil && a.IsDir() && p.IsDir()
}

// runningWindower asks Windows where a running Windower.exe lives.
func runningWindower() string {
	out, err := exec.Command("powershell", "-NoProfile", "-Command",
		"(Get-Process -Name Windower -ErrorAction SilentlyContinue | Select-Object -First 1).Path").Output()
	if err != nil {
		return ""
	}
	p := strings.TrimSpace(string(out))
	if p == "" {
		return ""
	}
	return filepath.Dir(p)
}

// findWindower tries: the saved folder, next to / above this exe, a running Windower, the usual install places.
func findWindower(saved string) string {
	exe, _ := os.Executable()
	here := filepath.Dir(exe)
	home, _ := os.UserHomeDir()
	cands := []string{saved, filepath.Dir(here), here}
	if rw := runningWindower(); rw != "" {
		cands = append(cands, rw)
	}
	for _, base := range []string{os.Getenv("ProgramFiles(x86)"), os.Getenv("ProgramFiles"), `C:\`, `D:\`,
		filepath.Join(home, "Desktop"), filepath.Join(home, "Documents"), filepath.Join(home, "Downloads"), home} {
		if base == "" {
			continue
		}
		for _, name := range []string{"Windower4", "Windower 4", "Windower"} {
			cands = append(cands, filepath.Join(base, name))
		}
	}
	for _, c := range cands {
		if isWindower(c) {
			return filepath.Clean(c)
		}
	}
	return ""
}

// installAddon writes the built-in addon files into <windower>\addons\Vanguard (never the data folder).
func installAddon(windower string) (int, error) {
	dst := filepath.Join(windower, "addons", "Vanguard")
	if err := os.MkdirAll(dst, 0o755); err != nil {
		return 0, err
	}
	n := 0
	err := fs.WalkDir(addonFS, "addon", func(path string, d fs.DirEntry, err error) error {
		if err != nil || d.IsDir() {
			return err
		}
		name := strings.TrimPrefix(path, "addon/")
		if strings.Contains(name, "/") { // only the addon's own top-level files
			return nil
		}
		data, err := addonFS.ReadFile(path)
		if err != nil {
			return err
		}
		if err := os.WriteFile(filepath.Join(dst, name), data, 0o644); err != nil {
			return err
		}
		n++
		return nil
	})
	return n, err
}

func initPath(windower string) string { return filepath.Join(windower, "scripts", "init.txt") }

func hasAutoload(windower string) bool {
	b, err := os.ReadFile(initPath(windower))
	return err == nil && autoloadRe.Match(b)
}

// addAutoload adds "lua load vanguard" to scripts\init.txt (made if missing).
func addAutoload(windower string) error {
	if hasAutoload(windower) {
		return nil
	}
	p := initPath(windower)
	if err := os.MkdirAll(filepath.Dir(p), 0o755); err != nil {
		return err
	}
	b, _ := os.ReadFile(p)
	text := string(b)
	if text != "" && !strings.HasSuffix(text, "\n") {
		text += "\r\n"
	}
	text += "lua load vanguard\r\n"
	return os.WriteFile(p, []byte(text), 0o644)
}

// pickFolder shows the Windows folder picker.
func pickFolder() string {
	script := `Add-Type -AssemblyName System.Windows.Forms; $d = New-Object System.Windows.Forms.FolderBrowserDialog; ` +
		`$d.Description = 'Choose your Windower folder (the one with Windower.exe)'; ` +
		`if ($d.ShowDialog() -eq 'OK') { $d.SelectedPath }`
	out, err := exec.Command("powershell", "-NoProfile", "-STA", "-Command", script).Output()
	if err != nil {
		return ""
	}
	return strings.TrimSpace(string(out))
}

// ---------------------------------------------------------------- state + HTTP

type addonState struct {
	Windower  string `json:"windower"`
	Found     bool   `json:"found"`
	Installed string `json:"installed"`
	Bundled   string `json:"bundled"`
	Autoload  bool   `json:"autoload"`
	Auto      bool   `json:"auto"`
	Panel     string `json:"panel"`
}

func currentAddonState() addonState {
	cfgMu.Lock()
	c := loadConfig()
	cfgMu.Unlock()
	s := addonState{Windower: c.Windower, Bundled: bundledVersion(), Auto: c.auto(), Panel: panelVersion}
	if isWindower(c.Windower) {
		s.Found = true
		s.Installed = installedVersion(c.Windower)
		s.Autoload = hasAutoload(c.Windower)
	}
	return s
}

// ensureAddon finds Windower and, with automatic mode on, installs / updates the addon. Returns what it did.
func (h *hub) ensureAddon(force bool) string {
	cfgMu.Lock()
	c := loadConfig()
	if !isWindower(c.Windower) {
		if w := findWindower(c.Windower); w != "" {
			c.Windower = w
			saveConfig(c)
		}
	}
	cfgMu.Unlock()
	if !isWindower(c.Windower) {
		return "Windower folder not found: use Choose folder."
	}
	inst, bund := installedVersion(c.Windower), bundledVersion()
	if bund == "" {
		return ""
	}
	if !force && !c.auto() {
		return ""
	}
	if inst != "" && inst != "?" && !newer(bund, inst) && !force {
		return ""
	}
	n, err := installAddon(c.Windower)
	if err != nil {
		h.addLog("Couldn't install Vanguard into %s: %v", c.Windower, err)
		return "Install failed: " + err.Error()
	}
	if inst == "" {
		addAutoload(c.Windower)
		h.addLog("Installed Vanguard %s into %s (%d files) and set it to load when the game starts.", bund, c.Windower, n)
	} else {
		h.addLog("Updated Vanguard %s -> %s in %s (%d files). Characters reload it by themselves.", inst, bund, c.Windower, n)
	}
	return "ok"
}

// reloadWatch: characters still running an older addon than the one on disk are told to reload (once each).
func (h *hub) reloadWatch() {
	asked := map[string]string{}
	toldOld := map[string]bool{}
	for {
		time.Sleep(5 * time.Second)
		st := currentAddonState()
		if !st.Found || !st.Auto || st.Installed == "" || st.Installed == "?" {
			continue
		}
		h.mu.Lock()
		var todo, old []string
		for name, c := range h.chars {
			v, _ := c.Snapshot["version"].(string)
			online := time.Since(c.LastSeen) < 5*time.Second
			if online && v == "" && c.Snapshot["type"] == "state" && !toldOld[name] {
				toldOld[name] = true
				old = append(old, name)
			}
			// not in the middle of a fight: the reload waits until it's over (it would drop the fight)
			status, _ := c.Snapshot["status"].(string)
			if online && v != "" && newer(st.Installed, v) && asked[name] != st.Installed && status != "Engaged" {
				todo = append(todo, name+"|"+v)
			}
		}
		h.mu.Unlock()
		for _, name := range old {
			h.addLog("%s runs an old Vanguard that can't be reloaded from here: type //lua r vanguard once in its game window.", name)
		}
		for _, t := range todo {
			parts := strings.SplitN(t, "|", 2)
			asked[parts[0]] = st.Installed
			if h.send(parts[0], "reload") {
				h.addLog("%s runs Vanguard %s: reloading it to %s.", parts[0], parts[1], st.Installed)
			}
		}
	}
}

func (h *hub) handleAddon(w http.ResponseWriter, r *http.Request) {
	switch r.URL.Query().Get("do") {
	case "install":
		msg := h.ensureAddon(true)
		st := currentAddonState()
		if st.Found && r.URL.Query().Get("autoload") != "0" {
			addAutoload(st.Windower)
		}
		if msg != "ok" && msg != "" {
			h.addLog("%s", msg)
		}
	case "autoload":
		if st := currentAddonState(); st.Found {
			if err := addAutoload(st.Windower); err != nil {
				h.addLog("Couldn't change scripts\\init.txt: %v", err)
			} else {
				h.addLog("Vanguard now loads when the game starts (scripts\\init.txt).")
			}
		}
	case "pick", "folder":
		dir := r.URL.Query().Get("path")
		if r.URL.Query().Get("do") == "pick" {
			dir = pickFolder()
		}
		if dir != "" {
			if !isWindower(dir) {
				h.addLog("%s doesn't look like a Windower folder (no Windower.exe there).", dir)
			} else {
				cfgMu.Lock()
				c := loadConfig()
				c.Windower = filepath.Clean(dir)
				saveConfig(c)
				cfgMu.Unlock()
				h.addLog("Windower folder: %s", dir)
				h.ensureAddon(false)
			}
		}
	case "auto":
		cfgMu.Lock()
		c := loadConfig()
		on := r.URL.Query().Get("on") != "0"
		c.AutoAddon = &on
		saveConfig(c)
		cfgMu.Unlock()
		h.addLog("Automatic addon install / reload: %s", map[bool]string{true: "on", false: "off"}[on])
	case "reload":
		n := 0
		for _, name := range h.names() {
			if h.send(name, "reload") {
				n++
			}
		}
		h.addLog("Reloading Vanguard on %d character(s).", n)
	case "check":
		go func() {
			latest, err := checkUpdate()
			switch {
			case err != nil:
				h.addLog("Couldn't reach the GitHub page (%v).", err)
			case latest == "":
				h.addLog("Vanguard Control %s is the newest (addon %s).", panelVersion, bundledVersion())
			default:
				h.updateNow <- latest
			}
		}()
	}
	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(currentAddonState())
}
