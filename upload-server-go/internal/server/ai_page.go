package server

import (
	"encoding/json"
	"io"
	"net/http"
	"os"
	"strings"
)

// /ai-page-chat
//
// 输入: {"prompt": "...完整 prompt, 客户端已经拼好 (含选中文字等上下文)..."}
// 行为: 纯转发, 直接把 prompt 流式调 AI; 不再扫 .rm 文件 / 不再依赖 rmscene.
//       (改造前: 客户端只发 prompt_prefix, 服务器扫 .rm 拼整页 text — 但 .rm 不实时刷新,
//        用户必须等几秒才能点 AI; 改成客户端从 Clipboard 拿选中文字自己拼 prompt 后即时.)
// 输出: NDJSON 流, 每行一个 JSON 对象:
//       {"text":"答"}  {"text":"案"}  ...   ← 每个 token delta
//       {"done":true}                          ← 末尾结束
//       出错时: {"error":"..."} (可能在任何位置)
// 客户端用 XHR readyState=LOADING 阶段读 responseText, 按 \n 切行解析.

func (s *Server) aiPageChat(w http.ResponseWriter, r *http.Request) {
	var in struct {
		Prompt string `json:"prompt"`
	}
	if err := json.NewDecoder(io.LimitReader(r.Body, 256<<10)).Decode(&in); err != nil {
		httpError(w, http.StatusBadRequest, "JSON 解析失败: "+err.Error())
		return
	}
	in.Prompt = strings.TrimSpace(in.Prompt)
	if in.Prompt == "" {
		httpError(w, http.StatusBadRequest, "prompt 不能为空")
		return
	}

	cfg := defaultAIConfig()
	if data, err := os.ReadFile(AIConfigPath); err == nil {
		var disk aiConfig
		if json.Unmarshal(data, &disk) == nil {
			cfg = disk
		}
	}
	if cfg.Key == "" {
		httpError(w, http.StatusBadRequest, "未配置 API Key, 请先在「高级 → AI 设置」填写")
		return
	}

	flusher, ok := w.(http.Flusher)
	if !ok {
		httpError(w, http.StatusInternalServerError, "ResponseWriter 不支持 streaming")
		return
	}
	w.Header().Set("Content-Type", "application/x-ndjson; charset=utf-8")
	w.Header().Set("Cache-Control", "no-cache")
	w.Header().Set("X-Accel-Buffering", "no")
	w.WriteHeader(http.StatusOK)

	enc := json.NewEncoder(w)
	writeLine := func(v any) {
		_ = enc.Encode(v)
		flusher.Flush()
	}

	err := callAIStream(r.Context(), cfg, in.Prompt, func(chunk string) {
		writeLine(map[string]string{"text": chunk})
	})
	if err != nil {
		writeLine(map[string]string{"error": err.Error()})
		return
	}
	writeLine(map[string]bool{"done": true})
}
