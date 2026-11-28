// Team planner (2.0.0, Silmaril audit item 3.1). Off by default (App setting, Team tab).
//
// Every character already sends its state to the app. While the planner is on, the addon adds a small "plan" part to
// that state (healer: the party members it can reach, their distance and HP; Enfeebler mode: the mobs it would take,
// in its own order, and its enfeebler.count) and reports a reactive skillchain follow-up the moment it queues one
// ("scfq"). Up to 4 times a second the app works out team-wide jobs and sends them to every character as one line:
//
//	plan <seq> cure=Member:Healer,... enf=Char:mobid/mobid,Char:- scf=Char:mob:pid:1,Char:mob:pid:0
//
//	cure  which healer covers which party member (spread by distance, MP, who is casting; a member under the
//	      emergency HP is still cured by anyone - the addon checks that, share.emergency)
//	enf   which character keeps which mobs enfeebled (no two on the same mob; each up to its enfeebler.count;
//	      "-" = nothing for you right now)
//	scf   one character per skillchain trigger on a mob: 1 = you close it, 0 = someone else does
//
// The addon only follows a plan that is under 3 s old and came from the app's own port; with the app closed or the
// planner off it decides by itself, exactly as before. Nothing here talks to the game.
package main

import (
	"encoding/json"
	"fmt"
	"math"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"sync"
	"time"
)

const (
	planEvery     = 250 * time.Millisecond // at most 4 plans a second
	planHeartbeat = time.Second            // an unchanged plan is re-sent this often (the addon wants it under 3 s old)
	planStale     = 3 * time.Second        // a character's state older than this is not planned with
	scfGroup      = 1.5                    // follow-ups due within this many seconds of each other answer one trigger
)

// ---------------------------------------------------------------- inputs

type planMember struct {
	Name string
	Dist float64
	HPP  float64
}

type planMob struct {
	ID   int
	Dist float64
	BT   bool // the mob it fights
	Pull bool // an unclaimed mob (enfeebler.pull): only to fill the count, never while the party fights enough
}

type planChar struct {
	Name    string
	HPP     float64
	MPP     float64
	Healer  bool
	Casting bool
	Members []planMember // healer: the members it can reach
	Enf     bool
	EnfN    int       // enfeebler.count
	Mobs    []planMob // Enfeebler candidates, in the character's own order
}

// a queued reactive skillchain follow-up ("scfq" from the addon)
type scfPending struct {
	Name  string
	Mob   int
	PID   int
	Due   time.Time // when its weapon skill is due
	TP    float64
	Reach bool // the mob is in weapon skill reach
	Seen  time.Time
}

type teamPlan struct {
	Cure map[string]string // member (lower case) -> healer name
	Enf  map[string][]int  // character -> mob ids ("" list = nothing)
	Scf  []scfVerdict
}

type scfVerdict struct {
	Name string
	Mob  int
	PID  int
	Keep bool
}

func num(v any) float64 {
	switch x := v.(type) {
	case float64:
		return x
	case int:
		return float64(x)
	}
	return 0
}

// planCharFrom reads what the planner needs out of one character's snapshot (nil = nothing to plan with).
func planCharFrom(name string, snap map[string]any) *planChar {
	if snap == nil {
		return nil
	}
	c := &planChar{Name: name, HPP: num(snap["hpp"]), MPP: num(snap["mpp"])}
	if st, _ := snap["status"].(string); st == "Dead" {
		c.HPP = 0
	}
	// Vanguard stopped (//vg off, the app's Stop, not started yet) or away: it cures and enfeebles nobody, so it is
	// given nobody (the addon leaves its plan part out then too; this covers an older addon)
	if en, ok := snap["enabled"].(bool); ok && !en {
		return c
	}
	if away, _ := snap["away"].(bool); away {
		return c
	}
	p, _ := snap["plan"].(map[string]any)
	if p == nil {
		return c
	}
	if hl, ok := p["heal"].(map[string]any); ok {
		c.Healer = true
		c.Casting, _ = hl["casting"].(bool)
		for _, x := range arrOf(hl["m"]) {
			m, _ := x.(map[string]any)
			n, _ := m["n"].(string)
			if n != "" {
				c.Members = append(c.Members, planMember{Name: n, Dist: num(m["d"]), HPP: num(m["hpp"])})
			}
		}
	}
	if e, ok := p["enf"].(map[string]any); ok {
		c.Enf = true
		c.EnfN = int(num(e["n"]))
		if c.EnfN < 1 {
			c.EnfN = 1
		}
		for _, x := range arrOf(e["mobs"]) {
			m, _ := x.(map[string]any)
			id := int(num(m["id"]))
			if id > 0 {
				bt, _ := m["bt"].(bool)
				pull, _ := m["p"].(bool)
				c.Mobs = append(c.Mobs, planMob{ID: id, Dist: num(m["d"]), BT: bt, Pull: pull})
			}
		}
	}
	return c
}

