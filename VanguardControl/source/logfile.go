// The log file and Send logs (user request 2026-10-18: "add a send logs feature so that if someone is having issues it
// can record the logs in app and updates, the user can send last X logs to the same place that report a problem goes").
// Every line of the app's log (the app's own messages, each character's Vanguard messages, updates) also goes into
// vanguard_log.txt next to the exe, so it outlives a restart. Send logs takes the last N lines, replaces character
// names and the Windows user name, opens the same GitHub "new issue" page as Report a problem with the newest lines
// that fit in the link, and puts all N lines on the clipboard to paste into the report (Ctrl+V). Nothing is sent
// without the player's Submit click there.
package main

import (
	"bufio"
	"fmt"
	"net/url"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"sort"
	"strings"
	"time"
	"unicode/utf16"
)

const logFileMax = 3 << 20 // trimmed to the newest half past 3 MB

var logFilePath = func() string {
	exe, _ := os.Executable()
	return filepath.Join(filepath.Dir(exe), "vanguard_log.txt")
}

var logWrites int

// writeLogFile: "2026-10-18 21:04:05 | who | text" (called with h.mu held, so one writer at a time).
func writeLogFile(who, text string) {
	path := logFilePath()
	f, err := os.OpenFile(path, os.O_CREATE|os.O_APPEND|os.O_WRONLY, 0o644)
	if err != nil {
		return
	}
	text = strings.NewReplacer("\r", " ", "\n", " ").Replace(text)
	fmt.Fprintf(f, "%s | %s | %s\n", time.Now().Format("2006-01-02 15:04:05"), who, text)
	f.Close()
	if logWrites++; logWrites%200 == 1 {
		if st, err := os.Stat(path); err == nil && st.Size() > logFileMax {
			if b, err := os.ReadFile(path); err == nil {
				b = b[len(b)/2:]
				if i := strings.IndexByte(string(b), '\n'); i >= 0 {
					b = b[i+1:]
				}
				os.WriteFile(path, b, 0o644)
			}
		}
	}
}

// lastLogLines: the newest n lines of the log file, and every character name seen in them.
func lastLogLines(n int) ([]string, []string) {
	f, err := os.Open(logFilePath())
	if err != nil {
		return nil, nil
	}
	defer f.Close()
	var lines []string
	sc := bufio.NewScanner(f)
	sc.Buffer(make([]byte, 64*1024), 1<<20)
	for sc.Scan() {
		lines = append(lines, sc.Text())
		if len(lines) > n*2+1000 {
			lines = lines[len(lines)-n:]
		}
	}
	if len(lines) > n {
		lines = lines[len(lines)-n:]
	}
	seen := map[string]bool{}
	for _, l := range lines {
		if p := strings.SplitN(l, " | ", 3); len(p) == 3 && p[1] != "app" {
			seen[p[1]] = true
		}
	}
	names := make([]string, 0, len(seen))
	for k := range seen {
		names = append(names, k)
	}
	return lines, names
}

// copyText puts text on the Windows clipboard (clip.exe, which reads UTF-16 with a BOM).
var copyText = func(text string) error {
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

func (h *hub) sendLogs(n int) {
	switch {
	case n <= 0:
		n = 250
	case n > 2000:
		n = 2000
	}
	lines, names := lastLogLines(n)
	if len(lines) == 0 {
		h.addLog("No logs to send yet.")
		return
	}
	// the same CharA, CharB... for a name everywhere: names online now first (as in crash reports), then the rest
	all := h.names()
	have := map[string]bool{}
	for _, x := range all {
		have[strings.ToLower(x)] = true
	}
	sort.Strings(names)
	for _, x := range names {
		if !have[strings.ToLower(x)] {
			all = append(all, x)
			have[strings.ToLower(x)] = true
		}
	}
	text := scrubNames(strings.Join(lines, "\n"), all)
	// GitHub takes up to 65,536 characters in a report: the newest lines win
	full := text
	if len(full) > 60000 {
		full = full[len(full)-60000:]
		if i := strings.IndexByte(full, '\n'); i >= 0 {
			full = full[i+1:]
		}
	}
	copied := copyText("**Log (last " + fmt.Sprint(len(lines)) + " lines):**\n```\n" + full + "\n```\n") == nil
	exe, _ := os.Executable()
	os.WriteFile(filepath.Join(filepath.Dir(exe), "vanguard_log_report.txt"), []byte(full), 0o644)

	addon := currentAddonState()
	head := "**What happened:** (please describe what you were doing and what went wrong)\n\n" +
		fmt.Sprintf("**App:** %s  **Addon:** %s (installed %s)  **Windows:** %s/%s\n", panelVersion, addon.Bundled, addon.Installed, runtime.GOOS, runtime.GOARCH)
	if copied {
		head += fmt.Sprintf("\n**The full log (%d lines) is on your clipboard: click at the end of this box and press Ctrl+V.**\n", len(lines))
	} else {
		head += "\n**The full log is in vanguard_log_report.txt next to Vanguard Control.exe: drag it into this box.**\n"
	}
	tail := "\n_Sent from Vanguard Control. Character names and the Windows user name were replaced._\n"
	head = scrubNames(head, all)
	// the newest lines that fit in the link (browsers and GitHub cut very long links)
	ls := strings.Split(text, "\n")
	k := len(ls)
	body := ""
	for k > 0 {
		body = head + fmt.Sprintf("\n**Newest log lines:**\n```\n%s\n```\n", strings.Join(ls[len(ls)-k:], "\n")) + tail
		if len(url.QueryEscape(body)) <= 6500 {
			break
		}
		k = k * 4 / 5
	}
	if k == 0 {
		body = head + tail
	}
	openURL(issuesURL + "?title=" + url.QueryEscape("[logs] Vanguard Control") + "&body=" + url.QueryEscape(body))
	if copied {
		h.addLog("Opened a log report in your browser: the last %d log lines are on your clipboard - click in the report box, press Ctrl+V, describe the problem, then click Submit.", len(lines))
	} else {
		h.addLog("Opened a log report in your browser: drag vanguard_log_report.txt (next to the app) into the report box, describe the problem, then click Submit.")
	}
}
