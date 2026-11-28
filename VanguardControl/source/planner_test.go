package main

import (
	"encoding/json"
	"net"
	"net/http/httptest"
	"os"
	"strings"
	"testing"
	"time"
)

func healer(name string, mpp float64, members ...planMember) *planChar {
	return &planChar{Name: name, HPP: 100, MPP: mpp, Healer: true, Members: members}
}

func TestPlanCureSpreadsMembers(t *testing.T) {
	now := time.Now()
	// two healers standing apart: each covers the ones next to it
	a := healer("CharC", 80, planMember{"CharC", 0, 100}, planMember{"CharB", 3, 90}, planMember{"CharA", 18, 90})
	b := healer("CharA", 80, planMember{"CharA", 0, 100}, planMember{"CharB", 17, 90}, planMember{"CharC", 18, 90})
	p := makePlan([]*planChar{a, b}, nil, nil, now)
	if p.Cure["charb"] != "CharC" || p.Cure["charc"] != "CharC" || p.Cure["chara"] != "CharA" {
		t.Errorf("each member goes to the nearest healer, got %v", p.Cure)
	}
	// same distance: the load is shared, not everyone on one healer
	m := func(n string) planMember { return planMember{n, 5, 90} }
	a = healer("CharC", 80, m("A1"), m("A2"), m("A3"), m("A4"))
	b = healer("CharA", 80, m("A1"), m("A2"), m("A3"), m("A4"))
	p = makePlan([]*planChar{a, b}, nil, nil, now)
	count := map[string]int{}
	for _, h := range p.Cure {
		count[h]++
	}
	if count["CharC"] != 2 || count["CharA"] != 2 {
		t.Errorf("four members, two healers at the same distance: two each, got %v", p.Cure)
	}
	// a healer out of MP covers nobody another healer can reach; one only it can reach stays with it
	a = healer("CharC", 5, m("A1"), m("A2"), planMember{"Far", 15, 90})
	b = healer("CharA", 80, m("A1"), m("A2"))
	p = makePlan([]*planChar{a, b}, nil, nil, now)
	if p.Cure["a1"] != "CharA" || p.Cure["a2"] != "CharA" || p.Cure["far"] != "CharC" {
		t.Errorf("low MP: the other healer takes over what it can reach, got %v", p.Cure)
	}
	// casting right now counts against a healer
	a = healer("CharC", 80, m("A1"))
	a.Casting = true
	b = healer("CharA", 80, m("A1"))
	p = makePlan([]*planChar{a, b}, nil, nil, now)
	if p.Cure["a1"] != "CharA" {
		t.Errorf("the healer busy casting gives way, got %v", p.Cure)
	}
	// a KO'd healer is not planned with; one healer alone = no cure plan (the addon decides)
	a = healer("CharC", 80, m("A1"))
	a.HPP = 0
	b = healer("CharA", 80, m("A1"))
	p = makePlan([]*planChar{a, b}, nil, nil, now)
	if len(p.Cure) != 0 {
		t.Errorf("one living healer: nothing to share out, got %v", p.Cure)
	}
	// steady: a member keeps his healer when the other one is only a little better
	a = healer("CharC", 80, planMember{"A1", 6, 90})
	b = healer("CharA", 80, planMember{"A1", 4, 90})
	prev := teamPlan{Cure: map[string]string{"a1": "CharC"}}
	p = makePlan([]*planChar{a, b}, nil, &prev, now)
	if p.Cure["a1"] != "CharC" {
		t.Errorf("no flip-flopping for 2 yalms, got %v", p.Cure)
	}
}

func enfChar(name string, n int, mobs ...planMob) *planChar {
	return &planChar{Name: name, HPP: 100, MPP: 100, Enf: true, EnfN: n, Mobs: mobs}
}

