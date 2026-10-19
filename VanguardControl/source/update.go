// Self-update from the GitHub page (user request 2026-10-15).
//
// A few seconds after it starts (and every hour) the panel reads VanguardControl/version.txt on
// github.com/Daviant123/Vanguard. When that is newer than panelVersion it downloads the new
// "Vanguard Control.exe", swaps it in (Windows lets a running exe be renamed, not overwritten) and
// restarts itself; the open window carries on with the new version. A file named "noupdate.txt" next
// to the exe turns this off. Only this exe is replaced; the addon updates itself with //vg update.
package main

import (
	"bytes"
	"fmt"
	"io"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"time"
)

var panelVersion = "1.78.4" // set by -X for tests; the published version

// how often the panel looks for a newer version (was 6 hours: his open window stayed several versions behind)
var updateEvery = time.Hour

var updateBase = "https://raw.githubusercontent.com/Daviant123/Vanguard/main/VanguardControl/" // tests point it elsewhere

// newer reports whether version a is newer than b ("1.10.0" > "1.9.2").
func newer(a, b string) bool {
	pa, pb := strings.Split(strings.TrimSpace(a), "."), strings.Split(strings.TrimSpace(b), ".")
	for i := 0; i < len(pa) || i < len(pb); i++ {
		var x, y int
		if i < len(pa) {
			x, _ = strconv.Atoi(pa[i])
		}
		if i < len(pb) {
			y, _ = strconv.Atoi(pb[i])
		}
		if x != y {
			return x > y
		}
	}
	return false
}

func fetch(url string, limit int64) ([]byte, error) {
	client := &http.Client{Timeout: 60 * time.Second}
	resp, err := client.Get(url)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("HTTP %d", resp.StatusCode)
	}
	return io.ReadAll(io.LimitReader(resp.Body, limit))
}

// cleanupOld removes the exes left behind by earlier updates (any still running stay until next time).
func cleanupOld() {
	if exe, err := os.Executable(); err == nil {
		olds, _ := filepath.Glob(strings.TrimSuffix(exe, filepath.Ext(exe)) + ".old*.exe")
		for _, f := range olds {
			os.Remove(f)
		}
	}
}

func oldPath(exe string) string {
	return strings.TrimSuffix(exe, filepath.Ext(exe)) + ".old.exe"
}

// checkUpdate returns the newer version on GitHub, or "" when up to date / unreachable.
func checkUpdate() (string, error) {
	body, err := fetch(updateBase+"version.txt", 64)
	if err != nil {
		return "", err
	}
	latest := strings.TrimSpace(string(body))
	if latest == "" || !newer(latest, panelVersion) {
		return "", nil
	}
	return latest, nil
}

// installUpdate downloads the new exe and swaps it in. It returns the path to start.
func installUpdate(version string) (string, error) {
	exe, err := os.Executable()
	if err != nil {
		return "", err
	}
	data, err := fetch(updateBase+"Vanguard%20Control.exe", 64<<20)
	if err != nil {
		return "", err
	}
	if len(data) < 1<<20 || !bytes.HasPrefix(data, []byte("MZ")) {
		return "", fmt.Errorf("the download doesn't look like a program (%d bytes)", len(data))
	}
	if err := swapIn(exe, data); err != nil {
		return "", err
	}
	return exe, nil
}

// swapIn puts the new exe in place of the running one: the running one is renamed out of the way (Windows lets a
// running exe be renamed, not replaced). The usual name for it is "<exe>.old.exe"; when that file can't be removed
// - it's the program that's running now, left there by the last update (the bug that kept 1.7.4 from ever
// updating: "Access is denied") - a fresh name is used instead.
func swapIn(exe string, data []byte) error {
	tmp := exe + ".new"
	if err := os.WriteFile(tmp, data, 0o755); err != nil {
		return err
	}
	old := oldPath(exe)
	if os.Remove(old) != nil {
		if _, err := os.Stat(old); err == nil {
			old = strings.TrimSuffix(exe, filepath.Ext(exe)) + fmt.Sprintf(".old-%d.exe", time.Now().UnixNano())
		}
	}
	if err := os.Rename(exe, old); err != nil {
		os.Remove(tmp)
		return err
	}
	if err := os.Rename(tmp, exe); err != nil {
		os.Rename(old, exe) // put the working one back
		return err
	}
	return nil
}

func updatesDisabled() bool {
	exe, err := os.Executable()
	if err != nil {
		return true
	}
	_, err = os.Stat(filepath.Join(filepath.Dir(exe), "noupdate.txt"))
	return err == nil
}

// autoUpdate runs in the background for the life of the panel. "Check for updates" in the panel sends a
// version on h.updateNow (that works even with noupdate.txt, since it's asked for).
func (h *hub) autoUpdate(restart func(exe string)) {
	disabled := updatesDisabled()
	if disabled {
		h.addLog("Vanguard Control %s (automatic updates off: noupdate.txt)", panelVersion)
	} else {
		time.Sleep(5 * time.Second)
	}
	try := func(latest string) bool {
		h.addLog("Vanguard Control %s is available (you have %s): downloading...", latest, panelVersion)
		exe, err := installUpdate(latest)
		if err != nil {
			h.addLog("Update failed (%v); still on %s. It will try again later.", err, panelVersion)
			return false
		}
		h.addLog("Updated to %s: restarting the panel...", latest)
		time.Sleep(1 * time.Second)
		restart(exe)
		return true
	}
	for {
		if !disabled {
			if latest, err := checkUpdate(); err == nil && latest != "" && try(latest) {
				return
			}
		}
		select {
		case latest := <-h.updateNow:
			if try(latest) {
				return
			}
		case <-time.After(updateEvery):
		}
	}
}

// startDetached starts the new exe without opening another window.
func startDetached(exe string) error {
	cmd := exec.Command(exe, "--no-window")
	cmd.Dir = filepath.Dir(exe)
	return cmd.Start()
}
