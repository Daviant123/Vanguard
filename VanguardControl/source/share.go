// Sharing profiles (series 2 round 9). MMOMinion has a downloads section where players share skill profiles by
// class; Vanguard Control exports a profile as one file (Windows "Save as" window) and imports one a friend sent
// ("Open" window) - nothing to type. Exported files drop the character it came from and the leader's name.
package main

import (
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strings"
	"time"
)

const shareExt = ".vgprofile.json"

var jobRe = regexp.MustCompile(`^[A-Z]{3}$`)

// psQuote makes a string safe inside a single-quoted PowerShell literal.
func psQuote(s string) string { return strings.ReplaceAll(s, "'", "''") }

var saveDialog = func(defaultName string) string {
	script := `Add-Type -AssemblyName System.Windows.Forms; $d = New-Object System.Windows.Forms.SaveFileDialog; ` +
		`$d.Filter = 'Vanguard profile (*` + shareExt + `)|*` + shareExt + `'; $d.FileName = '` + psQuote(defaultName) + `'; ` +
		`$d.InitialDirectory = [Environment]::GetFolderPath('Desktop'); if ($d.ShowDialog() -eq 'OK') { $d.FileName }`
	out, err := exec.Command("powershell", "-NoProfile", "-STA", "-Command", script).Output()
	if err != nil {
		return ""
	}
	return strings.TrimSpace(string(out))
}

var openDialog = func() string {
	script := `Add-Type -AssemblyName System.Windows.Forms; $d = New-Object System.Windows.Forms.OpenFileDialog; ` +
		`$d.Filter = 'Vanguard profile (*` + shareExt + `;*.json)|*` + shareExt + `;*.json'; ` +
		`$d.InitialDirectory = [Environment]::GetFolderPath('Desktop'); if ($d.ShowDialog() -eq 'OK') { $d.FileName }`
	out, err := exec.Command("powershell", "-NoProfile", "-STA", "-Command", script).Output()
	if err != nil {
		return ""
	}
	return strings.TrimSpace(string(out))
}

// exportProfile writes the profile to dest, without who it came from.
func exportProfile(job, name, dest string) error {
	p, err := readProfile(job, name)
	if err != nil {
		return fmt.Errorf("no %s profile called %q", job, name)
	}
	var data map[string]any
	if json.Unmarshal(p.Data, &data) == nil {
		delete(data, "leader")
		p.Data, _ = json.Marshal(data)
	}
	p.From = ""
	if !strings.HasSuffix(strings.ToLower(dest), ".json") {
		dest += shareExt
	}
	b, _ := json.MarshalIndent(p, "", "  ")
	return os.WriteFile(dest, b, 0o644)
}

// importProfile checks a shared file and adds it to the profiles folder. Returns the name it was saved under.
func importProfile(src string) (profileFile, error) {
	var p profileFile
	st, err := os.Stat(src)
	if err != nil {
		return p, err
	}
	if st.Size() > 256*1024 {
		return p, fmt.Errorf("that file is too big to be a profile")
	}
	b, err := os.ReadFile(src)
	if err != nil {
		return p, err
	}
	if json.Unmarshal(b, &p) != nil || !jobRe.MatchString(p.Job) || !profileName.MatchString(p.Name) || len(p.Data) == 0 {
		return p, fmt.Errorf("that file isn't a Vanguard profile")
	}
	var data map[string]any
	if json.Unmarshal(p.Data, &data) != nil || data["job"] != p.Job {
		return p, fmt.Errorf("that file isn't a Vanguard profile")
	}
	delete(data, "leader")
	p.Data, _ = json.Marshal(data)
	base := p.Name
	for i := 2; ; i++ { // don't overwrite one of yours
		if _, err := os.Stat(profilePath(p.Job, p.Name)); os.IsNotExist(err) {
			break
		}
		p.Name = fmt.Sprintf("%s (%d)", base, i)
		if len(p.Name) > 40 || i > 50 {
			return p, fmt.Errorf("too many profiles called %q", base)
		}
	}
	p.From, p.Saved = "imported", time.Now().Format("2006-01-02 15:04")
	os.MkdirAll(profilesDir(), 0o755)
	out, _ := json.MarshalIndent(p, "", "  ")
	return p, os.WriteFile(profilePath(p.Job, p.Name), out, 0o644)
}

func shareDefaultName(job, name string) string {
	return filepath.Base(job + " - " + name + shareExt)
}