// Lua's JSON writes an empty list as {} - treat both as a list
func arrOf(v any) []any {
	switch x := v.(type) {
	case []any:
		return x
	}
	return nil
}

// ---------------------------------------------------------------- the plan

// makePlan: pure, so it can be tested. prev keeps assignments steady (no flip-flopping between two healers).
func makePlan(chars []*planChar, pend []scfPending, prev *teamPlan, now time.Time) teamPlan {
	sort.Slice(chars, func(i, j int) bool { return chars[i].Name < chars[j].Name })
	out := teamPlan{Cure: map[string]string{}, Enf: map[string][]int{}}
	planCure(chars, prev, &out)
	planEnf(chars, prev, &out)
	out.Scf = planScf(pend, now)
	return out
}

// (a) cure coverage: each member to one healer
func planCure(chars []*planChar, prev *teamPlan, out *teamPlan) {
	var healers []*planChar
	for _, c := range chars {
		if c.Healer && c.HPP > 0 {
			healers = append(healers, c)
		}
	}
	if len(healers) < 2 {
		return // one healer (or none): nothing to share out, the addon decides by itself
	}
	type cand struct {
		h *planChar
		d float64
	}
	reach := map[string][]cand{}
	shown := map[string]string{}
	for _, h := range healers {
		for _, m := range h.Members {
			k := strings.ToLower(m.Name)
			reach[k] = append(reach[k], cand{h, m.Dist})
			shown[k] = m.Name
		}
	}
	members := make([]string, 0, len(reach))
	for k := range reach {
		members = append(members, k)
	}
	// the members only one or two healers reach go first, so the free healers take the rest
	sort.Slice(members, func(i, j int) bool {
		a, b := len(reach[members[i]]), len(reach[members[j]])
		if a != b {
			return a < b
		}
		return members[i] < members[j]
	})
	load := map[string]int{}
	for _, k := range members {
		best, bestCost := "", math.Inf(1)
		for _, c := range reach[k] {
			cost := c.d/4 + (100-c.h.MPP)/20 + float64(load[c.h.Name])*1.5
			if c.h.Casting {
				cost += 1.5
			}
			if c.h.MPP < 10 {
				cost += 10 // nearly out of MP: only if nobody else reaches him
			}
			if prev != nil && prev.Cure[k] == c.h.Name {
				cost -= 1 // keep the healer he had
			}
			if cost < bestCost || (cost == bestCost && c.h.Name < best) {
				best, bestCost = c.h.Name, cost
			}
		}
		if best != "" {
			out.Cure[k] = best
			load[best]++
		}
	}
}

// (b) Enfeebler: no two characters on the same mob, each up to its own count
func planEnf(chars []*planChar, prev *teamPlan, out *teamPlan) {
	var enf []*planChar
	for _, c := range chars {
		if c.Enf && c.HPP > 0 {
			enf = append(enf, c)
		}
	}
	if len(enf) < 2 {
		return
	}
	had := map[int]string{}
	if prev != nil {
		for n, ids := range prev.Enf {
			for _, id := range ids {
				had[id] = n
			}
		}
	}
	type pair struct {
		c    *planChar
		mob  int
		rank int
		cost float64
	}
	var pairs, pulls []pair
	fighting := map[string]int{} // how many mobs fighting the party each character sees
	for _, c := range enf {
		for _, m := range c.Mobs {
			if !m.Pull {
				fighting[c.Name]++
			}
		}
	}
	for _, c := range enf {
		for i, m := range c.Mobs {
			cost := float64(i)*2 + m.Dist/5
			if m.Pull {
				// pulling only fills the count (the addon's rule): never while the party already fights that many
				if fighting[c.Name] < c.EnfN {
					pulls = append(pulls, pair{c, m.ID, i, cost})
				}
				continue
			}
			if m.BT {
				cost -= 1
			}
			if had[m.ID] == c.Name {
				cost -= 1.5
			}
			pairs = append(pairs, pair{c, m.ID, i, cost})
		}
	}
	byCost := func(l []pair) {
		sort.SliceStable(l, func(i, j int) bool {
			if l[i].cost != l[j].cost {
				return l[i].cost < l[j].cost
			}
			if l[i].c.Name != l[j].c.Name {
				return l[i].c.Name < l[j].c.Name
			}
			return l[i].mob < l[j].mob
		})
	}
	byCost(pairs)
	byCost(pulls)
	taken := map[int]bool{}
	got := map[string][]pair{}
	// the mobs fighting the party first; pulls only after every one of those is taken
	for _, list := range [][]pair{pairs, pulls} {
		for _, p := range list {
			if taken[p.mob] || len(got[p.c.Name]) >= p.c.EnfN {
				continue
			}
			taken[p.mob] = true
			got[p.c.Name] = append(got[p.c.Name], p)
		}
	}
	for _, c := range enf {
		list := got[c.Name]
		sort.Slice(list, func(i, j int) bool { return list[i].rank < list[j].rank }) // in its own order
		ids := []int{}
		for _, p := range list {
			ids = append(ids, p.mob)
		}
		out.Enf[c.Name] = ids
	}
}

