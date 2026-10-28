//go:build windows

// Windows-only parts of Vanguard Control (the Linux ones are in platform_other.go): the warning sound, opening the
// window / links / folders, finding a running Windower, the file and folder pickers, the clipboard, the update file.
package main

import (
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"syscall"
	"unicode/utf16"
)

// the file the self-update downloads from the GitHub page, and how it starts
const updateAsset = "Vanguard%20Control.exe"
const programMagic = "MZ"
const systemName = "Windows"

// The sound: Windows' warning sound (MessageBeep, no extra program).
func playAlarmOS() {
	defer func() { recover() }()
	syscall.NewLazyDLL("user32.dll").NewProc("MessageBeep").Call(0x30)
}

func openURLOS(u string) { exec.Command("rundll32", "url.dll,FileProtocolHandler", u).Start() }

func openFolderOS(dir string) { exec.Command("explorer", filepath.Clean(dir)).Start() }

// openAppWindow: Edge app mode gives a clean standalone window; else the default browser.
func openAppWindow(url string) {
	edges := []string{
		filepath.Join(os.Getenv("ProgramFiles(x86)"), `Microsoft\Edge\Application\msedge.exe`),
		filepath.Join(os.Getenv("ProgramFiles"), `Microsoft\Edge\Application\msedge.exe`),
	}
	for _, e := range edges {
		if _, err := os.Stat(e); err == nil {
			if exec.Command(e, "--app="+url, "--window-size=1180,860").Start() == nil {
				return
			}
		}
	}
	openURLOS(url)
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

// windowerPlaces: where Windower usually is on Windows.
func windowerPlaces(home string) []string {
	var out []string
	for _, base := range []string{os.Getenv("ProgramFiles(x86)"), os.Getenv("ProgramFiles"), `C:\`, `D:\`,
		filepath.Join(home, "Desktop"), filepath.Join(home, "Documents"), filepath.Join(home, "Downloads"), home} {
		if base == "" {
			continue
		}
		for _, name := range []string{"Windower4", "Windower 4", "Windower"} {
			out = append(out, filepath.Join(base, name))
		}
	}
	return out
}

// psQuote makes a string safe inside a single-quoted PowerShell literal.
func psQuote(s string) string { return strings.ReplaceAll(s, "'", "''") }

func powershell(script string) string {
	out, err := exec.Command("powershell", "-NoProfile", "-STA", "-Command", script).Output()
	if err != nil {
		return ""
	}
	return strings.TrimSpace(string(out))
}

// pickFolderOS shows the Windows folder picker.
func pickFolderOS() string {
	return powershell(`Add-Type -AssemblyName System.Windows.Forms; $d = New-Object System.Windows.Forms.FolderBrowserDialog; ` +
		`$d.Description = 'Choose your Windower folder (the one with Windower.exe)'; ` +
		`if ($d.ShowDialog() -eq 'OK') { $d.SelectedPath }`)
}

func saveDialogOS(defaultName string) string {
	return powershell(`Add-Type -AssemblyName System.Windows.Forms; $d = New-Object System.Windows.Forms.SaveFileDialog; ` +
		`$d.Filter = 'Vanguard profile (*` + shareExt + `)|*` + shareExt + `'; $d.FileName = '` + psQuote(defaultName) + `'; ` +
		`$d.InitialDirectory = [Environment]::GetFolderPath('Desktop'); if ($d.ShowDialog() -eq 'OK') { $d.FileName }`)
}

func openDialogOS() string {
	return powershell(`Add-Type -AssemblyName System.Windows.Forms; $d = New-Object System.Windows.Forms.OpenFileDialog; ` +
		`$d.Filter = 'Vanguard profile (*` + shareExt + `;*.json)|*` + shareExt + `;*.json'; ` +
		`$d.InitialDirectory = [Environment]::GetFolderPath('Desktop'); if ($d.ShowDialog() -eq 'OK') { $d.FileName }`)
}

// copyTextOS puts text on the Windows clipboard (clip.exe, which reads UTF-16 with a BOM).
func copyTextOS(text string) error {
	u := utf16.Encode([]rune(text))
	b := make([]byte, 2, 2+len(u)*2)
	b[0], b[1] = 0xFF, 0xFE
	for _, c := range u {
		b = append(b, byte(c), byte(c>>8))
	}
	cmd := exec.Command("clip")
	cmd.Stdin = strings.NewReader(string(b))
	return cmd.Run()
}
