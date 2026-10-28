// Vanguard Control - standalone Windows control panel for the Vanguard Windower addon.
//
// - Listens for addon snapshots on UDP 127.0.0.1:47000 (same protocol as before).
// - Serves the control panel UI on http://127.0.0.1:47001 and opens it in an
//   Edge app window (falls back to the default browser).
// - Nothing leaves the PC.
package main

import (
	"bytes"
	"embed"
	"errors"
	"encoding/json"
	"fmt"
	"io/fs"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"sync"
	"time"
)

//go:embed web
var webFS embed.FS

var (
	udpAddr  = "127.0.0.1:47000"
	httpAddr = "127.0.0.1:47001"
	uiURL    = "http://" + httpAddr + "/"
)

// VANGUARD_CONTROL_PORTS=48000,48001 runs a test copy beside the real one (the game only talks to 47000).
func init() {
	if p := strings.Split(os.Getenv("VANGUARD_CONTROL_PORTS"), ","); len(p) == 2 {
		udpAddr, httpAddr = "127.0.0.1:"+p[0], "127.0.0.1:"+p[1]
		uiURL = "http://" + httpAddr + "/"
	}
}

type character struct {
	Snapshot map[string]any `json:"snapshot"`
	Profile  map[string]any `json:"profile"`
	Nearby   map[string]any `json:"nearby,omitempty"` // the last "Look around" answer (mobs near it)
	LastSeen time.Time      `json:"-"`
	Online   bool           `json:"online"`
	addr     *net.UDPAddr
}

type logLine struct {
	ID   int    `json:"id"`
	Time string `json:"time"`
	Text string `json:"text"`
}

type hub struct {
	updateNow chan string
	dumps     map[string]chan json.RawMessage // characters asked for their setup (profiles)
	jobs      map[string]string               // last job seen per character (auto-load profiles)
	timer     stopTimer                       // the stop timer (timer.go)
	mu     sync.Mutex
	conn   *net.UDPConn
	chars  map[string]*character
	logs   []logLine
	nextID int
}

func (h *hub) addLog(format string, args ...any) { h.addLogFrom("app", format, args...) }

// addLogFrom: who is "app" or the character the line came from (kept in the log file for Send logs, logfile.go).
func (h *hub) addLogFrom(who, format string, args ...any) {
	h.mu.Lock()
	defer h.mu.Unlock()
	h.nextID++
	text := fmt.Sprintf(format, args...)
	h.logs = append(h.logs, logLine{ID: h.nextID, Time: time.Now().Format("15:04:05"), Text: text})
	writeLogFile(who, text)
	if len(h.logs) > 500 {
		h.logs = h.logs[len(h.logs)-500:]
	}
}

func (h *hub) listen() {
	buf := make([]byte, 65535)
	parts := map[string][]string{} // big messages arrive in parts: "vgpart <id> <i>/<n> <text>"
	for {
		n, addr, err := h.conn.ReadFromUDP(buf)
		if err != nil {
			if errors.Is(err, net.ErrClosed) {
				return
			}
			continue
		}
		data := buf[:n]
		if bytes.HasPrefix(data, []byte("vgpart ")) {
			var id, i, total int
			var head string
			if c, _ := fmt.Sscanf(string(data), "vgpart %d %d/%d", &id, &i, &total); c != 3 || i < 1 || total < 1 || i > total || total > 50 {
				continue
			}
			head = fmt.Sprintf("vgpart %d %d/%d ", id, i, total)
			key := fmt.Sprintf("%s#%d", addr.String(), id)
			if parts[key] == nil {
				parts[key] = make([]string, total)
			}
			parts[key][i-1] = string(data[len(head):])
			done := true
			for _, p := range parts[key] {
				if p == "" {
					done = false
				}
			}
			if !done {
				continue
			}
			data = []byte(strings.Join(parts[key], ""))
			delete(parts, key)
			if len(parts) > 100 { // stale halves from a crashed client
				parts = map[string][]string{}
			}
		}
		var msg map[string]any
		if json.Unmarshal(data, &msg) != nil {
			continue
		}
		name, _ := msg["name"].(string)
		if name == "" {
			continue
		}
		switch msg["type"] {
		case "state":
			h.mu.Lock()
			c, ok := h.chars[name]
			if !ok {
				c = &character{}
				h.chars[name] = c
			}
			c.Snapshot, c.LastSeen, c.addr = msg, time.Now(), addr
			h.mu.Unlock()
			if !ok {
				h.addLog("%s connected", name)
			}
		case "profile":
			h.mu.Lock()
			c, ok := h.chars[name]
			if !ok {
				c = &character{Snapshot: map[string]any{"name": name}}
				h.chars[name] = c
			}
			c.Profile, c.addr = msg, addr
			job, _ := msg["job"].(string)
			changed := job != "" && h.jobs[name] != job
			if changed {
				h.jobs[name] = job
			}
			h.mu.Unlock()
			if changed {
				h.safeGo("loading a profile by itself", func() { h.autoProfile(name, job) })
			}
		case "nearby":
			h.mu.Lock()
			if c, ok := h.chars[name]; ok {
				c.Nearby = msg
				c.addr = addr
			}
			h.mu.Unlock()
		case "farmrun":
			h.addFarmRun(msg)
		case "crash":
			// vg_crash.lua caught an error in the addon
			str := func(k string) string { v, _ := msg[k].(string); return v }
			h.addCrash(crashReport{Source: "addon", Who: name, Job: str("job"), Version: str("version"),
				Where: str("where"), Error: str("err"), Trace: str("trace")})
		case "dump":
			raw, _ := json.Marshal(msg["data"])
			h.mu.Lock()
			if ch, ok := h.dumps[name]; ok {
				select {
				case ch <- raw:
				default:
				}
			}
			h.mu.Unlock()
		case "log":
			text, _ := msg["text"].(string)
			h.mu.Lock()
			if c, ok := h.chars[name]; ok {
				c.addr = addr
			}
			h.mu.Unlock()
			h.addLogFrom(name, "%s: %s", name, text)
			h.alarmFromLog(name, text)
		}
	}
}

