package space

import (
	"archive/zip"
	"bytes"
	"encoding/json"
	"io"
	"log"
	"net/http"
	"os"
	"path/filepath"
	"regexp"
	"strconv"
	"sync"
	"time"
)

// Handler 把注册表 + 进程托管暴露为 HTTP 接口, 全部挂在 /space/ 下:
//
//	GET    /space/apps                      应用列表 (外壳首页 / 手机管理页共用)
//	POST   /space/apps                      上传 zip 安装 (multipart 字段 file, 或 body 直接是 zip)
//	POST   /space/apps/install-url          {"url": ..., "sha256": ...} 从网址安装 (应用商店用)
//	DELETE /space/apps/{id}                 卸载 (仅用户目录)
//	GET    /space/apps/{id}/service         后台状态
//	POST   /space/apps/{id}/service/start   拉起后台 (就绪后返回)
//	POST   /space/apps/{id}/service/stop    收掉后台
//	GET    /space/apps/{id}/data/{key}      读应用数据 (JSON, 存在 dataDir/<key>.json; 纯 QML 应用的持久化)
//	PUT    /space/apps/{id}/data/{key}      写应用数据 (body 是 JSON, ≤1MB)
type Handler struct {
	Reg *Registry
	Sup *Supervisor
	// 应用商店索引地址 (JSON, 见 space/README.md "应用商店"); 空 = 不提供商店
	StoreURL string

	storeMu   sync.Mutex
	storeAt   time.Time
	storeBody []byte
}

// 商店索引缓存时长: 设备 Wi-Fi 常年休眠、DNS 不稳, 拉一次能用就多用一会儿
const storeCacheTTL = 10 * time.Minute

// New 组装默认的注册表 + 托管器。
func New(builtinDir, userDir, dataDir, arch, baseURL string) *Handler {
	for _, d := range []string{userDir, dataDir} {
		_ = os.MkdirAll(d, 0o755)
	}
	return &Handler{
		Reg: &Registry{BuiltinDir: builtinDir, UserDir: userDir, DataDir: dataDir, Arch: arch},
		Sup: NewSupervisor(baseURL),
	}
}

// Mount 注册路由。
func (h *Handler) Mount(mux *http.ServeMux) {
	mux.HandleFunc("GET /space/apps", h.list)
	mux.HandleFunc("POST /space/apps", h.installUpload)
	mux.HandleFunc("POST /space/apps/install-url", h.installURL)
	mux.HandleFunc("DELETE /space/apps/{id}", h.uninstall)
	mux.HandleFunc("GET /space/apps/{id}/service", h.serviceStatus)
	mux.HandleFunc("POST /space/apps/{id}/service/start", h.serviceStart)
	mux.HandleFunc("POST /space/apps/{id}/service/stop", h.serviceStop)
	mux.HandleFunc("GET /space/apps/{id}/data/{key}", h.dataGet)
	mux.HandleFunc("PUT /space/apps/{id}/data/{key}", h.dataPut)
	mux.HandleFunc("GET /space/store", h.store)
}

var dataKeyRe = regexp.MustCompile(`^[A-Za-z0-9][A-Za-z0-9_.-]{0,63}$`)

// dataPath 把 (应用 id, key) 映射到 dataDir/<id>/<key>.json; id/key 都严格限制字符, 不会出目录。
func (h *Handler) dataPath(id, key string) (string, bool) {
	if !idRe.MatchString(id) || !dataKeyRe.MatchString(key) {
		return "", false
	}
	return filepath.Join(h.Reg.DataDir, id, key+".json"), true
}

func (h *Handler) dataGet(w http.ResponseWriter, r *http.Request) {
	p, ok := h.dataPath(r.PathValue("id"), r.PathValue("key"))
	if !ok {
		fail(w, http.StatusBadRequest, "id 或 key 不合法")
		return
	}
	b, err := os.ReadFile(p)
	if err != nil {
		fail(w, http.StatusNotFound, "没有这份数据")
		return
	}
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	_, _ = w.Write(b)
}

