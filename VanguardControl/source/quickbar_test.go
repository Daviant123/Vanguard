package main

import (
	"encoding/json"
	"net/http/httptest"
	"os"
	"strings"
	"testing"
	"time"
)

func TestQuickButtons(t *testing.T) {
	h := testHub(t)
	defer os.Remove(quickPath())
	os.Remove(quickPath())
	_, got := fakeChar(t, h, "CharB", "WHM", nil)
	_, got2 := fakeChar(t, h, "CharC", "BRD", nil)
	call := func(q string) []quickButton {
		rec := httptest.NewRecorder()
		h.handleQuick(rec, httptest.NewRequest("GET", "/api/quick?"+q, nil))
		var list []quickButton
		json.Unmarshal(rec.Body.Bytes(), &list)
		return list
	}
	call("do=add&who=CharB&kind=ma&name=Curaga+III&target=me&label=Curaga")
	list := call("do=add&who=*&kind=ja&name=Provoke&target=bt")
	if len(list) != 2 || list[0].Label != "Curaga" || list[1].Label != "Provoke" {
		t.Fatalf("two buttons should be saved, got %+v", list)
	}
	if _, err := os.Stat(quickPath()); err != nil {
		t.Error("buttons are kept in quickbar.json next to the exe")
	}
	call("do=press&i=0")
	msgs := collect(got, 300*time.Millisecond)
	if len(msgs) == 0 || msgs[len(msgs)-1] != "cmd act ma me Curaga III" {
		t.Errorf("pressing sends the character a normal command, got %v", msgs)
	}
	if m := collect(got2, 100*time.Millisecond); len(m) != 0 {
		t.Error("a one-character button goes to that character only")
	}
	call("do=press&i=1")
	if a, b := collect(got, 300*time.Millisecond), collect(got2, 300*time.Millisecond); len(a) == 0 || len(b) == 0 ||
		!strings.HasSuffix(b[len(b)-1], "act ja bt Provoke") {
		t.Error("an Everyone button goes to every character")
	}
	list = call("do=left&i=1")
	if list[0].Label != "Provoke" {
		t.Error("buttons can be moved")
	}
	for _, bad := range []string{"do=add&who=CharB&kind=lua&name=x&target=me", "do=add&who=CharB&kind=ma&name=Cure;quit&target=me",
		"do=add&who=CharB;x&kind=ma&name=Cure&target=me", "do=add&who=CharB&kind=ma&name=&target=me"} {
		if len(call(bad)) != 2 {
			t.Errorf("a bad button is refused: %s", bad)
		}
	}
	// hotkeys: Ctrl+1 on the Curaga button, set in CharC's game window
	collect(got, 100*time.Millisecond)
	collect(got2, 100*time.Millisecond)
	list = call("do=key&i=1&key=^1&host=CharC")
	if list[1].Key != "^1" || list[1].Host != "CharC" {
		t.Fatalf("the hotkey should be saved on the button, got %+v", list[1])
	}
	if m := collect(got2, 300*time.Millisecond); len(m) == 0 || m[len(m)-1] != "cmd hotkey set ^1 CharB ma me Curaga III" {
		t.Errorf("the host character is told to bind it, got %v", m)
	}
	list = call("do=key&i=0&key=^1&host=CharC") // same key on another button: moves
	if list[0].Key != "^1" || list[1].Key != "" {
		t.Error("one button per key")
	}
	if m := strings.Join(collect(got2, 300*time.Millisecond), ","); !strings.Contains(m, "hotkey clear ^1") || !strings.Contains(m, "hotkey set ^1 * ja bt Provoke") {
		t.Errorf("moving a key clears the old binding and sets the new one, got %s", m)
	}
	for _, bad := range []string{"do=key&i=0&key=f12&host=CharC", "do=key&i=0&key=^1;quit&host=CharC", "do=key&i=0&key=^1&host=x;y"} {
		if call(bad)[0].Key != "^1" {
			t.Errorf("bad hotkey request changed something: %s", bad)
		}
	}
	collect(got2, 100*time.Millisecond)
	if list = call("do=delete&i=0"); len(collect(got2, 300*time.Millisecond)) == 0 {
		t.Error("deleting a button with a hotkey unbinds it")
	}
	list = call("do=left&i=0")
	if list = call("do=delete&i=0"); len(list) != 0 {
		t.Error("delete removes a button")
	}
}