func TestPlanEnfeeblerNoTwoOnOneMob(t *testing.T) {
	now := time.Now()
	a := enfChar("CharC", 1, planMob{ID: 50, Dist: 5, BT: true}, planMob{ID: 51, Dist: 8, BT: false})
	b := enfChar("CharA", 1, planMob{ID: 50, Dist: 5, BT: true}, planMob{ID: 51, Dist: 4, BT: false})
	p := makePlan([]*planChar{a, b}, nil, nil, now)
	va, vb := p.Enf["CharC"], p.Enf["CharA"]
	if len(va) != 1 || len(vb) != 1 || va[0] == vb[0] {
		t.Fatalf("two enfeeblers, two mobs: one each, never the same, got %v", p.Enf)
	}
	// count is respected: count 2 takes two, the other one gets what's left
	a = enfChar("CharC", 2, planMob{ID: 50, Dist: 5, BT: true}, planMob{ID: 51, Dist: 6, BT: false}, planMob{ID: 52, Dist: 7, BT: false})
	b = enfChar("CharA", 1, planMob{ID: 50, Dist: 5, BT: true}, planMob{ID: 51, Dist: 6, BT: false}, planMob{ID: 52, Dist: 7, BT: false})
	p = makePlan([]*planChar{a, b}, nil, nil, now)
	seen := map[int]string{}
	for n, ids := range p.Enf {
		for _, id := range ids {
			if seen[id] != "" {
				t.Errorf("mob %d given to %s and %s", id, seen[id], n)
			}
			seen[id] = n
		}
	}
	if len(p.Enf["CharC"]) != 2 || len(p.Enf["CharA"]) != 1 {
		t.Errorf("CharC (count 2) gets two mobs, CharA (count 1) one, got %v", p.Enf)
	}
	// more enfeeblers than mobs: the one left over gets an empty list (sent as "-")
	a = enfChar("CharC", 1, planMob{ID: 50, Dist: 5, BT: true})
	b = enfChar("CharA", 1, planMob{ID: 50, Dist: 5, BT: true})
	p = makePlan([]*planChar{a, b}, nil, nil, now)
	if len(p.Enf["CharC"])+len(p.Enf["CharA"]) != 1 {
		t.Errorf("one mob: only one enfeebler takes it, got %v", p.Enf)
	}
	if txt := encodePlan(p); !strings.Contains(txt, ":-") {
		t.Errorf("the one with nothing is told so (\"-\"), got %q", txt)
	}
	// a single enfeebler: no plan (it decides by itself)
	p = makePlan([]*planChar{enfChar("CharC", 1, planMob{ID: 50, Dist: 5, BT: true})}, nil, nil, now)
	if len(p.Enf) != 0 {
		t.Errorf("one enfeebler: nothing planned, got %v", p.Enf)
	}
}

func TestPlanSkillchainOnePerTrigger(t *testing.T) {
	now := time.Now()
	pend := []scfPending{
		{Name: "CharC", Mob: 50, PID: 3, Due: now.Add(3 * time.Second), TP: 1200, Reach: true},
		{Name: "CharA", Mob: 50, PID: 7, Due: now.Add(3500 * time.Millisecond), TP: 2500, Reach: true},
		{Name: "CharB", Mob: 50, PID: 1, Due: now.Add(3 * time.Second), TP: 3000, Reach: false},
	}
	v := planScf(pend, now)
	keep := 0
	for _, x := range v {
		if x.Keep {
			keep++
			if x.Name != "CharA" {
				t.Errorf("in reach and the most TP closes it, got %s", x.Name)
			}
		}
	}
	if keep != 1 || len(v) != 3 {
		t.Errorf("three follow-ups for one trigger: one keeps it, got %+v", v)
	}
	// a follow-up due much later is the next step of a chain: it keeps its own
	pend = []scfPending{
		{Name: "CharC", Mob: 50, PID: 3, Due: now.Add(2 * time.Second), TP: 1200, Reach: true},
		{Name: "CharA", Mob: 50, PID: 7, Due: now.Add(6 * time.Second), TP: 1200, Reach: true},
		{Name: "CharB", Mob: 51, PID: 9, Due: now.Add(2 * time.Second), TP: 1200, Reach: true},
	}
	for _, x := range planScf(pend, now) {
		if !x.Keep {
			t.Errorf("different steps / different mobs: everyone keeps theirs, %s didn't", x.Name)
		}
	}
	// same TP and reach: the alphabetical first (like the addon's own tie-break)
	pend = []scfPending{
		{Name: "CharC", Mob: 50, PID: 3, Due: now.Add(2 * time.Second), TP: 1000, Reach: true},
		{Name: "CharA", Mob: 50, PID: 7, Due: now.Add(2 * time.Second), TP: 1000, Reach: true},
	}
	for _, x := range planScf(pend, now) {
		if x.Keep != (x.Name == "CharA") {
			t.Errorf("tie: alphabetical first keeps it, got %+v", x)
		}
	}
}

