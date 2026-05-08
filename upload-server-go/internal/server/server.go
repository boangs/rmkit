package server

import (
	"bufio"
	"bytes"
	"context"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log"
	"net/http"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"time"

	"github.com/rmkit-cn/upload-server/internal/librarian"
	"github.com/rmkit-cn/upload-server/internal/qr"
)

const (
	UploadPort       = 8080
	LibrarianTimeout = 60 * time.Second
	MaxUploadBytes   = 200 << 20 // 200 MiB
	XochitlDir       = "/home/root/.local/share/remarkable/xochitl"
	AIConfigPath     = "/home/root/.local/share/rmkit-cn/ai_config.json"
	AIChatTimeout    = 90 * time.Second
)

var (
	allowedFontExts   = map[string]struct{}{".ttf": {}, ".otf": {}}
	allowedScreenExts = map[string]struct{}{".png": {}}
	allowedDocExts    = map[string]struct{}{".pdf": {}, ".epub": {}}
)

// Config 是构造服务器需要的所有可配项.
type Config struct {
	StaticDir      string // 静态资源目录 (index.html, qr.html)
	FontsDir       string // 字体存放目录
	ScreensDir     string // 锁屏图存放目录
	DocStagingDir  string // /documents 上传暂存目录 (librarian 会从此处复制)
	FontsActiveDir string // 字体激活符号链接目录 (~/.local/share/fonts)
	XochitlConf    string // xochitl 配置路径 (~/.config/remarkable/xochitl.conf)
}

type Server struct {
	cfg Config
}

func New(cfg Config) (*Server, error) {
	for _, d := range []string{cfg.FontsDir, cfg.ScreensDir, cfg.DocStagingDir} {
		if err := os.MkdirAll(d, 0o755); err != nil {
			return nil, fmt.Errorf("mkdir %s: %w", d, err)
		}
	}
	return &Server{cfg: cfg}, nil
}

func (s *Server) Routes() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("GET /", s.index)
	mux.HandleFunc("GET /qr", s.qrPage)
	mux.HandleFunc("GET /qr-info", s.qrInfo)
	mux.HandleFunc("GET /qr.png", s.qrPNG)

	mux.HandleFunc("GET /fonts", s.listFonts)
	mux.HandleFunc("POST /fonts", s.uploadFont)
	mux.HandleFunc("DELETE /fonts/{name}", s.deleteFont)
	mux.HandleFunc("GET /fonts/active", s.activeFont)
	mux.HandleFunc("POST /fonts/{name}/apply", s.applyFont)

	mux.HandleFunc("GET /screens", s.listScreens)
	mux.HandleFunc("POST /screens", s.uploadScreen)
	mux.HandleFunc("DELETE /screens/{name}", s.deleteScreen)
	mux.HandleFunc("GET /screens/active", s.activeScreen)
	mux.HandleFunc("POST /screens/{name}/apply", s.applyScreen)
	mux.HandleFunc("GET /screens/{name}/preview", s.previewScreen)

	mux.HandleFunc("POST /documents", s.uploadDocument)

	mux.HandleFunc("GET /ai-config", s.getAIConfig)
	mux.HandleFunc("PUT /ai-config", s.putAIConfig)
	mux.HandleFunc("POST /ai-chat", s.aiChat)
	mux.HandleFunc("POST /ai-page-chat", s.aiPageChat)
	mux.HandleFunc("POST /ai-glyph-chat", s.aiGlyphChat)
	mux.HandleFunc("POST /ai-glyph-paste", s.aiGlyphPaste)
	mux.HandleFunc("POST /ai-glyph-handwrite", s.aiGlyphHandwrite)
	mux.HandleFunc("POST /ai-glyph-tap", s.aiGlyphTap)

	mux.HandleFunc("POST /apply", s.applyAll)

	mux.HandleFunc("POST /apps/koreader/launch", s.launchKoreader)

	mux.Handle("GET /static/", http.StripPrefix("/static/", http.FileServer(http.Dir(s.cfg.StaticDir))))

	return accessLog(mux)
}

