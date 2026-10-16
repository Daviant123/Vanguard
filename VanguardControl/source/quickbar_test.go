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
	if list = call("do=delete&i=0"); len(list) != 1 || list[0].Label != "Curaga" {
		t.Error("delete removes a button")
	}
}
