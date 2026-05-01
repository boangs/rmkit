package main

import (
	"encoding/json"
	"fmt"
	"net/http"
	"os"
	"strings"
	"sync"
	"unicode"

	"github.com/rmkit-cn/ime/pinyin"
)

const charQueueFile = "/tmp/rmkit_char_queue"

var charQueueMu sync.Mutex

var engine = pinyin.NewEngine()

// normalizeInput 模拟 Engine.Append 的过滤:只保留字母,转小写
func normalizeInput(s string) string {
	var b strings.Builder
	for _, ch := range s {
		if unicode.IsLetter(ch) {
			b.WriteRune(unicode.ToLower(ch))
		}
	}
	return b.String()
}

func candidatesHandler(w http.ResponseWriter, r *http.Request) {
	py := r.URL.Query().Get("pinyin")
	if py == "" {
		w.WriteHeader(http.StatusBadRequest)
		fmt.Fprintf(w, `{"error":"missing pinyin"}`)
		return
	}
	cands := engine.CandidatesFor(normalizeInput(py))

	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	json.NewEncoder(w).Encode(cands)
}

func selectHandler(w http.ResponseWriter, r *http.Request) {
	py := r.URL.Query().Get("pinyin")
	idxStr := r.URL.Query().Get("index")
	if py == "" || idxStr == "" {
		w.WriteHeader(http.StatusBadRequest)
		fmt.Fprintf(w, `{"error":"missing pinyin or index"}`)
		return
	}

	var idx int
	if _, err := fmt.Sscanf(idxStr, "%d", &idx); err != nil {
		w.WriteHeader(http.StatusBadRequest)
		fmt.Fprintf(w, `{"error":"invalid index"}`)
		return
	}

	cands := engine.CandidatesFor(normalizeInput(py))
	if idx >= len(cands) {
		w.WriteHeader(http.StatusNotFound)
		fmt.Fprintf(w, `{"error":"index out of range"}`)
		return
	}

	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	json.NewEncoder(w).Encode(map[string]string{"char": cands[idx]})
}

func healthHandler(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "application/json")
	fmt.Fprintf(w, `{"status":"ok"}`)
}

// popAllCharsHandler atomically reads and clears /tmp/rmkit_char_queue.
// Returns all committed characters as a plain string (newlines stripped).
func popAllCharsHandler(w http.ResponseWriter, r *http.Request) {
	charQueueMu.Lock()
	defer charQueueMu.Unlock()

	// Rename atomically so hook writes to a fresh file while we read the old one
	tmpFile := charQueueFile + ".reading"
	if err := os.Rename(charQueueFile, tmpFile); err != nil {
		w.Header().Set("Content-Type", "text/plain; charset=utf-8")
		w.Header().Set("Access-Control-Allow-Origin", "*")
		fmt.Fprintf(w, "")
		return
	}
	data, err := os.ReadFile(tmpFile)
	os.Remove(tmpFile)
	if err != nil {
		w.Header().Set("Content-Type", "text/plain; charset=utf-8")
		w.Header().Set("Access-Control-Allow-Origin", "*")
		fmt.Fprintf(w, "")
		return
	}
	result := strings.ReplaceAll(string(data), "\n", "")
	w.Header().Set("Content-Type", "text/plain; charset=utf-8")
	w.Header().Set("Access-Control-Allow-Origin", "*")
	fmt.Fprintf(w, "%s", result)
}

// setModeHandler creates or deletes mode flag files used by the LD_PRELOAD hook.
// GET /set-mode?chinese=1  → create /tmp/rmkit_chinese_mode
// GET /set-mode?chinese=0  → delete /tmp/rmkit_chinese_mode
// GET /set-mode?pinyin_active=1 → create /tmp/rmkit_pinyin_active
// GET /set-mode?pinyin_active=0 → delete /tmp/rmkit_pinyin_active
func setModeHandler(w http.ResponseWriter, r *http.Request) {
	q := r.URL.Query()
	if v := q.Get("chinese"); v != "" {
		if v == "1" {
			os.WriteFile("/tmp/rmkit_chinese_mode", []byte{}, 0644)
		} else {
			os.Remove("/tmp/rmkit_chinese_mode")
		}
	}
	if v := q.Get("pinyin_active"); v != "" {
		if v == "1" {
			os.WriteFile("/tmp/rmkit_pinyin_active", []byte{}, 0644)
		} else {
			os.Remove("/tmp/rmkit_pinyin_active")
		}
	}
	w.Header().Set("Content-Type", "application/json")
	w.Header().Set("Access-Control-Allow-Origin", "*")
	fmt.Fprintf(w, `{"ok":true}`)
}

func main() {
	port := os.Getenv("IME_PORT")
	if port == "" {
		port = "19876"
	}

	// Clean up stale mode files from previous runs
	os.Remove("/tmp/rmkit_chinese_mode")
	os.Remove("/tmp/rmkit_pinyin_active")
	os.Remove(charQueueFile)

	http.HandleFunc("/candidates", candidatesHandler)
	http.HandleFunc("/select", selectHandler)
	http.HandleFunc("/health", healthHandler)
	http.HandleFunc("/pop-all-chars", popAllCharsHandler)
	http.HandleFunc("/set-mode", setModeHandler)

	fmt.Printf("rmkit-cn-ime HTTP server listening on :%s\n", port)
	if err := http.ListenAndServe("127.0.0.1:"+port, nil); err != nil {
		fmt.Fprintf(os.Stderr, "Server error: %v\n", err)
		os.Exit(1)
	}
}