func accessLog(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		start := time.Now()
		next.ServeHTTP(w, r)
		log.Printf("%s %s %s (%s)", r.RemoteAddr, r.Method, r.URL.Path, time.Since(start))
	})
}

// ---- 工具 ----

func writeJSON(w http.ResponseWriter, code int, v any) {
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.WriteHeader(code)
	json.NewEncoder(w).Encode(v)
}

func httpError(w http.ResponseWriter, code int, detail string) {
	writeJSON(w, code, map[string]string{"detail": detail})
}

// safeJoin 防 path traversal: 只取 name 的 base, 校验拼接后仍在 base 下.
func safeJoin(base, name string) (string, error) {
	clean := filepath.Base(name)
	if clean == "." || clean == "/" || clean == "" {
		return "", errors.New("非法文件名")
	}
	full := filepath.Join(base, clean)
	rel, err := filepath.Rel(base, full)
	if err != nil || strings.HasPrefix(rel, "..") {
		return "", errors.New("非法文件名")
	}
	return full, nil
}

func listFiles(dir string, allowed map[string]struct{}) []map[string]any {
	out := []map[string]any{}
	entries, err := os.ReadDir(dir)
	if err != nil {
		return out
	}
	type item struct {
		name string
		size int64
	}
	items := []item{}
	for _, e := range entries {
		if e.IsDir() {
			continue
		}
		ext := strings.ToLower(filepath.Ext(e.Name()))
		if _, ok := allowed[ext]; !ok {
			continue
		}
		info, err := e.Info()
		if err != nil {
			continue
		}
		items = append(items, item{e.Name(), info.Size()})
	}
	sort.Slice(items, func(i, j int) bool { return items[i].name < items[j].name })
	for _, it := range items {
		out = append(out, map[string]any{"name": it.name, "size": it.size})
	}
	return out
}

func saveUpload(w http.ResponseWriter, r *http.Request, dir string, allowed map[string]struct{}, allowedDesc string) (name string, size int64, ok bool) {
	r.Body = http.MaxBytesReader(w, r.Body, MaxUploadBytes)
	if err := r.ParseMultipartForm(32 << 20); err != nil {
		httpError(w, http.StatusBadRequest, "上传解析失败: "+err.Error())
		return "", 0, false
	}
	file, header, err := r.FormFile("file")
	if err != nil {
		httpError(w, http.StatusBadRequest, "缺少 file 字段")
		return "", 0, false
	}
	defer file.Close()

	if header.Filename == "" {
		httpError(w, http.StatusBadRequest, "文件名不能为空")
		return "", 0, false
	}
	safe := filepath.Base(header.Filename)
	ext := strings.ToLower(filepath.Ext(safe))
	if _, okExt := allowed[ext]; !okExt {
		httpError(w, http.StatusBadRequest, "仅支持 "+allowedDesc+" 文件")
		return "", 0, false
	}

	dest, err := safeJoin(dir, safe)
	if err != nil {
		httpError(w, http.StatusBadRequest, err.Error())
		return "", 0, false
	}
	out, err := os.Create(dest)
	if err != nil {
		httpError(w, http.StatusInternalServerError, "创建文件失败: "+err.Error())
		return "", 0, false
	}
	defer out.Close()
	n, err := io.Copy(out, file)
	if err != nil {
		os.Remove(dest)
		httpError(w, http.StatusInternalServerError, "写入文件失败: "+err.Error())
		return "", 0, false
	}
	return safe, n, true
}

// ---- 静态页面 ----

func (s *Server) index(w http.ResponseWriter, r *http.Request) {
	http.ServeFile(w, r, filepath.Join(s.cfg.StaticDir, "index.html"))
}

func (s *Server) qrPage(w http.ResponseWriter, r *http.Request) {
	http.ServeFile(w, r, filepath.Join(s.cfg.StaticDir, "qr.html"))
}

// ---- QR ----

// qrFocus: 仅允许 doc/font/screen/ai (qr.html 现有四 tab); 其他值忽略.
func qrFocus(r *http.Request) string {
	switch r.URL.Query().Get("focus") {
	case "doc", "font", "screen", "ai":
		return r.URL.Query().Get("focus")
	}
	return ""
}