func (h *Handler) dataPut(w http.ResponseWriter, r *http.Request) {
	p, ok := h.dataPath(r.PathValue("id"), r.PathValue("key"))
	if !ok {
		fail(w, http.StatusBadRequest, "id 或 key 不合法")
		return
	}
	b, err := io.ReadAll(io.LimitReader(r.Body, 1<<20+1))
	if err != nil || len(b) > 1<<20 || !json.Valid(b) {
		fail(w, http.StatusBadRequest, "body 必须是 ≤1MB 的合法 JSON")
		return
	}
	if err := os.MkdirAll(filepath.Dir(p), 0o755); err != nil {
		fail(w, http.StatusInternalServerError, err.Error())
		return
	}
	if err := os.WriteFile(p, b, 0o644); err != nil {
		fail(w, http.StatusInternalServerError, err.Error())
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"ok": true})
}

// store 转发应用商店索引 (带缓存)。索引格式:
//
//	{"apps": [{"id","name","version","description","category","arch":[...],"zip":"https://...","sha256":"..."}]}
//
// 由设备端拉取而不是让面板直连: 面板里的 XHR 拿不到设备的 DNS 兜底与超时控制。
func (h *Handler) store(w http.ResponseWriter, r *http.Request) {
	if h.StoreURL == "" {
		fail(w, http.StatusNotFound, "没有配置应用商店")
		return
	}
	h.storeMu.Lock()
	defer h.storeMu.Unlock()
	if h.storeBody == nil || time.Since(h.storeAt) > storeCacheTTL || r.URL.Query().Get("refresh") == "1" {
		client := &http.Client{Timeout: 15 * time.Second}
		resp, err := client.Get(h.StoreURL)
		if err != nil {
			fail(w, http.StatusBadGateway, "连不上应用商店: "+err.Error())
			return
		}
		body, err := io.ReadAll(io.LimitReader(resp.Body, 4<<20))
		resp.Body.Close()
		if err != nil || resp.StatusCode != http.StatusOK || !json.Valid(body) {
			fail(w, http.StatusBadGateway, "应用商店索引无效 (HTTP "+strconv.Itoa(resp.StatusCode)+")")
			return
		}
		h.storeBody, h.storeAt = body, time.Now()
	}
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	_, _ = w.Write(h.storeBody)
}

// AutoStart 拉起所有声明了 autostart 的应用后台 (upload-server 启动时调一次)。
func (h *Handler) AutoStart() {
	for _, a := range h.Reg.List() {
		if a.Service != nil && a.Service.AutoStart && a.Error == "" {
			if _, err := h.Sup.Start(a); err != nil {
				log.Printf("space: %s 后台自启失败: %v", a.ID, err)
			}
		}
	}
}

func (h *Handler) list(w http.ResponseWriter, r *http.Request) {
	apps := h.Reg.List()
	for i := range apps {
		if apps[i].Service != nil {
			st := h.Sup.Status(apps[i].ID)
			if st.Running {
				apps[i].ServiceURL = st.URL
			}
		}
	}
	tzName, tzOffset := localTimezone()
	writeJSON(w, http.StatusOK, map[string]any{
		"shell":    ShellVersion,
		"arch":     h.Reg.Arch,
		"userDir":  h.Reg.UserDir,
		"apps":     apps,
		"timezone": tzName,
		"tzOffset": tzOffset, // 分钟, 东八区 = 480; 设备系统时区是 UTC, 外壳用它显示本地时间
		"dev":      devMode(h.Reg.UserDir),
	})
}

// devMode: 用户应用目录旁放一个 .dev 文件, 外壳每次打开应用都绕过 QML 组件缓存 (改完 QML 不用重启 xochitl)。
// 生产环境别开: 每次打开都会多缓存一份编译单元。
func devMode(userDir string) bool {
	_, err := os.Stat(filepath.Join(filepath.Dir(userDir), ".dev"))
	return err == nil
}

