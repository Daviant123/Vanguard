// Vanguard Control - standalone Windows control panel for the Vanguard Windower addon.
//
// - Listens for addon snapshots on UDP 127.0.0.1:47000 (same protocol as before).
// - Serves the control panel UI on http://127.0.0.1:47001 and opens it in an
//   Edge app window (falls back to the default browser).
// - Nothing leaves the PC.
package main

import (
	"embed"
	"encoding/json"
	"fmt"
	"io/fs"
	"net"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strings"
	"sync"
	"time"
)

//go:embed web
var webFS embed.FS

const (
	udpAddr  = "127.0.0.1:47000"
	httpAddr = "127.0.0.1:47001"
	uiURL    = "http://" + httpAddr + "/"
)

type character struct {
	Snapshot map[string]any `json:"snapshot"`
	Profile  map[string]any `json:"profile"`
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
	mu     sync.Mutex
	conn   *net.UDPConn
	chars  map[string]*character
	logs   []logLine
	nextID int
}

func (h *hub) addLog(format string, args ...any) {
	h.mu.Lock()
	defer h.mu.Unlock()
	h.nextID++
	h.logs = append(h.logs, logLine{ID: h.nextID, Time: time.Now().Format("15:04:05"), Text: fmt.Sprintf(format, args...)})
	if len(h.logs) > 500 {
		h.logs = h.logs[len(h.logs)-500:]
	}
}

func (h *hub) listen() {
	buf := make([]byte, 65535)
	for {
		n, addr, err := h.conn.ReadFromUDP(buf)
		if err != nil {
			continue
		}
		var msg map[string]any
		if json.Unmarshal(buf[:n], &msg) != nil {
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
			h.mu.Unlock()
		case "log":
			text, _ := msg["text"].(string)
			h.mu.Lock()
			if c, ok := h.chars[name]; ok {
				c.addr = addr
			}
			h.mu.Unlock()
			h.addLog("%s: %s", name, text)
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
	body, _ := json.Marshal(map[string]any{"chars": chars, "logs": logs})
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
	sent := 0
	if req.Target == "*" {
		for _, n := range h.names() {
			if h.send(n, cmd) {
				sent++
			}
		}
		if cmd != "profile" {
			h.addLog("-> all: %s", cmd)
		}
	} else if h.send(req.Target, cmd) {
		sent = 1
		if cmd != "profile" {
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
	dir := filepath.Join(filepath.Dir(exe), "..", "addons", "Vanguard", "data")
	if _, err := os.Stat(dir); err != nil {
		dir = filepath.Dir(exe)
	}
	exec.Command("explorer", filepath.Clean(dir)).Start()
	w.WriteHeader(http.StatusNoContent)
}

// ---------------------------------------------------------------- launch

func openWindow() {
	// Edge app mode gives a clean standalone window; fall back to the default browser.
	edges := []string{
		filepath.Join(os.Getenv("ProgramFiles(x86)"), `Microsoft\Edge\Application\msedge.exe`),
		filepath.Join(os.Getenv("ProgramFiles"), `Microsoft\Edge\Application\msedge.exe`),
	}
	for _, e := range edges {
		if _, err := os.Stat(e); err == nil {
			if exec.Command(e, "--app="+uiURL, "--window-size=1180,860").Start() == nil {
				return
			}
		}
	}
	exec.Command("rundll32", "url.dll,FileProtocolHandler", uiURL).Start()
}

func main() {
	addr, _ := net.ResolveUDPAddr("udp", udpAddr)
	conn, err := net.ListenUDP("udp", addr)
	if err != nil {
		// Already running: just bring up another window on the existing instance.
		openWindow()
		return
	}
	h := &hub{conn: conn, chars: map[string]*character{}}
	h.addLog("Listening on %s. Load the addon in game with //lua load vanguard", udpAddr)
	go h.listen()

	web, _ := fs.Sub(webFS, "web")
	mux := http.NewServeMux()
	mux.Handle("/", http.FileServer(http.FS(web)))
	mux.HandleFunc("/api/state", h.handleState)
	mux.HandleFunc("/api/send", h.handleSend)
	mux.HandleFunc("/api/leader", h.handleLeader)
	mux.HandleFunc("/api/setup", h.handleSetup)
	mux.HandleFunc("/api/open-settings", handleOpenSettings)
	mux.HandleFunc("/api/quit", func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusNoContent)
		go func() { time.Sleep(200 * time.Millisecond); os.Exit(0) }()
	})

	ln, err := net.Listen("tcp", httpAddr)
	if err != nil {
		os.Exit(1)
	}
	go openWindow()
	http.Serve(ln, mux)
}
