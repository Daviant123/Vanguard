package main

import (
	"net/http"
	"net/http/httptest"
	"testing"
)

func TestNewer(t *testing.T) {
	cases := []struct {
		a, b string
		want bool
	}{{"1.1.0", "1.0.0", true}, {"1.10.0", "1.9.9", true}, {"1.1.0", "1.1.0", false}, {"1.0.9", "1.1.0", false}, {"2", "1.9.9", true}}
	for _, c := range cases {
		if newer(c.a, c.b) != c.want {
			t.Errorf("newer(%q, %q) should be %v", c.a, c.b, c.want)
		}
	}
}

func TestCheckUpdate(t *testing.T) {
	version := "9.9.9\n"
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/version.txt" {
			w.Write([]byte(version))
			return
		}
		http.NotFound(w, r)
	}))
	defer srv.Close()
	updateBase = srv.URL + "/"
	if v, err := checkUpdate(); err != nil || v != "9.9.9" {
		t.Errorf("a newer version on the page should be found, got %q %v", v, err)
	}
	version = panelVersion
	if v, _ := checkUpdate(); v != "" {
		t.Errorf("same version: no update, got %q", v)
	}
	updateBase = srv.URL + "/missing/"
	if v, err := checkUpdate(); err == nil || v != "" {
		t.Errorf("page not reachable: an error and no update, got %q %v", v, err)
	}
}