// (c) reactive skillchains: one character per trigger on a mob
func planScf(pend []scfPending, now time.Time) []scfVerdict {
	byMob := map[int][]scfPending{}
	for _, p := range pend {
		if now.Sub(p.Due) > 3*time.Second { // long gone
			continue
		}
		byMob[p.Mob] = append(byMob[p.Mob], p)
	}
	mobs := make([]int, 0, len(byMob))
	for m := range byMob {
		mobs = append(mobs, m)
	}
	sort.Ints(mobs)
	better := func(a, b scfPending) bool { // a closes rather than b
		if a.Reach != b.Reach {
			return a.Reach
		}
		if (a.TP >= 1000) != (b.TP >= 1000) {
			return a.TP >= 1000
		}
		if a.TP != b.TP {
			return a.TP > b.TP
		}
		return a.Name < b.Name
	}
	var out []scfVerdict
	for _, m := range mobs {
		list := byMob[m]
		sort.Slice(list, func(i, j int) bool { return list[i].Due.Before(list[j].Due) })
		// follow-ups due within 1.5 s of the first one answer the same trigger; a later one is the next step
		for len(list) > 0 {
			n := 1
			for n < len(list) && list[n].Due.Sub(list[0].Due).Seconds() <= scfGroup {
				n++
			}
			group := list[:n]
			win := 0
			for i := range group {
				if better(group[i], group[win]) {
					win = i
				}
			}
			for i, p := range group {
				out = append(out, scfVerdict{Name: p.Name, Mob: p.Mob, PID: p.PID, Keep: i == win})
			}
			list = list[n:]
		}
	}
	sort.Slice(out, func(i, j int) bool {
		if out[i].Name != out[j].Name {
			return out[i].Name < out[j].Name
		}
		return out[i].PID < out[j].PID
	})
	return out
}

// encodePlan: the line sent to the addon (without "plan <seq>")
func encodePlan(p teamPlan) string {
	var parts []string
	if len(p.Cure) > 0 {
		keys := make([]string, 0, len(p.Cure))
		for k := range p.Cure {
			keys = append(keys, k)
		}
		sort.Strings(keys)
		var s []string
		for _, k := range keys {
			s = append(s, k+":"+p.Cure[k])
		}
		parts = append(parts, "cure="+strings.Join(s, ","))
	}
	if len(p.Enf) > 0 {
		keys := make([]string, 0, len(p.Enf))
		for k := range p.Enf {
			keys = append(keys, k)
		}
		sort.Strings(keys)
		var s []string
		for _, k := range keys {
			ids := []string{}
			for _, id := range p.Enf[k] {
				ids = append(ids, fmt.Sprint(id))
			}
			v := strings.Join(ids, "/")
			if v == "" {
				v = "-"
			}
			s = append(s, k+":"+v)
		}
		parts = append(parts, "enf="+strings.Join(s, ","))
	}
	if len(p.Scf) > 0 {
		var s []string
		for _, v := range p.Scf {
			k := 0
			if v.Keep {
				k = 1
			}
			s = append(s, fmt.Sprintf("%s:%d:%d:%d", v.Name, v.Mob, v.PID, k))
		}
		parts = append(parts, "scf="+strings.Join(s, ","))
	}
	return strings.Join(parts, " ")
}

// ---------------------------------------------------------------- running it

type plannerState struct {
	mu      sync.Mutex
	On      bool `json:"on"`
	seq     int
	last    teamPlan
	lastTxt string
	sentAt  time.Time
	sentTo  int
	pending map[string]scfPending // name -> its one queued follow-up
}

var planner = &plannerState{pending: map[string]scfPending{}}

func plannerPath() string {
	exe, _ := os.Executable()
	return filepath.Join(filepath.Dir(exe), "planner.json")
}

func loadPlanner() {
	var c struct {
		On bool `json:"on"`
	}
	if b, err := os.ReadFile(plannerPath()); err == nil {
		json.Unmarshal(b, &c)
	}
	planner.mu.Lock()
	planner.On = c.On
	planner.mu.Unlock()
}