func qrTargetURL(ip, focus string) string {
	url := fmt.Sprintf("http://%s:%d/qr", ip, UploadPort)
	if focus != "" {
		url += "?focus=" + focus
	}
	return url
}

func (s *Server) qrInfo(w http.ResponseWriter, r *http.Request) {
	ip, err := qr.DetectLanIP()
	if err != nil {
		writeJSON(w, http.StatusOK, map[string]any{
			"available": false,
			"reason":    err.Error(),
		})
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{
		"available": true,
		"ip":        ip,
		"port":      UploadPort,
		"url":       qrTargetURL(ip, qrFocus(r)),
	})
}

func (s *Server) qrPNG(w http.ResponseWriter, r *http.Request) {
	ip, err := qr.DetectLanIP()
	if err != nil {
		httpError(w, http.StatusServiceUnavailable, err.Error())
		return
	}
	png, err := qr.PNG(qrTargetURL(ip, qrFocus(r)))
	if err != nil {
		httpError(w, http.StatusInternalServerError, "生成 QR 失败: "+err.Error())
		return
	}
	w.Header().Set("Content-Type", "image/png")
	w.Write(png)
}

// ---- 字体 ----

func (s *Server) listFonts(w http.ResponseWriter, r *http.Request) {
	items := listFiles(s.cfg.FontsDir, allowedFontExts)
	active := s.detectActiveFont()
	for _, it := range items {
		it["active"] = it["name"] == active
	}
	writeJSON(w, http.StatusOK, items)
}

func (s *Server) uploadFont(w http.ResponseWriter, r *http.Request) {
	name, size, ok := saveUpload(w, r, s.cfg.FontsDir, allowedFontExts, ".ttf / .otf")
	if !ok {
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"name": name, "size": size})
}

func (s *Server) deleteFont(w http.ResponseWriter, r *http.Request) {
	name := r.PathValue("name")
	target, err := safeJoin(s.cfg.FontsDir, name)
	if err != nil {
		httpError(w, http.StatusBadRequest, err.Error())
		return
	}
	if err := os.Remove(target); err != nil {
		if os.IsNotExist(err) {
			httpError(w, http.StatusNotFound, "文件不存在")
			return
		}
		httpError(w, http.StatusInternalServerError, err.Error())
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"deleted": filepath.Base(name)})
}

// ---- 锁屏图 ----

func (s *Server) listScreens(w http.ResponseWriter, r *http.Request) {
	items := listFiles(s.cfg.ScreensDir, allowedScreenExts)
	active := s.detectActiveScreen()
	for _, it := range items {
		it["active"] = it["name"] == active
	}
	writeJSON(w, http.StatusOK, items)
}

func (s *Server) uploadScreen(w http.ResponseWriter, r *http.Request) {
	name, size, ok := saveUpload(w, r, s.cfg.ScreensDir, allowedScreenExts, ".png")
	if !ok {
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"name": name, "size": size})
}

func (s *Server) deleteScreen(w http.ResponseWriter, r *http.Request) {
	name := r.PathValue("name")
	target, err := safeJoin(s.cfg.ScreensDir, name)
	if err != nil {
		httpError(w, http.StatusBadRequest, err.Error())
		return
	}
	if err := os.Remove(target); err != nil {
		if os.IsNotExist(err) {
			httpError(w, http.StatusNotFound, "文件不存在")
			return
		}
		httpError(w, http.StatusInternalServerError, err.Error())
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"deleted": filepath.Base(name)})
}

// ---- 文档 (走 librarian pipe 热导入) ----

// invokeLibrarian 是一个变量, 测试时可替换.
var invokeLibrarian = librarian.Invoke

func randomToken() string {
	b := make([]byte, 8)
	rand.Read(b)
	return hex.EncodeToString(b)
}

