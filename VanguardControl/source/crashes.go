// Crash reports (user request 2026-10-16). Problems from the addon ("crash" messages from vg_crash.lua) and from the
// app itself (a panic in a request or a background job) are kept in crashes.json next to the exe. The app shows them
// under App & updates > Problems; "Send report" opens a ready-made report on the GitHub page in the browser - the
// player clicks Submit there and the owner gets it. Character names and the Windows user name are replaced first,
// and nothing is sent without that click. (No key or password is built into the exe.)
package main

import (
	"encoding/json"
	"fmt"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"regexp"
	"runtime"
	"runtime/debug"
	"strconv"
	"strings"
	"sync"
	"time"
)

const issuesURL = "https://github.com/Daviant123/Vanguard/issues/new"

type crashReport struct {
	Time    string `json:"time"`
	Source  string `json:"source"` // addon | app
	Who     string `json:"who,omitempty"`
	Job     string `json:"job,omitempty"`
	Version string `json:"version"`
	Where   string `json:"where"`
	Error   string `json:"error"`
	Trace   string `json:"trace,omitempty"`
	Count   int    `json:"count"`
	Sent    bool   `json:"sent"`
}

var crashMu sync.Mutex
var openURL = openURLOS

func crashPath() string {
	exe, _ := os.Executable()
	return filepath.Join(filepath.Dir(exe), "crashes.json")
}

func loadCrashes() []crashReport {
	var list []crashReport
	if b, err := os.ReadFile(crashPath()); err == nil {
		json.Unmarshal(b, &list)
	}
	if list == nil {
		list = []crashReport{}
	}
	return list
}

func saveCrashes(list []crashReport) {
	if len(list) > 30 {
		list = list[len(list)-30:]
	}
	b, _ := json.MarshalIndent(list, "", "  ")
	os.WriteFile(crashPath(), b, 0o644)
}

// addCrash keeps a report; the same problem again just counts up (and is unsent again if it came back).
func (h *hub) addCrash(c crashReport) {
	crashMu.Lock()
	defer crashMu.Unlock()
	list := loadCrashes()
	c.Time = time.Now().Format("2006-01-02 15:04:05")
	if len(c.Error) > 2000 {
		c.Error = c.Error[:2000]
	}
	if len(c.Trace) > 6000 {
		c.Trace = c.Trace[:6000]
	}
	for i := range list {
		if list[i].Source == c.Source && list[i].Where == c.Where && list[i].Error == c.Error && list[i].Version == c.Version {
			list[i].Count++
			list[i].Time = c.Time
			saveCrashes(list)
			return
		}
	}
	c.Count = 1
	list = append(list, c)
	saveCrashes(list)
	if h != nil {
		h.alarmProblem(c.Where)
		h.addLog("A problem was caught (%s, %s): see App & updates > Problems to send a report.", c.Source, c.Where)
	}
}

// recordPanic: call in a deferred function; keeps an app crash with its stack.
func (h *hub) recordPanic(where string, r any) {
	h.addCrash(crashReport{Source: "app", Version: panelVersion, Where: where, Error: fmt.Sprint(r), Trace: string(debug.Stack())})
}

// safeGo runs a background job; if it panics, the panic is kept and the job starts again after a pause.
func (h *hub) safeGo(where string, fn func()) {
	go func() {
		for {
			done := func() (finished bool) {
				defer func() {
					if r := recover(); r != nil {
						h.recordPanic(where, r)
						finished = false
					}
				}()
				fn()
				return true
			}()
			if done {
				return
			}
			time.Sleep(5 * time.Second)
		}
	}()
}

// guardHTTP: a panic in one request is kept as a report instead of being lost.
func (h *hub) guardHTTP(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		defer func() {
			if rec := recover(); rec != nil {
				h.recordPanic("request "+r.URL.Path, rec)
				http.Error(w, "internal error (kept as a crash report)", http.StatusInternalServerError)
			}
		}()
		next.ServeHTTP(w, r)
	})
}

// scrub takes out character names and the Windows user name.
func (h *hub) scrub(text string) string { return scrubNames(text, h.names()) }