func TestEncodePlan(t *testing.T) {
	p := teamPlan{Cure: map[string]string{"charb": "CharC", "chara": "CharA"},
		Enf: map[string][]int{"CharC": {50, 51}, "CharA": {}},
		Scf: []scfVerdict{{"CharA", 50, 7, true}, {"CharC", 50, 3, false}}}
	want := "cure=chara:CharA,charb:CharC enf=CharA:-,CharC:50/51 scf=CharA:50:7:1,CharC:50:3:0"
	if got := encodePlan(p); got != want {
		t.Errorf("plan line\n got %q\nwant %q", got, want)
	}
	if encodePlan(teamPlan{}) != "" {
		t.Error("an empty plan is an empty line (a heartbeat: the planner is on)")
	}
}

func TestPlanCharFromSnapshot(t *testing.T) {
	var snap map[string]any
	json.Unmarshal([]byte(`{"name":"CharC","hpp":90,"mpp":40,"status":"Engaged","plan":{
		"heal":{"casting":true,"m":[{"n":"CharB","d":4.5,"hpp":70},{"n":"CharC","d":0,"hpp":90}]},
		"enf":{"n":2,"mobs":[{"id":50,"d":5,"bt":true},{"id":51,"d":9}]}}}`), &snap)
	c := planCharFrom("CharC", snap)
	if !c.Healer || !c.Casting || len(c.Members) != 2 || c.Members[0].Name != "CharB" || c.Members[0].Dist != 4.5 {
		t.Errorf("healer part read wrong: %+v", c)
	}
	if !c.Enf || c.EnfN != 2 || len(c.Mobs) != 2 || !c.Mobs[0].BT || c.Mobs[1].ID != 51 {
		t.Errorf("enfeebler part read wrong: %+v", c)
	}
	// Lua sends an empty list as {}; no plan part = nothing to plan with
	snap = nil
	json.Unmarshal([]byte(`{"name":"X","hpp":100,"plan":{"heal":{"m":{}}}}`), &snap)
	if c := planCharFrom("X", snap); !c.Healer || len(c.Members) != 0 {
		t.Errorf("empty member list: %+v", c)
	}
	snap = nil
	json.Unmarshal([]byte(`{"name":"Y","hpp":100,"status":"Dead"}`), &snap)
	if c := planCharFrom("Y", snap); c.Healer || c.Enf || c.HPP != 0 {
		t.Errorf("no plan part, KO'd: %+v", c)
	}
}