// importDocAvoidingTrashDup 调 librarian importDocument; 若返回的 UUID 是
// 用户之前删进回收站的旧条目 (librarian 按 hash 复用 UUID), 永久 deleteEntry
// 该旧条目, 再 importDocument 一次, 拿到全新 UUID. 这样"删了就是删了, 重新上传 = 全新条目".
func importDocAvoidingTrashDup(stagingPath string) (string, error) {
	doImport := func() (string, error) {
		out, err := invokeLibrarian("importDocument", stagingPath, LibrarianTimeout)
		fmt.Fprintf(os.Stderr, "importDocument path=%s ret=%q err=%v\n", stagingPath, out, err)
		if err != nil {
			return "", err
		}
		out = strings.TrimSpace(out)
		if strings.HasPrefix(out, "ERROR:") {
			return "", fmt.Errorf("%s", out)
		}
		if out == "" {
			return "", fmt.Errorf("librarian 返回空")
		}
		return out, nil
	}

	uuid, err := doImport()
	if err != nil {
		return "", err
	}

	if !isUUIDInTrash(uuid) {
		return uuid, nil
	}

	// 旧条目在回收站里, 永久删除后再导入.
	if _, delErr := invokeLibrarian("deleteEntry", uuid, LibrarianTimeout); delErr != nil {
		fmt.Fprintf(os.Stderr, "deleteEntry %s (清理 trash dup) 失败: %v\n", uuid, delErr)
		// 即便永久删除失败也尽量再导入一次, 不阻断
	}
	return doImport()
}

// isUUIDInTrash 读 metadata, 看 parent 是不是 "trash". 任何错误都视为不在回收站.
func isUUIDInTrash(uuid string) bool {
	data, err := os.ReadFile(filepath.Join(XochitlDir, uuid+".metadata"))
	if err != nil {
		return false
	}
	var meta struct {
		Parent string `json:"parent"`
	}
	if err := json.Unmarshal(data, &meta); err != nil {
		return false
	}
	return meta.Parent == "trash"
}

func (s *Server) uploadDocument(w http.ResponseWriter, r *http.Request) {
	r.Body = http.MaxBytesReader(w, r.Body, MaxUploadBytes)
	if err := r.ParseMultipartForm(32 << 20); err != nil {
		httpError(w, http.StatusBadRequest, "上传解析失败: "+err.Error())
		return
	}
	file, header, err := r.FormFile("file")
	if err != nil {
		httpError(w, http.StatusBadRequest, "缺少 file 字段")
		return
	}
	defer file.Close()

	if header.Filename == "" {
		httpError(w, http.StatusBadRequest, "文件名不能为空")
		return
	}
	fmt.Fprintf(os.Stderr, "upload filename raw=%q hex=%x\n", header.Filename, []byte(header.Filename))
	safe := filepath.Base(header.Filename)
	ext := strings.ToLower(filepath.Ext(safe))
	if _, ok := allowedDocExts[ext]; !ok {
		httpError(w, http.StatusBadRequest, "仅支持 .pdf / .epub 文件")
		return
	}

	// staging 用纯随机名 + 扩展名, 不含原始文件名:
	// librarian 的 findArgSeparator 用 lastIndexOf(',') 切 path/parentId,
	// 文件名里有 ',' 会被误切. 用纯 token 名规避.
	stagingName := randomToken() + ext
	stagingPath := filepath.Join(s.cfg.DocStagingDir, stagingName)
	out, err := os.Create(stagingPath)
	if err != nil {
		httpError(w, http.StatusInternalServerError, "创建暂存文件失败: "+err.Error())
		return
	}
	size, err := io.Copy(out, file)
	out.Close()
	if err != nil {
		os.Remove(stagingPath)
		httpError(w, http.StatusInternalServerError, "写入暂存文件失败: "+err.Error())
		return
	}

	defer os.Remove(stagingPath) // librarian copy 完后清理

	uuid, err := importDocAvoidingTrashDup(stagingPath)
	if err != nil {
		if errors.Is(err, librarian.ErrPipeMissing) || errors.Is(err, librarian.ErrTimeout) {
			httpError(w, http.StatusServiceUnavailable, err.Error())
			return
		}
		httpError(w, http.StatusInternalServerError, err.Error())
		return
	}

	// 把 visibleName 改回原始文件名 (去掉扩展名).
	// renameEntry 走 <UUID>,<newName> 路径, UUID 36 字符 + ',' 命中 findArgSeparator
	// 的特殊分支, 即便 newName 含 ',' 也不会被误切.
	//
	// 给 broker 200ms 喘息: importDocument 在 broker 内涉及 xochitl model 注册 +
	// metadata 写盘, 立刻接 renameEntry 偶尔会失败 (broker 写"ok" 但 setVisibleName 未生效).
	visibleName := strings.TrimSuffix(safe, ext)
	if visibleName != "" {
		time.Sleep(200 * time.Millisecond)
		renameArg := uuid + "," + visibleName
		out, renameErr := invokeLibrarian("renameEntry", renameArg, LibrarianTimeout)
		out = strings.TrimSpace(out)
		fmt.Fprintf(os.Stderr, "renameEntry uuid=%s name=%q ret=%q err=%v\n", uuid, visibleName, out, renameErr)
		if renameErr == nil && strings.HasPrefix(out, "ERROR:") {
			fmt.Fprintf(os.Stderr, "renameEntry librarian 报错: %s\n", out)
		}
	}

	writeJSON(w, http.StatusOK, map[string]any{
		"name": safe,
		"size": size,
		"uuid": uuid,
	})
}