func scrubNames(text string, names []string) string {
	for i, n := range names {
		if len(n) >= 3 {
			text = regexp.MustCompile(`(?i)\b`+regexp.QuoteMeta(n)+`\b`).ReplaceAllString(text, "Char"+string(rune('A'+i%26)))
		}
	}
	text = regexp.MustCompile(`(?i)(C:[\\/]+Users[\\/]+)[^\\/\s"']+`).ReplaceAllString(text, "${1}<user>")
	if u := os.Getenv("USERNAME"); len(u) >= 3 {
		text = regexp.MustCompile(`(?i)\b`+regexp.QuoteMeta(u)+`\b`).ReplaceAllString(text, "<user>")
	}
	return text
}

// reportURL builds the GitHub "new issue" link for a report (kept short enough for a browser).
func (h *hub) reportURL(c *crashReport) string {
	h.mu.Lock()
	var recent []string
	for i := len(h.logs) - 1; i >= 0 && len(recent) < 15; i-- {
		recent = append([]string{h.logs[i].Time + " " + h.logs[i].Text}, recent...)
	}
	h.mu.Unlock()
	addon := currentAddonState()
	var b strings.Builder
	title := "[crash] Vanguard Control"
	if c != nil {
		title = fmt.Sprintf("[crash] %s: %s", c.Where, firstLine(c.Error))
		fmt.Fprintf(&b, "**What broke:** %s (%s)\n**Error:** %s\n**Seen:** %d time(s), last %s\n", c.Where, c.Source, c.Error, c.Count, c.Time)
		if c.Job != "" {
			fmt.Fprintf(&b, "**Job:** %s\n", c.Job)
		}
	} else {
		title = "[problem] Vanguard Control"
		b.WriteString("**What happened:** (please describe what you were doing and what went wrong)\n")
	}
	fmt.Fprintf(&b, "**App:** %s  **Addon:** %s (installed %s)  **System:** %s/%s\n", panelVersion, addon.Bundled, addon.Installed, runtime.GOOS, runtime.GOARCH)
	if c != nil && c.Trace != "" {
		trace := c.Trace
		if len(trace) > 2500 {
			trace = trace[:2500] + "\n..."
		}
		fmt.Fprintf(&b, "\n**Where in the code:**\n```\n%s\n```\n", trace)
	}
	if len(recent) > 0 {
		fmt.Fprintf(&b, "\n**Last app messages:**\n```\n%s\n```\n", strings.Join(recent, "\n"))
	}
	b.WriteString("\n_Sent from Vanguard Control. Character names and the Windows user name were replaced._\n")
	body := h.scrub(b.String())
	title = h.scrub(title)
	if len(title) > 120 {
		title = title[:120]
	}
	for len(url.QueryEscape(body)) > 6500 && len(body) > 500 { // browsers and GitHub cut very long links
		body = body[:len(body)*4/5] + "\n...(shortened)"
	}
	return issuesURL + "?title=" + url.QueryEscape(title) + "&body=" + url.QueryEscape(body)
}

func firstLine(s string) string {
	if i := strings.IndexAny(s, "\r\n"); i >= 0 {
		s = s[:i]
	}
	if len(s) > 80 {
		s = s[:80]
	}
	return s
}

func (h *hub) handleCrashes(w http.ResponseWriter, r *http.Request) {
	q := r.URL.Query()
	switch q.Get("do") {
	case "report", "dismiss":
		i, err := strconv.Atoi(q.Get("i"))
		crashMu.Lock()
		list := loadCrashes()
		if err == nil && i >= 0 && i < len(list) {
			if q.Get("do") == "report" {
				c := list[i]
				crashMu.Unlock()
				openURL(h.reportURL(&c))
				crashMu.Lock()
				list = loadCrashes()
				if i < len(list) {
					list[i].Sent = true
				}
				h.addLog("Opened the crash report in your browser: click Submit there to send it.")
			} else {
				list = append(list[:i], list[i+1:]...)
			}
			saveCrashes(list)
		}
		crashMu.Unlock()
	case "logs":
		n, _ := strconv.Atoi(q.Get("n"))
		h.sendLogs(n)
	case "problem":
		openURL(h.reportURL(nil))
		h.addLog("Opened a problem report in your browser: describe what happened, then click Submit.")
	case "clear":
		crashMu.Lock()
		saveCrashes([]crashReport{})
		crashMu.Unlock()
	}
	crashMu.Lock()
	list := loadCrashes()
	crashMu.Unlock()
	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(list)
}