// localTimezone 决定外壳显示用的时区: 环境变量 TZ > ~/.config/rmkit-cn/space.json 的 timezone > Asia/Shanghai。
// reMarkable 系统时区固定是 UTC, xochitl 自己不显示时钟, 所以只能我们自己定。
func localTimezone() (string, int) {
	name := os.Getenv("TZ")
	if name == "" {
		if home, err := os.UserHomeDir(); err == nil {
			var cfg struct {
				Timezone string `json:"timezone"`
			}
			if b, err := os.ReadFile(filepath.Join(home, ".config/rmkit-cn/space.json")); err == nil {
				_ = json.Unmarshal(b, &cfg)
				name = cfg.Timezone
			}
		}
	}
	if name == "" {
		name = "Asia/Shanghai"
	}
	loc, err := time.LoadLocation(name)
	if err != nil {
		return "Asia/Shanghai", 480
	}
	_, off := time.Now().In(loc).Zone()
	return name, off / 60
}

func (h *Handler) installUpload(w http.ResponseWriter, r *http.Request) {
	var data []byte
	if f, _, err := r.FormFile("file"); err == nil {
		defer f.Close()
		data, err = io.ReadAll(io.LimitReader(f, maxAppBytes+1))
		if err != nil {
			fail(w, http.StatusBadRequest, err.Error())
			return
		}
	} else {
		var err error
		data, err = io.ReadAll(io.LimitReader(r.Body, maxAppBytes+1))
		if err != nil {
			fail(w, http.StatusBadRequest, err.Error())
			return
		}
	}
	if len(data) > maxAppBytes {
		fail(w, http.StatusRequestEntityTooLarge, "应用包超过 256MB")
		return
	}
	zr, err := zip.NewReader(bytes.NewReader(data), int64(len(data)))
	if err != nil {
		fail(w, http.StatusBadRequest, "不是合法 zip: "+err.Error())
		return
	}
	app, err := h.Reg.InstallZip(zr, h.Sup)
	if err != nil {
		fail(w, http.StatusBadRequest, err.Error())
		return
	}
	writeJSON(w, http.StatusOK, app)
}

func (h *Handler) installURL(w http.ResponseWriter, r *http.Request) {
	var req struct {
		URL    string `json:"url"`
		SHA256 string `json:"sha256"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil || req.URL == "" {
		fail(w, http.StatusBadRequest, "需要 {\"url\": ...}")
		return
	}
	app, err := h.Reg.InstallFromURL(req.URL, req.SHA256, h.Sup)
	if err != nil {
		fail(w, http.StatusBadGateway, err.Error())
		return
	}
	writeJSON(w, http.StatusOK, app)
}

func (h *Handler) uninstall(w http.ResponseWriter, r *http.Request) {
	id := r.PathValue("id")
	if err := h.Reg.Uninstall(id, h.Sup); err != nil {
		fail(w, http.StatusBadRequest, err.Error())
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"deleted": id})
}

func (h *Handler) serviceStatus(w http.ResponseWriter, r *http.Request) {
	writeJSON(w, http.StatusOK, h.Sup.Status(r.PathValue("id")))
}

func (h *Handler) serviceStart(w http.ResponseWriter, r *http.Request) {
	app, ok := h.Reg.Get(r.PathValue("id"))
	if !ok {
		fail(w, http.StatusNotFound, "没有这个应用")
		return
	}
	st, err := h.Sup.Start(app)
	if err != nil {
		fail(w, http.StatusInternalServerError, err.Error())
		return
	}
	writeJSON(w, http.StatusOK, st)
}

func (h *Handler) serviceStop(w http.ResponseWriter, r *http.Request) {
	id := r.PathValue("id")
	if err := h.Sup.Stop(id); err != nil {
		fail(w, http.StatusInternalServerError, err.Error())
		return
	}
	writeJSON(w, http.StatusOK, h.Sup.Status(id))
}

// DataDirOf 给应用私有数据目录 (供 upload-server 其它模块引用, 避免各处拼路径)。
func (h *Handler) DataDirOf(id string) string { return filepath.Join(h.Reg.DataDir, id) }

func writeJSON(w http.ResponseWriter, code int, v any) {
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.WriteHeader(code)
	_ = json.NewEncoder(w).Encode(v)
}

func fail(w http.ResponseWriter, code int, detail string) {
	writeJSON(w, code, map[string]any{"error": detail, "detail": detail})
}