// ---- AI 配置 ----

type aiConfig struct {
	Kind  string `json:"kind"`
	URL   string `json:"url"`
	Key   string `json:"key"`
	Model string `json:"model"`
	// Thinking 控制 OpenAI 兼容协议下的 `enable_thinking` 字段 (Qwen3 等 hybrid thinking 模型).
	// nil = 用模型默认 (不发字段); true/false = 显式开/关. 其它后端 (Anthropic / 非 thinking 模型) 忽略.
	Thinking *bool `json:"enable_thinking,omitempty"`
}

func defaultAIConfig() aiConfig {
	return aiConfig{Kind: "openai", URL: "https://api.openai.com/v1", Model: "gpt-4o-mini"}
}

func (s *Server) getAIConfig(w http.ResponseWriter, r *http.Request) {
	cfg := defaultAIConfig()
	data, err := os.ReadFile(AIConfigPath)
	if err == nil {
		var disk aiConfig
		if json.Unmarshal(data, &disk) == nil {
			cfg = disk
		}
	}
	writeJSON(w, http.StatusOK, cfg)
}

// ---- AI 调用 ----

func (s *Server) aiChat(w http.ResponseWriter, r *http.Request) {
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

	text, err := callAI(cfg, in.Prompt)
	if err != nil {
		httpError(w, http.StatusBadGateway, err.Error())
		return
	}
	writeJSON(w, http.StatusOK, map[string]string{"text": text})
}

func callAI(cfg aiConfig, prompt string) (string, error) {
	base := strings.TrimRight(cfg.URL, "/")
	client := &http.Client{Timeout: AIChatTimeout}
	if cfg.Kind == "anthropic" {
		return callAnthropic(client, base, cfg.Key, cfg.Model, prompt)
	}
	return callOpenAI(client, base, cfg.Key, cfg.Model, prompt, cfg.Thinking)
}

func callOpenAI(client *http.Client, base, key, model, prompt string, thinking *bool) (string, error) {
	payload := map[string]any{
		"model":       model,
		"max_tokens":  8192,
		"temperature": 0.7,
		"messages":    []map[string]string{{"role": "user", "content": prompt}},
	}
	if thinking != nil {
		payload["enable_thinking"] = *thinking
	}
	body, _ := json.Marshal(payload)
	req, _ := http.NewRequest("POST", base+"/chat/completions", bytes.NewReader(body))
	req.Header.Set("Authorization", "Bearer "+key)
	req.Header.Set("Content-Type", "application/json")
	resp, err := client.Do(req)
	if err != nil {
		return "", fmt.Errorf("请求 AI 失败: %w", err)
	}
	defer resp.Body.Close()
	raw, _ := io.ReadAll(io.LimitReader(resp.Body, 4<<20))
	if resp.StatusCode >= 400 {
		return "", fmt.Errorf("AI HTTP %d: %s", resp.StatusCode, snippet(raw))
	}
	var r struct {
		Choices []struct {
			Message struct {
				Content string `json:"content"`
			} `json:"message"`
		} `json:"choices"`
	}
	if err := json.Unmarshal(raw, &r); err != nil || len(r.Choices) == 0 {
		return "", fmt.Errorf("AI 响应解析失败: %s", snippet(raw))
	}
	return strings.TrimSpace(r.Choices[0].Message.Content), nil
}

