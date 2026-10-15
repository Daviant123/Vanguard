// Profiles, CurePlease-style (user request 2026-10-15): a character's whole setup for a job - role, weapon skill,
// abilities with their thresholds, cure tiers, buffs, songs, geo, enfeebles, modules and the other settings - is
// saved by the app as a file in "profiles" next to the exe, and can be loaded onto any character. A profile can
// be set to load by itself whenever a character is on that job.
package main

import (
	"encoding/json"
	"fmt"
	"net/http"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
	"time"
)

var profileName = regexp.MustCompile(`^[A-Za-z0-9 _'()-]{1,40}$`)

type profileFile struct {
	Name  string          `json:"name"`
	Job   string          `json:"job"`
	From  string          `json:"from"`
	Saved string          `json:"saved"`
	Data  json.RawMessage `json:"data"`
}

func profilesDir() string {
	exe, _ := os.Executable()
	return filepath.Join(filepath.Dir(exe), "profiles")
}

func profilePath(job, name string) string {
	return filepath.Join(profilesDir(), job+" - "+name+".json")
}

func listProfiles() []profileFile {
	out := []profileFile{}
	files, _ := filepath.Glob(filepath.Join(profilesDir(), "*.json"))
	for _, f := range files {
		if filepath.Base(f) == "auto.json" {
			continue
		}
		b, err := os.ReadFile(f)
		if err != nil {
			continue
		}
		var p profileFile
		if json.Unmarshal(b, &p) == nil && p.Name != "" && p.Job != "" {
			p.Data = nil
			out = append(out, p)
		}
	}
	sort.Slice(out, func(i, j int) bool {
		if out[i].Job != out[j].Job {
			return out[i].Job < out[j].Job
		}
		return strings.ToLower(out[i].Name) < strings.ToLower(out[j].Name)
	})
	return out
}

func readProfile(job, name string) (profileFile, error) {
	var p profileFile
	b, err := os.ReadFile(profilePath(job, name))
	if err != nil {
		return p, err
	}
	err = json.Unmarshal(b, &p)
	return p, err
}

// auto.json: character -> job -> profile name that loads by itself.
func readAuto() map[string]map[string]string {
	m := map[string]map[string]string{}
	if b, err := os.ReadFile(filepath.Join(profilesDir(), "auto.json")); err == nil {
		json.Unmarshal(b, &m)
	}
	return m
}

func writeAuto(m map[string]map[string]string) error {
	os.MkdirAll(profilesDir(), 0o755)
	b, _ := json.MarshalIndent(m, "", "  ")
	return os.WriteFile(filepath.Join(profilesDir(), "auto.json"), b, 0o644)
}

// requestDump asks a character for its current setup and waits for the answer.
func (h *hub) requestDump(name string) (json.RawMessage, error) {
	ch := make(chan json.RawMessage, 1)
	h.mu.Lock()
	h.dumps[name] = ch
	h.mu.Unlock()
	defer func() { h.mu.Lock(); delete(h.dumps, name); h.mu.Unlock() }()
	if !h.send(name, "dump") {
		return nil, fmt.Errorf("%s isn't connected", name)
	}
	select {
	case d := <-ch:
		return d, nil
	case <-time.After(4 * time.Second):
		return nil, fmt.Errorf("%s didn't answer", name)
	}
}

// sendProfile puts a profile on a character, in parts (the addon reads UDP messages of up to 8 KB).
func (h *hub) sendProfile(name string, p profileFile) error {
	var data map[string]any
	if err := json.Unmarshal(p.Data, &data); err != nil {
		return err
	}
	data["name"] = p.Name
	b, _ := json.Marshal(data)
	text := string(b)
	const size = 6000
	parts := []string{}
	for len(text) > size {
		parts = append(parts, text[:size])
		text = text[size:]
	}
	parts = append(parts, text)
	h.mu.Lock()
	c, ok := h.chars[name]
	h.mu.Unlock()
	if !ok || c.addr == nil {
		return fmt.Errorf("%s isn't connected", name)
	}
	for i, part := range parts {
		msg := fmt.Sprintf("cfg %d/%d %s", i+1, len(parts), part)
		if _, err := h.conn.WriteToUDP([]byte(msg), c.addr); err != nil {
			return err
		}
	}
	return nil
}

// autoProfile: when a character shows up or changes job, load the profile set to load by itself.
func (h *hub) autoProfile(name, job string) {
	prof := readAuto()[name][job]
	if prof == "" {
		return
	}
	p, err := readProfile(job, prof)
	if err != nil {
		h.addLog("%s: profile \"%s\" for %s is missing (%v)", name, prof, job, err)
		return
	}
	time.Sleep(2 * time.Second) // let the addon finish setting the job up first
	if err := h.sendProfile(name, p); err == nil {
		h.addLog("%s is on %s: loaded profile \"%s\".", name, job, prof)
	}
}

func (h *hub) handleProfiles(w http.ResponseWriter, r *http.Request) {
	q := r.URL.Query()
	char, name, job := q.Get("char"), strings.TrimSpace(q.Get("name")), q.Get("job")
	reply := map[string]any{}
	fail := func(format string, a ...any) { reply["error"] = fmt.Sprintf(format, a...); h.addLog("%s", reply["error"]) }
	switch q.Get("do") {
	case "save":
		if !profileName.MatchString(name) {
			fail("Profile names: letters, digits, spaces and - _ ' ( ), up to 40.")
			break
		}
		data, err := h.requestDump(char)
		if err != nil {
			fail("Couldn't save: %v", err)
			break
		}
		var head struct{ Job string `json:"job"` }
		json.Unmarshal(data, &head)
		if head.Job == "" {
			fail("Couldn't save: %s sent no job", char)
			break
		}
		p := profileFile{Name: name, Job: head.Job, From: char, Saved: time.Now().Format("2006-01-02 15:04"), Data: data}
		os.MkdirAll(profilesDir(), 0o755)
		b, _ := json.MarshalIndent(p, "", "  ")
		if err := os.WriteFile(profilePath(p.Job, name), b, 0o644); err != nil {
			fail("Couldn't write the profile: %v", err)
			break
		}
		h.addLog("Saved %s's %s setup as profile \"%s\".", char, p.Job, name)
	case "load":
		p, err := readProfile(job, name)
		if err != nil {
			fail("No %s profile called \"%s\".", job, name)
			break
		}
		if err := h.sendProfile(char, p); err != nil {
			fail("Couldn't load: %v", err)
			break
		}
		h.addLog("Loaded profile \"%s\" (%s) on %s.", name, job, char)
	case "delete":
		if err := os.Remove(profilePath(job, name)); err != nil {
			fail("Couldn't delete \"%s\": %v", name, err)
			break
		}
		h.addLog("Deleted profile \"%s\" (%s).", name, job)
	case "auto":
		m := readAuto()
		if m[char] == nil {
			m[char] = map[string]string{}
		}
		if name == "" {
			delete(m[char], job)
			h.addLog("%s on %s: no profile loads by itself.", char, job)
		} else {
			m[char][job] = name
			h.addLog("%s on %s: profile \"%s\" loads by itself.", char, job, name)
		}
		writeAuto(m)
	case "folder":
		os.MkdirAll(profilesDir(), 0o755)
		openFolder(profilesDir())
	}
	reply["profiles"] = listProfiles()
	reply["auto"] = readAuto()
	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(reply)
}