func (h *hub) send(name, command string) bool {
	h.mu.Lock()
	c, ok := h.chars[name]
	h.mu.Unlock()
	if !ok || c.addr == nil {
		return false
	}
	_, err := h.conn.WriteToUDP([]byte("cmd "+command), c.addr)
	return err == nil
}

func (h *hub) names() []string {
	h.mu.Lock()
	defer h.mu.Unlock()
	out := make([]string, 0, len(h.chars))
	for n := range h.chars {
		out = append(out, n)
	}
	sort.Strings(out)
	return out
}

// ---------------------------------------------------------------- HTTP API

func (h *hub) handleState(w http.ResponseWriter, r *http.Request) {
	var since int
	fmt.Sscan(r.URL.Query().Get("since"), &since)
	h.mu.Lock()
	chars := map[string]*character{}
	for n, c := range h.chars {
		c.Online = time.Since(c.LastSeen) < 5*time.Second
		chars[n] = c
	}
	logs := []logLine{}
	for _, l := range h.logs {
		if l.ID > since {
			logs = append(logs, l)
		}
	}
	body, _ := json.Marshal(map[string]any{"chars": chars, "logs": logs, "version": panelVersion})
	h.mu.Unlock()
	w.Header().Set("Content-Type", "application/json")
	w.Write(body)
}

func (h *hub) handleSend(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, "POST only", http.StatusMethodNotAllowed)
		return
	}
	var req struct {
		Target  string `json:"target"` // character name or "*" for all
		Command string `json:"command"`
	}
	if json.NewDecoder(r.Body).Decode(&req) != nil || strings.TrimSpace(req.Command) == "" {
		http.Error(w, "bad request", http.StatusBadRequest)
		return
	}
	cmd := strings.TrimSpace(strings.TrimPrefix(strings.TrimSpace(req.Command), "//vg "))
	if strings.Contains(cmd, "logout") {
		quietAlarms(3 * time.Minute) // logging out on purpose: no "went offline" alarm
	}
	sent := 0
	if req.Target == "*" {
		for _, n := range h.names() {
			if h.send(n, cmd) {
				sent++
			}
		}
		if cmd != "profile" && cmd != "radar" { // (the Farming tab asks for the radar every few seconds)
			h.addLog("-> all: %s", cmd)
		}
	} else if h.send(req.Target, cmd) {
		sent = 1
		if cmd != "profile" && cmd != "radar" { // (the Farming tab asks for the radar every few seconds)
			h.addLog("-> %s: %s", req.Target, cmd)
		}
	}
	json.NewEncoder(w).Encode(map[string]int{"sent": sent})
}

func (h *hub) handleLeader(w http.ResponseWriter, r *http.Request) {
	leader := r.URL.Query().Get("name")
	for _, n := range h.names() {
		if n != leader {
			h.send(n, "leader "+leader)
			h.send(n, "follow on")
		}
	}
	h.addLog("Leader set to %s; others following.", leader)
	w.WriteHeader(http.StatusNoContent)
}

