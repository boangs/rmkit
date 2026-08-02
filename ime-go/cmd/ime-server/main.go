package main

import (
	"encoding/json"
	"fmt"
	"log"
	"net"
	"net/http"
	"os"
	"strings"
	"sync"
	"time"
	"unicode"

	"github.com/rmkit-cn/ime/pinyin"
)

const (
	charQueueFile   = "/tmp/rmkit_char_queue"
	hookNotifySock  = "/tmp/rmkit_hook_notify.sock"
	blockingTimeout = 5 * time.Second
)

var (
	charQueueMu sync.Mutex
	// hookNotify: ime_hook 写入字符后通过 unix datagram 通知, listener goroutine 把信号转入此 channel.
	// blocking handler select 此 channel 实现 0-polling 字符上屏。
	hookNotify = make(chan struct{}, 256)
)

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
// tryReadCharQueue atomically renames charQueueFile to a temp file and reads it.
// Returns "" on any error / empty queue. Concurrency-safe via charQueueMu.
func tryReadCharQueue() string {
	charQueueMu.Lock()
	defer charQueueMu.Unlock()

	tmpFile := charQueueFile + ".reading"
	if err := os.Rename(charQueueFile, tmpFile); err != nil {
		return ""
	}
	data, err := os.ReadFile(tmpFile)
	os.Remove(tmpFile)
	if err != nil {
		return ""
	}
	return strings.ReplaceAll(string(data), "\n", "")
}

func writeTextPlain(w http.ResponseWriter, body string) {
	w.Header().Set("Content-Type", "text/plain; charset=utf-8")
	w.Header().Set("Access-Control-Allow-Origin", "*")
	fmt.Fprintf(w, "%s", body)
}

// popAllCharsHandler — non-blocking version, preserved for backward compat / fallback polling.
func popAllCharsHandler(w http.ResponseWriter, r *http.Request) {
	writeTextPlain(w, tryReadCharQueue())
}

// rimeInputHandler — long-poll + 引擎处理合一 (GET /rime/input)。
//
// 取到字符后**在本进程内**直接喂给引擎 (librime 是 cgo 函数调用, 零往返),
// 把 preedit + 候选 + 上屏文本一次性返回。QML 因此每次输入只需这一个请求,
// 不再"先取字符、再查候选"两次往返 —— 后者的回调要排 xochitl 主线程队列,
// 正是之前"打字有时候慢、空格上屏卡一下"的根因。
func rimeInputHandler(w http.ResponseWriter, r *http.Request) {
	touchPoll() // 心跳: 证明 QML 侧还在工作, 看门狗据此判断是否该清模式标志
	chars := tryReadCharQueue()
	if chars == "" {
		// 无字符: 阻塞等 hook 通知 (0-polling), 超时返回空状态
		for drained := false; !drained; {
			select {
			case <-hookNotify:
			default:
				drained = true
			}
		}
		select {
		case <-hookNotify:
		case <-time.After(blockingTimeout):
		case <-r.Context().Done():
			return
		}
		chars = tryReadCharQueue()
	}
	if chars == "" {
		// 超时空转: 返回**当前真实状态**, 不能伪造空状态 —— 空 preedit 会让
		// writeState 删掉 pinyin_active (hook 随即不再吞空格, 提交信号丢失,
		// preedit 无限累积), 也会让 QML 的候选框在停顿 5 秒后凭空消失。
		writeState(w, ime.Snapshot())
		return
	}
	writeState(w, ime.Feed(chars))
}

// popAllCharsBlockingHandler — long-poll: returns immediately if queue has data,
// otherwise blocks on hookNotify channel (signaled by ime_hook via unix socket)
// or 5s timeout, then returns whatever is in queue.
// 保留: 旧版 QML (自己攒拼音串那套) 仍用它, 便于灰度回滚。
func popAllCharsBlockingHandler(w http.ResponseWriter, r *http.Request) {
	if data := tryReadCharQueue(); data != "" {
		writeTextPlain(w, data)
		return
	}
	// drain stale signals so we react to fresh keystrokes only
	for drained := false; !drained; {
		select {
		case <-hookNotify:
		default:
			drained = true
		}
	}
	select {
	case <-hookNotify:
	case <-time.After(blockingTimeout):
	case <-r.Context().Done():
		return
	}
	writeTextPlain(w, tryReadCharQueue())
}

// startHookNotifyListener listens on a unix datagram socket. ime_hook sends
// any byte after enqueue_char, which we translate into a non-blocking signal
// on hookNotify. The actual character payload still flows through char_queue
// file (kept for atomicity + simplicity); socket carries only "wake up" signal.
func startHookNotifyListener() {
	os.Remove(hookNotifySock)
	addr, err := net.ResolveUnixAddr("unixgram", hookNotifySock)
	if err != nil {
		log.Printf("[hook-notify] resolve failed: %v", err)
		return
	}
	conn, err := net.ListenUnixgram("unixgram", addr)
	if err != nil {
		log.Printf("[hook-notify] listen failed: %v", err)
		return
	}
	if err := os.Chmod(hookNotifySock, 0666); err != nil {
		log.Printf("[hook-notify] chmod failed: %v", err)
	}
	log.Printf("[hook-notify] listening on %s", hookNotifySock)
	buf := make([]byte, 64)
	for {
		n, _, err := conn.ReadFromUnix(buf)
		if err != nil {
			continue
		}
		if n > 0 {
			select {
			case hookNotify <- struct{}{}:
			default:
				// channel full, signal already pending — fine
			}
		}
	}
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

	// Start hook notification listener (unix socket) — enables 0-polling long-poll path.
	go startHookNotifyListener()

	// 输入引擎 (librime 或回退的自研引擎, 由 build tag 决定)
	initBackend()
	startModeWatchdog()

	// 新接口: long-poll + 引擎处理合一, QML 每次输入只需这一个请求
	http.HandleFunc("/rime/input", rimeInputHandler)
	http.HandleFunc("/rime/select", selectCandidateHandler)
	http.HandleFunc("/rime/page", changePageHandler)
	http.HandleFunc("/rime/clear", clearHandler)
	http.HandleFunc("/rime/key", keyHandler)

	// 旧接口: 保留供灰度回滚 / 外部调试
	http.HandleFunc("/candidates", candidatesHandler)
	http.HandleFunc("/select", selectHandler)
	http.HandleFunc("/health", healthHandler)
	http.HandleFunc("/pop-all-chars", popAllCharsHandler)
	http.HandleFunc("/pop-all-chars-blocking", popAllCharsBlockingHandler)
	http.HandleFunc("/set-mode", setModeHandler)

	fmt.Printf("rmkit-cn-ime HTTP server listening on :%s\n", port)
	if err := http.ListenAndServe("127.0.0.1:"+port, nil); err != nil {
		fmt.Fprintf(os.Stderr, "Server error: %v\n", err)
		os.Exit(1)
	}
}