// The loop: off = nothing sent; on = a plan line to every online character, at most 4 a second, re-sent each second.
func TestPlannerSendsToCharacters(t *testing.T) {
	os.Remove(plannerPath())
	defer os.Remove(plannerPath())
	app, err := net.ListenUDP("udp", &net.UDPAddr{IP: net.IPv4(127, 0, 0, 1)})
	if err != nil {
		t.Skip("no UDP here")
	}
	defer app.Close()
	game, _ := net.ListenUDP("udp", &net.UDPAddr{IP: net.IPv4(127, 0, 0, 1)})
	defer game.Close()
	h := &hub{conn: app, chars: map[string]*character{}}
	now := time.Now()
	snap := func(name string, members ...string) map[string]any {
		var s map[string]any
		var m []string
		for _, n := range members {
			m = append(m, `{"n":"`+n+`","d":3,"hpp":80}`)
		}
		json.Unmarshal([]byte(`{"name":"`+name+`","hpp":100,"mpp":80,"plan":{"heal":{"m":[`+strings.Join(m, ",")+`]}}}`), &s)
		return s
	}
	gaddr := game.LocalAddr().(*net.UDPAddr)
	h.chars["CharC"] = &character{Snapshot: snap("CharC", "CharC", "CharB"), LastSeen: now, addr: gaddr}
	h.chars["CharA"] = &character{Snapshot: snap("CharA", "CharA", "CharB"), LastSeen: now, addr: gaddr}
	h.chars["Old"] = &character{Snapshot: snap("Old"), LastSeen: now.Add(-10 * time.Second), addr: gaddr}

	setPlanner(false)
	if h.planOnce(now) {
		t.Fatal("planner off (the default): nothing is sent")
	}
	setPlanner(true)
	if !h.planOnce(now) {
		t.Fatal("planner on: the first plan goes out")
	}
	buf := make([]byte, 2048)
	got := 0
	game.SetReadDeadline(time.Now().Add(time.Second))
	var line string
	for got < 2 {
		n, _, err := game.ReadFromUDP(buf)
		if err != nil {
			break
		}
		line = string(buf[:n])
		got++
	}
	if got != 2 || !strings.HasPrefix(line, "plan ") || !strings.Contains(line, "cure=") {
		t.Errorf("one plan line to each of the 2 online characters (not the stale one), got %d, last %q", got, line)
	}
	if h.planOnce(now.Add(100 * time.Millisecond)) {
		t.Error("nothing changed, under a second: not sent again")
	}
	if !h.planOnce(now.Add(1100 * time.Millisecond)) {
		t.Error("a second later the same plan is sent again (keeps it fresh in the addon)")
	}
	st := plannerStatus(now.Add(1500 * time.Millisecond))
	if st["on"] != true || st["chars"] != 2 || st["age"].(float64) != 0.4 {
		t.Errorf("status for the Team tab: %v", st)
	}
	// a queued skillchain follow-up from two characters gets one verdict each
	h.plannerScf("CharC", map[string]any{"mob": 50.0, "pid": 3.0, "d": 3.0, "tp": 1500.0, "r": true})
	h.plannerScf("CharA", map[string]any{"mob": 50.0, "pid": 4.0, "d": 3.0, "tp": 1000.0, "r": true})
	drain := func() {
		game.SetReadDeadline(time.Now().Add(50 * time.Millisecond))
		for {
			if _, _, err := game.ReadFromUDP(buf); err != nil {
				return
			}
		}
	}
	drain() // (the plan sent at 1.1 s)
	h.planOnce(now.Add(1200 * time.Millisecond))
	game.SetReadDeadline(time.Now().Add(time.Second))
	for i := 0; i < 2; i++ {
		n, _, err := game.ReadFromUDP(buf)
		if err != nil {
			break
		}
		line = string(buf[:n])
	}
	if !strings.Contains(line, "scf=CharA:50:4:0,CharC:50:3:1") {
		t.Errorf("the follow-ups are answered (CharC has more TP), got %q", line)
	}
	h.plannerScf("CharC", map[string]any{"d": -1.0})
	planner.mu.Lock()
	_, still := planner.pending["CharC"]
	planner.mu.Unlock()
	if still {
		t.Error("a used follow-up is forgotten")
	}
	// the switch is kept (planner.json) and the API answers
	setPlanner(false)
	loadPlanner()
	if plannerStatus(now)["on"] != false {
		t.Error("off is remembered")
	}
	rec := httptest.NewRecorder()
	h.handlePlanner(rec, httptest.NewRequest("GET", "/api/planner?on=1", nil))
	loadPlanner()
	if !strings.Contains(rec.Body.String(), `"on":true`) || plannerStatus(now)["on"] != true {
		t.Errorf("/api/planner?on=1 switches it on and keeps it: %s", rec.Body.String())
	}
	setPlanner(false)
}