func callAnthropic(client *http.Client, base, key, model, prompt string) (string, error) {
	body, _ := json.Marshal(map[string]any{
		"model":      model,
		"max_tokens": 8192,
		"messages":   []map[string]string{{"role": "user", "content": prompt}},
	})
	req, _ := http.NewRequest("POST", base+"/messages", bytes.NewReader(body))
	req.Header.Set("x-api-key", key)
	req.Header.Set("anthropic-version", "2023-06-01")
	req.Header.Set("Content-Type", "application/json")
	resp, err := client.Do(req)
	if err != nil {
		return "", fmt.Errorf("请求 AI 失败: %w", err)
	}
	defer resp.Body.Close()
	raw, _ := io.ReadAll(io.LimitReader(resp.Body, 4<<20))
	if resp.StatusCode >= 400 {
		return "", fmt.Errorf("AI HTTP %d: %s", resp.StatusCode, snippet(raw))
	}
	var r struct {
		Content []struct {
			Type string `json:"type"`
			Text string `json:"text"`
		} `json:"content"`
	}
	if err := json.Unmarshal(raw, &r); err != nil {
		return "", fmt.Errorf("AI 响应解析失败: %s", snippet(raw))
	}
	var sb strings.Builder
	for _, c := range r.Content {
		if c.Type == "text" {
			sb.WriteString(c.Text)
		}
	}
	out := strings.TrimSpace(sb.String())
	if out == "" {
		return "", fmt.Errorf("AI 响应为空: %s", snippet(raw))
	}
	return out, nil
}

// callAIStream 流式调用 AI, 每个文本 delta 通过 onChunk 回调.
// ctx 取消时立即终止. 失败返回 error, 成功且未取消时返回 nil.
func callAIStream(ctx context.Context, cfg aiConfig, prompt string, onChunk func(string)) error {
	base := strings.TrimRight(cfg.URL, "/")
	client := &http.Client{} // 不设 Timeout: 流式期间连接一直保持
	if cfg.Kind == "anthropic" {
		return callAnthropicStream(ctx, client, base, cfg.Key, cfg.Model, prompt, onChunk)
	}
	return callOpenAIStream(ctx, client, base, cfg.Key, cfg.Model, prompt, cfg.Thinking, onChunk)
}