func setPlanner(on bool) {
	planner.mu.Lock()
	planner.On = on
	planner.last, planner.lastTxt = teamPlan{}, ""
	planner.mu.Unlock()
	b, _ := json.Marshal(map[string]bool{"on": on})
	os.WriteFile(plannerPath(), b, 0o644)
}

// "scfq" from an addon: a follow-up was queued (d = seconds until due; d < 0 = it was used or dropped)
func (h *hub) plannerScf(name string, msg map[string]any) {
	planner.mu.Lock()
	defer planner.mu.Unlock()
	if num(msg["d"]) < 0 {
		// (only that follow-up: a late "gone" for an older one never removes a newer one)
		if p, ok := planner.pending[name]; ok && (msg["pid"] == nil || p.PID == int(num(msg["pid"]))) {
			delete(planner.pending, name)
		}
		return
	}
	now := time.Now()
	r, _ := msg["r"].(bool)
	planner.pending[name] = scfPending{Name: name, Mob: int(num(msg["mob"])), PID: int(num(msg["pid"])),
		Due: now.Add(time.Duration(num(msg["d"]) * float64(time.Second))), TP: num(msg["tp"]), Reach: r, Seen: now}
}

// planOnce: one planning pass; sends the plan if it changed or the last one is a second old. Returns whether it sent.
func (h *hub) planOnce(now time.Time) bool {
	planner.mu.Lock()
	on := planner.On
	planner.mu.Unlock()
	if !on {
		return false
	}
	var chars []*planChar
	var to []*net.UDPAddr
	h.mu.Lock()
	for n, c := range h.chars {
		if c.addr == nil || now.Sub(c.LastSeen) > planStale {
			continue
		}
		to = append(to, c.addr) // (copied under the lock: the listener changes c.addr)
		if pc := planCharFrom(n, c.Snapshot); pc != nil {
			chars = append(chars, pc)
		}
	}
	h.mu.Unlock()
	planner.mu.Lock()
	var pend []scfPending
	for n, p := range planner.pending {
		if now.Sub(p.Due) > 3*time.Second {
			delete(planner.pending, n)
			continue
		}
		pend = append(pend, p)
	}
	prev := planner.last
	planner.mu.Unlock()

	p := makePlan(chars, pend, &prev, now)
	txt := encodePlan(p)
	planner.mu.Lock()
	changed := txt != planner.lastTxt
	due := now.Sub(planner.sentAt) >= planHeartbeat
	if !changed && !due {
		planner.mu.Unlock()
		return false
	}
	planner.seq++
	line := fmt.Sprintf("plan %d %s", planner.seq, txt)
	planner.last, planner.lastTxt, planner.sentAt, planner.sentTo = p, txt, now, len(to)
	planner.mu.Unlock()
	for _, a := range to {
		h.sendRaw(a, line)
	}
	return true
}

// sendRaw: one line to an address read under h.mu by the caller (never c.addr after the lock is let go)
func (h *hub) sendRaw(a *net.UDPAddr, text string) bool {
	if a == nil || h.conn == nil {
		return false
	}
	_, err := h.conn.WriteToUDP([]byte(text), a)
	return err == nil
}

func (h *hub) plannerLoop() {
	t := time.NewTicker(planEvery)
	defer t.Stop()
	for range t.C {
		h.planOnce(time.Now())
	}
}

// for the Team tab: "planner: on, 3 characters, last plan 0.4 s ago"
func plannerStatus(now time.Time) map[string]any {
	planner.mu.Lock()
	defer planner.mu.Unlock()
	out := map[string]any{"on": planner.On, "chars": planner.sentTo, "age": -1.0}
	if planner.On && !planner.sentAt.IsZero() {
		out["age"] = math.Round(now.Sub(planner.sentAt).Seconds()*10) / 10
	}
	cure, enf, scf := len(planner.last.Cure), 0, len(planner.last.Scf)
	for _, ids := range planner.last.Enf {
		enf += len(ids)
	}
	out["cure"], out["enf"], out["scf"] = cure, enf, scf
	return out
}

// GET /api/planner            -> status
// GET /api/planner?on=1 | on=0 -> switch it, then status
func (h *hub) handlePlanner(w http.ResponseWriter, r *http.Request) {
	switch r.URL.Query().Get("on") {
	case "1", "true":
		setPlanner(true)
		h.addLog("Team planner on: the app shares out cures, Enfeebler mobs and skillchain closes.")
	case "0", "false":
		setPlanner(false)
		h.addLog("Team planner off: every character decides by itself again.")
	}
	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(plannerStatus(time.Now()))
}