// review 2026-11-27: pulls only fill the count, never while the party already fights that many mobs
func TestPlanEnfeeblerPullOnlyFillsCount(t *testing.T) {
	now := time.Now()
	mobs := func() []planMob {
		return []planMob{{ID: 50, Dist: 5, BT: true}, {ID: 51, Dist: 6}, {ID: 52, Dist: 7}, {ID: 90, Dist: 9, Pull: true}}
	}
	a := enfChar("CharC", 2, mobs()...)
	b := enfChar("CharA", 2, mobs()...)
	p := makePlan([]*planChar{a, b}, nil, nil, now)
	for n, ids := range p.Enf {
		for _, id := range ids {
			if id == 90 {
				t.Errorf("the party fights 3 mobs (count 2): nobody pulls the unclaimed one, but %s got it: %v", n, p.Enf)
			}
		}
	}
	if len(p.Enf["CharC"])+len(p.Enf["CharA"]) != 3 {
		t.Errorf("the 3 mobs fighting the party are shared out: %v", p.Enf)
	}
	// only one mob fighting, count 2 each: a pull may fill the count, after the fighting one is taken
	a = enfChar("CharC", 2, planMob{ID: 50, Dist: 5, BT: true}, planMob{ID: 90, Dist: 3, Pull: true})
	b = enfChar("CharA", 2, planMob{ID: 50, Dist: 5, BT: true}, planMob{ID: 90, Dist: 3, Pull: true})
	p = makePlan([]*planChar{a, b}, nil, nil, now)
	got := map[int]bool{}
	for _, ids := range p.Enf {
		for _, id := range ids {
			got[id] = true
		}
	}
	if !got[50] || !got[90] {
		t.Errorf("one mob fighting, count 2: the fighting one and the pull are both given out: %v", p.Enf)
	}
	var snap map[string]any
	json.Unmarshal([]byte(`{"name":"V","hpp":100,"enabled":true,"plan":{"enf":{"n":1,"mobs":[{"id":90,"d":5,"p":true}]}}}`), &snap)
	if c := planCharFrom("V", snap); len(c.Mobs) != 1 || !c.Mobs[0].Pull {
		t.Errorf("the snapshot's pull mark is read: %+v", c)
	}
}

// review 2026-11-27: a stopped or away character is given no members and no mobs
func TestPlanSkipsStoppedCharacters(t *testing.T) {
	now := time.Now()
	read := func(js string) *planChar {
		var s map[string]any
		json.Unmarshal([]byte(js), &s)
		return planCharFrom("X", s)
	}
	part := `"plan":{"heal":{"m":[{"n":"CharB","d":3,"hpp":50}]},"enf":{"n":1,"mobs":[{"id":50,"d":5}]}}`
	if c := read(`{"hpp":100,"enabled":false,` + part + `}`); c.Healer || c.Enf {
		t.Errorf("Vanguard stopped (enabled false): not a healer, not an enfeebler: %+v", c)
	}
	if c := read(`{"hpp":100,"enabled":true,"away":true,` + part + `}`); c.Healer || c.Enf {
		t.Errorf("away: not a healer, not an enfeebler: %+v", c)
	}
	if c := read(`{"hpp":100,"enabled":true,"away":false,` + part + `}`); !c.Healer || !c.Enf {
		t.Errorf("running: both parts read: %+v", c)
	}
	// one running healer plus one stopped one: no cure assignments (the running one decides by itself)
	run := read(`{"hpp":100,"mpp":80,"enabled":true,` + part + `}`)
	run.Name = "CharC"
	stop := read(`{"hpp":100,"mpp":80,"enabled":false,` + part + `}`)
	stop.Name = "CharA"
	if p := makePlan([]*planChar{run, stop}, nil, nil, now); len(p.Cure) != 0 {
		t.Errorf("one running healer + one stopped: nothing to share out, got %v", p.Cure)
	}
}

// review 2026-11-27: a late "gone" for an older follow-up never removes the newer one
func TestPlannerScfGoneOnlyThatOne(t *testing.T) {
	h := &hub{chars: map[string]*character{}}
	planner.mu.Lock()
	planner.pending = map[string]scfPending{}
	planner.mu.Unlock()
	h.plannerScf("CharC", map[string]any{"mob": 50.0, "pid": 7.0, "d": 3.0, "tp": 1500.0, "r": true})
	h.plannerScf("CharC", map[string]any{"mob": 50.0, "pid": 6.0, "d": -1.0})
	planner.mu.Lock()
	_, still := planner.pending["CharC"]
	planner.mu.Unlock()
	if !still {
		t.Error("gone for follow-up 6 must not remove follow-up 7")
	}
	h.plannerScf("CharC", map[string]any{"mob": 50.0, "pid": 7.0, "d": -1.0})
	planner.mu.Lock()
	_, still = planner.pending["CharC"]
	planner.mu.Unlock()
	if still {
		t.Error("gone for follow-up 7 removes it")
	}
}