func callOpenAIStream(ctx context.Context, client *http.Client, base, key, model, prompt string, thinking *bool, onChunk func(string)) error {
	payload := map[string]any{
		"model":       model,
		"max_tokens":  8192,
		"temperature": 0.7,
		"stream":      true,
		"messages":    []map[string]string{{"role": "user", "content": prompt}},
	}
	if thinking != nil {
		payload["enable_thinking"] = *thinking
	}
	body, _ := json.Marshal(payload)
	req, _ := http.NewRequestWithContext(ctx, "POST", base+"/chat/completions", bytes.NewReader(body))
	req.Header.Set("Authorization", "Bearer "+key)
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("Accept", "text/event-stream")
	resp, err := client.Do(req)
	if err != nil {
		return fmt.Errorf("请求 AI 失败: %w", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode >= 400 {
		raw, _ := io.ReadAll(io.LimitReader(resp.Body, 4<<20))
		return fmt.Errorf("AI HTTP %d: %s", resp.StatusCode, snippet(raw))
	}
	scanner := bufio.NewScanner(resp.Body)
	scanner.Buffer(make([]byte, 0, 64<<10), 1<<20)
	for scanner.Scan() {
		line := scanner.Text()
		if !strings.HasPrefix(line, "data:") {
			continue
		}
		data := strings.TrimSpace(strings.TrimPrefix(line, "data:"))
		if data == "" || data == "[DONE]" {
			if data == "[DONE]" {
				return nil
			}
			continue
		}
		var ev struct {
			Choices []struct {
				Delta struct {
					Content string `json:"content"`
				} `json:"delta"`
			} `json:"choices"`
		}
		if json.Unmarshal([]byte(data), &ev) != nil {
			continue
		}
		for _, c := range ev.Choices {
			if c.Delta.Content != "" {
				onChunk(c.Delta.Content)
			}
		}
	}
	return scanner.Err()
}

func callAnthropicStream(ctx context.Context, client *http.Client, base, key, model, prompt string, onChunk func(string)) error {
	body, _ := json.Marshal(map[string]any{
		"model":      model,
		"max_tokens": 8192,
		"stream":     true,
		"messages":   []map[string]string{{"role": "user", "content": prompt}},
	})
	req, _ := http.NewRequestWithContext(ctx, "POST", base+"/messages", bytes.NewReader(body))
	req.Header.Set("x-api-key", key)
	req.Header.Set("anthropic-version", "2023-06-01")
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("Accept", "text/event-stream")
	resp, err := client.Do(req)
	if err != nil {
		return fmt.Errorf("请求 AI 失败: %w", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode >= 400 {
		raw, _ := io.ReadAll(io.LimitReader(resp.Body, 4<<20))
		return fmt.Errorf("AI HTTP %d: %s", resp.StatusCode, snippet(raw))
	}
	scanner := bufio.NewScanner(resp.Body)
	scanner.Buffer(make([]byte, 0, 64<<10), 1<<20)
	for scanner.Scan() {
		line := scanner.Text()
		if !strings.HasPrefix(line, "data:") {
			continue
		}
		data := strings.TrimSpace(strings.TrimPrefix(line, "data:"))
		if data == "" {
			continue
		}
		var ev struct {
			Type  string `json:"type"`
			Delta struct {
				Type string `json:"type"`
				Text string `json:"text"`
			} `json:"delta"`
		}
		if json.Unmarshal([]byte(data), &ev) != nil {
			continue
		}
		if ev.Type == "content_block_delta" && ev.Delta.Type == "text_delta" && ev.Delta.Text != "" {
			onChunk(ev.Delta.Text)
		}
	}
	return scanner.Err()
}

func snippet(b []byte) string {
	s := strings.TrimSpace(string(b))
	if len(s) > 200 {
		s = s[:200] + "…"
	}
	return s
}

func (s *Server) putAIConfig(w http.ResponseWriter, r *http.Request) {
	var in aiConfig
	if err := json.NewDecoder(io.LimitReader(r.Body, 64<<10)).Decode(&in); err != nil {
		httpError(w, http.StatusBadRequest, "JSON 解析失败: "+err.Error())
		return
	}
	in.Kind = strings.TrimSpace(in.Kind)
	in.URL = strings.TrimSpace(in.URL)
	in.Model = strings.TrimSpace(in.Model)
	if in.Kind != "openai" && in.Kind != "anthropic" {
		httpError(w, http.StatusBadRequest, "kind 必须是 openai 或 anthropic")
		return
	}
	if in.URL == "" {
		httpError(w, http.StatusBadRequest, "url 不能为空")
		return
	}
	// Key 为空时, 保留磁盘上原有 key (避免回填表单时把 key 清空)
	if in.Key == "" {
		if data, err := os.ReadFile(AIConfigPath); err == nil {
			var disk aiConfig
			if json.Unmarshal(data, &disk) == nil {
				in.Key = disk.Key
			}
		}
	}
	if err := os.MkdirAll(filepath.Dir(AIConfigPath), 0o755); err != nil {
		httpError(w, http.StatusInternalServerError, "创建目录失败: "+err.Error())
		return
	}
	body, _ := json.MarshalIndent(in, "", "  ")
	tmp := AIConfigPath + ".tmp"
	if err := os.WriteFile(tmp, body, 0o600); err != nil {
		httpError(w, http.StatusInternalServerError, "写入失败: "+err.Error())
		return
	}
	if err := os.Rename(tmp, AIConfigPath); err != nil {
		os.Remove(tmp)
		httpError(w, http.StatusInternalServerError, "保存失败: "+err.Error())
		return
	}
	writeJSON(w, http.StatusOK, in)
}
