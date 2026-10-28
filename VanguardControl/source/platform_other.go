//go:build !windows

// Linux (Ubuntu) parts of Vanguard Control (his request 2026-10-27: friends play FFXI on Ubuntu with Wine). The game,
// Windower and the Vanguard addon run inside Wine; this app runs natively and hears the addon on 127.0.0.1 like on
// Windows (Wine uses the PC's own network). The Windower folder is found inside the Wine prefixes (Wine, Lutris,
// Steam / Proton, Bottles, PlayOnLinux). Pickers through zenity / kdialog, the clipboard through wl-copy / xclip / xsel.
package main

import (
	"os"
	"os/exec"
	"path/filepath"
	"strings"
)

const updateAsset = "vanguard-control-linux"
const programMagic = "\x7fELF"
const systemName = "Linux"

func have(cmd string) bool { _, err := exec.LookPath(cmd); return err == nil }

// The sound: the desktop's warning sound, else the terminal bell.
func playAlarmOS() {
	for _, c := range [][]string{
		{"canberra-gtk-play", "-i", "dialog-warning"},
		{"paplay", "/usr/share/sounds/freedesktop/stereo/dialog-warning.oga"},
		{"aplay", "-q", "/usr/share/sounds/alsa/Front_Center.wav"},
	} {
		if have(c[0]) && exec.Command(c[0], c[1:]...).Start() == nil {
			return
		}
	}
	os.Stdout.WriteString("\a")
}

func openURLOS(u string) { exec.Command("xdg-open", u).Start() }

func openFolderOS(dir string) { exec.Command("xdg-open", filepath.Clean(dir)).Start() }

// openAppWindow: a Chrome-type browser in app mode gives a clean window; else the default browser.
func openAppWindow(url string) {
	for _, b := range []string{"google-chrome", "google-chrome-stable", "chromium", "chromium-browser", "brave-browser", "microsoft-edge"} {
		if have(b) && exec.Command(b, "--app="+url, "--window-size=1180,860").Start() == nil {
			return
		}
	}
	openURLOS(url)
}

// runningWindower: a Windower.exe running under Wine shows up in /proc with its Windows path; its Wine prefix is found
// from WINEPREFIX in that process' environment (default ~/.wine).
func runningWindower() string {
	procs, _ := filepath.Glob("/proc/[0-9]*/cmdline")
	for _, p := range procs {
		b, err := os.ReadFile(p)
		if err != nil || !strings.Contains(strings.ToLower(string(b)), "windower.exe") {
			continue
		}
		var exe string
		for _, a := range strings.Split(string(b), "\x00") {
			if strings.HasSuffix(strings.ToLower(a), "windower.exe") {
				exe = a
				break
			}
		}
		if exe == "" {
			continue
		}
		prefix := ""
		if env, err := os.ReadFile(filepath.Join(filepath.Dir(p), "environ")); err == nil {
			for _, kv := range strings.Split(string(env), "\x00") {
				if strings.HasPrefix(kv, "WINEPREFIX=") {
					prefix = strings.TrimPrefix(kv, "WINEPREFIX=")
				}
			}
		}
		if prefix == "" {
			home, _ := os.UserHomeDir()
			prefix = filepath.Join(home, ".wine")
		}
		if dir := winePathToLinux(prefix, exe); dir != "" {
			return filepath.Dir(dir)
		}
	}
	return ""
}

// windowerPlaces: on Linux, inside the Wine prefixes (wine.go).
func windowerPlaces(home string) []string { return wineWindowerPlaces(home) }

func dialog(args ...[]string) string {
	for _, a := range args {
		if have(a[0]) {
			out, err := exec.Command(a[0], a[1:]...).Output()
			if err == nil {
				return strings.TrimSpace(string(out))
			}
			return ""
		}
	}
	return ""
}

func pickFolderOS() string {
	return dialog([]string{"zenity", "--file-selection", "--directory", "--title=Choose your Windower folder (the one with Windower.exe)"},
		[]string{"kdialog", "--getexistingdirectory", os.Getenv("HOME"), "--title", "Choose your Windower folder"})
}

func saveDialogOS(defaultName string) string {
	home, _ := os.UserHomeDir()
	return dialog([]string{"zenity", "--file-selection", "--save", "--confirm-overwrite", "--filename=" + filepath.Join(home, defaultName)},
		[]string{"kdialog", "--getsavefilename", filepath.Join(home, defaultName)})
}

func openDialogOS() string {
	home, _ := os.UserHomeDir()
	return dialog([]string{"zenity", "--file-selection", "--file-filter=Vanguard profile | *" + shareExt + " *.json", "--filename=" + home + "/"},
		[]string{"kdialog", "--getopenfilename", home, "*" + shareExt + " *.json"})
}

func copyTextOS(text string) error {
	for _, c := range [][]string{{"wl-copy"}, {"xclip", "-selection", "clipboard"}, {"xsel", "--clipboard", "--input"}} {
		if have(c[0]) {
			cmd := exec.Command(c[0], c[1:]...)
			cmd.Stdin = strings.NewReader(text)
			return cmd.Run()
		}
	}
	return os.ErrNotExist
}