func (h *hub) handleSetup(w http.ResponseWriter, r *http.Request) {
	leader := r.URL.Query().Get("leader")
	for _, n := range h.names() {
		if n == leader {
			h.send(n, "leader none")
		} else {
			h.send(n, "leader "+leader)
		}
		h.send(n, "autosetup")
	}
	h.addLog("Party set up: %s leads, everyone else follows and uses their job's recommended setup.", leader)
	w.WriteHeader(http.StatusNoContent)
}

func handleOpenSettings(w http.ResponseWriter, r *http.Request) {
	exe, _ := os.Executable()
	dir := filepath.Dir(exe)
	if st := currentAddonState(); st.Found {
		dir = filepath.Join(st.Windower, "addons", "Vanguard")
		if _, err := os.Stat(filepath.Join(dir, "data")); err == nil {
			dir = filepath.Join(dir, "data")
		}
	}
	openFolder(dir)
	w.WriteHeader(http.StatusNoContent)
}

func openFolder(dir string) { openFolderOS(dir) }

// ---------------------------------------------------------------- launch

func openWindow() { openAppWindow(uiURL) }

func main() {
	// --no-window: started by the self-update; the old panel's window stays open and keeps working.
	restarted := len(os.Args) > 1 && os.Args[1] == "--no-window"
	cleanupOld()
	addr, _ := net.ResolveUDPAddr("udp", udpAddr)
	conn, err := net.ListenUDP("udp", addr)
	for i := 0; err != nil && restarted && i < 20; i++ { // the old one is still letting go of the port
		time.Sleep(250 * time.Millisecond)
		conn, err = net.ListenUDP("udp", addr)
	}
	if err != nil {
		// Already running: just bring up another window on the existing instance.
		openWindow()
		return
	}
	h := &hub{conn: conn, chars: map[string]*character{}, updateNow: make(chan string, 1),
		dumps: map[string]chan json.RawMessage{}, jobs: map[string]string{}}
	h.addLog("Vanguard Control %s. Listening on %s. Load the addon in game with //lua load vanguard", panelVersion, udpAddr)
	// A crash in the app itself is kept as a report (crashes.go); background jobs restart after one.
	defer func() {
		if r := recover(); r != nil {
			h.recordPanic("main", r)
			panic(r)
		}
	}()
	h.safeGo("listening to the characters", h.listen)
	h.safeGo("stop timer", h.timerLoop)
	loadAlarms()
	h.safeGo("alarms", h.alarmLoop)
	// The addon: find Windower, install / update the one built into this exe, reload old copies.
	h.safeGo("addon install / reload", func() {
		if msg := h.ensureAddon(false); msg != "" && msg != "ok" {
			h.addLog("%s", msg)
		}
		h.reloadWatch()
	})

	web, _ := fs.Sub(webFS, "web")
	mux := http.NewServeMux()
	mux.Handle("/", http.FileServer(http.FS(web)))
	mux.HandleFunc("/api/state", h.handleState)
	mux.HandleFunc("/api/send", h.handleSend)
	mux.HandleFunc("/api/leader", h.handleLeader)
	mux.HandleFunc("/api/setup", h.handleSetup)
	mux.HandleFunc("/api/open-settings", handleOpenSettings)
	mux.HandleFunc("/api/addon", h.handleAddon)
	mux.HandleFunc("/api/profiles", h.handleProfiles)
	mux.HandleFunc("/api/quick", h.handleQuick)
	mux.HandleFunc("/api/timer", h.handleTimer)
	mux.HandleFunc("/api/crashes", h.handleCrashes)
	mux.HandleFunc("/api/alarms", h.handleAlarms)
	mux.HandleFunc("/api/farmruns", h.handleFarmRuns)
	mux.HandleFunc("/api/quit", func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusNoContent)
		go func() { time.Sleep(200 * time.Millisecond); os.Exit(0) }()
	})

	ln, err := net.Listen("tcp", httpAddr)
	for i := 0; err != nil && restarted && i < 20; i++ {
		time.Sleep(250 * time.Millisecond)
		ln, err = net.Listen("tcp", httpAddr)
	}
	if err != nil {
		os.Exit(1)
	}
	h.safeGo("self-update", func() { h.autoUpdate(func(exe string) {
		// Start the new one first (it waits for the ports), then step aside.
		if err := startDetached(exe); err != nil {
			h.addLog("Couldn't restart (%v): close and reopen Vanguard Control to use the new version.", err)
			return
		}
		ln.Close()
		conn.Close()
		os.Exit(0)
	}) })
	if !restarted {
		go openWindow()
	}
	http.Serve(ln, h.guardHTTP(mux))
}
