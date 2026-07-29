package main

import (
	"encoding/json"
	"net/http"
	"os"
)

// inputState 是一次按键处理后的完整输入状态, 直接序列化给 QML。
// 一次 long-poll 返回它 = 字符流和候选一起到达, 省掉 QML 侧单独的候选查询往返
// (那次往返的回调排在 xochitl 主线程队列里, 正是"打字有时候慢"的来源)。
type inputState struct {
	Preedit     string   `json:"preedit"`               // 编辑区文本 (整句输入时是完整待选串)
	Commit      string   `json:"commit"`                // 本批按键产生的上屏文本, 空则无
	Candidates  []string `json:"candidates"`            // 当前页候选
	Highlighted int      `json:"highlighted,omitempty"` // 高亮候选下标 (页内)
	PageNo      int      `json:"pageNo,omitempty"`
	IsLastPage  bool     `json:"isLastPage,omitempty"`
}

// backend 抽象输入引擎。librime 版有整句 + userdb; 回退版是词级自研引擎。
// 两者行为差异对 HTTP 层与 QML 层透明。
type backend interface {
	Feed(chars string) inputState  // 喂一批按键字符, 返回处理后状态
	SelectCandidate(idx int) inputState
	ChangePage(backward bool) inputState
	Clear()
}

var ime backend

// initBackend 初始化输入引擎。RIME_SHARED_DIR/RIME_USER_DIR 指向随包下发的
// 预编译词库和可写的 userdb 目录 (设备上分别在 rmkit-cn/rime 与 ~/.rmkit-rime)。
func initBackend() {
	ime = newBackend(
		envOr("RIME_SHARED_DIR", "/home/root/rmkit-cn/rime"),
		envOr("RIME_USER_DIR", "/home/root/.rmkit-rime"),
	)
}

func envOr(k, def string) string {
	if v := os.Getenv(k); v != "" {
		return v
	}
	return def
}

func writeState(w http.ResponseWriter, st inputState) {
	if st.Candidates == nil {
		st.Candidates = []string{} // 让 QML 侧永远拿到数组而非 null
	}
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.Header().Set("Access-Control-Allow-Origin", "*")
	json.NewEncoder(w).Encode(st)
}

// selectCandidateHandler — 点击候选框选词。GET /rime/select?index=N
func selectCandidateHandler(w http.ResponseWriter, r *http.Request) {
	idx := 0
	if v := r.URL.Query().Get("index"); v != "" {
		json.Unmarshal([]byte(v), &idx)
	}
	writeState(w, ime.SelectCandidate(idx))
}

// changePageHandler — 翻页。GET /rime/page?backward=1
func changePageHandler(w http.ResponseWriter, r *http.Request) {
	writeState(w, ime.ChangePage(r.URL.Query().Get("backward") == "1"))
}

// clearHandler — 放弃当前输入 (焦点切换/退出中文模式)。GET /rime/clear
func clearHandler(w http.ResponseWriter, r *http.Request) {
	ime.Clear()
	writeState(w, inputState{})
}

// keyHandler — 直接送一个按键 (GET /rime/key?code=13)。
// 给那些拦不到、进不了字符队列的按键用: PPM 虚拟键盘的 Enter 既不走
// setCommitString 也不走 processKeyEvent, QML 侧靠全局 Shortcut 捕获后
// 转发到这里, 由 librime 决定上屏内容 (整句成型 / 上原拼音)。
func keyHandler(w http.ResponseWriter, r *http.Request) {
	code := 0
	if v := r.URL.Query().Get("code"); v != "" {
		json.Unmarshal([]byte(v), &code)
	}
	if code <= 0 {
		writeState(w, inputState{})
		return
	}
	writeState(w, ime.Feed(string(rune(code))))
}
