package server

import (
	"bufio"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"time"
)

// ---- 字体 active / apply ----
//
// reMarkable 系统通过 fontconfig 扫描 ~/.local/share/fonts/ (= FontsActiveDir)
// 下的真实字体文件来发现可用字体, 不跟随符号链接. 因此启用流程:
//   1. 把 FontsActiveDir 里现存的 .ttf/.otf 全部"归档"回 FontsDir 仓库
//      (仓库里没同名的就移过去, 有同名就直接删 active 副本).
//   2. 把 FontsDir/<name> 硬链接 (失败 fallback 到拷贝) 到 FontsActiveDir/<name>.
//   3. fc-cache + systemctl restart xochitl.
//
// detectActiveFont 直接读 FontsActiveDir 第一个 .ttf/.otf 文件名作为激活态.

func (s *Server) activeFont(w http.ResponseWriter, r *http.Request) {
	name := s.detectActiveFont()
	writeJSON(w, http.StatusOK, map[string]any{"name": name})
}

func (s *Server) detectActiveFont() string {
	entries, err := os.ReadDir(s.cfg.FontsActiveDir)
	if err != nil {
		return ""
	}
	for _, e := range entries {
		if e.IsDir() {
			continue
		}
		ext := strings.ToLower(filepath.Ext(e.Name()))
		if _, ok := allowedFontExts[ext]; !ok {
			continue
		}
		return e.Name()
	}
	return ""
}

func (s *Server) applyFont(w http.ResponseWriter, r *http.Request) {
	name := r.PathValue("name")
	applied, err := s.applyFontInternal(name)
	if err != nil {
		httpError(w, applyFontStatus(err), err.Error())
		return
	}
	go func() {
		if path, err := exec.LookPath("fc-cache"); err == nil {
			_ = exec.Command(path, "-f").Run()
		}
		time.Sleep(500 * time.Millisecond)
		if path, err := exec.LookPath("systemctl"); err == nil {
			_ = exec.Command(path, "restart", "xochitl").Run()
		}
	}()
	writeJSON(w, http.StatusOK, map[string]any{
		"applied": applied,
		"restart": true,
	})
}

// applyFontInternal 执行字体启用的所有文件系统操作, 不重启 xochitl, 不刷 fc-cache.
// 返回应用的字体 basename. 调用方负责后续的 fc-cache + xochitl 重启.
func (s *Server) applyFontInternal(name string) (string, error) {
	src, err := safeJoin(s.cfg.FontsDir, name)
	if err != nil {
		return "", err
	}
	info, err := os.Stat(src)
	if err != nil || info.IsDir() {
		return "", &applyErr{code: http.StatusNotFound, msg: "字体文件不存在"}
	}
	ext := strings.ToLower(filepath.Ext(src))
	if _, ok := allowedFontExts[ext]; !ok {
		return "", &applyErr{code: http.StatusBadRequest, msg: "仅支持 .ttf/.otf"}
	}

	if err := os.MkdirAll(s.cfg.FontsActiveDir, 0o755); err != nil {
		return "", fmt.Errorf("创建激活目录失败: %w", err)
	}
	if err := s.archiveActiveFonts(); err != nil {
		return "", fmt.Errorf("归档旧字体失败: %w", err)
	}
	dst := filepath.Join(s.cfg.FontsActiveDir, filepath.Base(src))
	if err := linkOrCopyFile(src, dst); err != nil {
		return "", fmt.Errorf("拷贝字体到激活目录失败: %w", err)
	}
	return filepath.Base(src), nil
}

type applyErr struct {
	code int
	msg  string
}

func (e *applyErr) Error() string { return e.msg }

func applyFontStatus(err error) int {
	if ae, ok := err.(*applyErr); ok {
		return ae.code
	}
	return http.StatusInternalServerError
}

// archiveActiveFonts 把 FontsActiveDir 里所有 .ttf/.otf 挪回 FontsDir 仓库.
// 仓库已存在同名则直接删 active 副本 (仓库版本权威).
// 仓库不存在则 rename (跨设备失败时 fallback copy+rm).
func (s *Server) archiveActiveFonts() error {
	entries, err := os.ReadDir(s.cfg.FontsActiveDir)
	if err != nil {
		if os.IsNotExist(err) {
			return nil
		}
		return err
	}
	for _, e := range entries {
		if e.IsDir() {
			continue
		}
		ext := strings.ToLower(filepath.Ext(e.Name()))
		if _, ok := allowedFontExts[ext]; !ok {
			continue
		}
		src := filepath.Join(s.cfg.FontsActiveDir, e.Name())
		dst := filepath.Join(s.cfg.FontsDir, e.Name())
		if _, err := os.Stat(dst); err == nil {
			// 仓库已有同名: 直接删 active 副本
			_ = os.Remove(src)
			continue
		} else if !os.IsNotExist(err) {
			return err
		}
		// 仓库无同名: 移过去
		if err := os.Rename(src, dst); err != nil {
			// 跨文件系统 fallback
			if cerr := copyFile(src, dst); cerr != nil {
				return cerr
			}
			_ = os.Remove(src)
		}
	}
	return nil
}

func linkOrCopyFile(src, dst string) error {
	_ = os.Remove(dst) // 防止 link 失败 (目标已存在)
	if err := os.Link(src, dst); err == nil {
		return nil
	}
	return copyFile(src, dst)
}

func copyFile(src, dst string) error {
	in, err := os.Open(src)
	if err != nil {
		return err
	}
	defer in.Close()
	out, err := os.Create(dst)
	if err != nil {
		return err
	}
	defer out.Close()
	if _, err := io.Copy(out, in); err != nil {
		return err
	}
	return nil
}

// ---- 壁纸 active / apply / preview ----

const sleepScreenKey = "SleepScreenPath"

// activeScreen 解析 xochitl.conf, 返回当前 SleepScreenPath 指向的文件 basename
// (仅当文件落在 ScreensDir 内时报告, 否则返回空; 这样未配置或指系统默认时都返回空).
func (s *Server) activeScreen(w http.ResponseWriter, r *http.Request) {
	name := s.detectActiveScreen()
	writeJSON(w, http.StatusOK, map[string]any{"name": name})
}

func (s *Server) detectActiveScreen() string {
	path := readSleepScreenPath(s.cfg.XochitlConf)
	if path == "" {
		return ""
	}
	rel, err := filepath.Rel(s.cfg.ScreensDir, path)
	if err != nil || strings.HasPrefix(rel, "..") {
		return ""
	}
	return filepath.Base(path)
}

func (s *Server) applyScreen(w http.ResponseWriter, r *http.Request) {
	name := r.PathValue("name")
	applied, err := s.applyScreenInternal(name)
	if err != nil {
		httpError(w, applyFontStatus(err), err.Error())
		return
	}
	go func() {
		time.Sleep(500 * time.Millisecond)
		if path, err := exec.LookPath("systemctl"); err == nil {
			_ = exec.Command(path, "restart", "xochitl").Run()
		}
	}()
	writeJSON(w, http.StatusOK, map[string]any{
		"applied": applied,
		"restart": true,
	})
}

// applyScreenInternal 执行壁纸启用的文件系统/conf 操作, 不重启 xochitl. 返回 basename.
func (s *Server) applyScreenInternal(name string) (string, error) {
	target, err := safeJoin(s.cfg.ScreensDir, name)
	if err != nil {
		return "", err
	}
	info, err := os.Stat(target)
	if err != nil || info.IsDir() {
		return "", &applyErr{code: http.StatusNotFound, msg: "壁纸文件不存在"}
	}
	ext := strings.ToLower(filepath.Ext(target))
	if _, ok := allowedScreenExts[ext]; !ok {
		return "", &applyErr{code: http.StatusBadRequest, msg: "仅支持 .png"}
	}
	if err := writeSleepScreenPath(s.cfg.XochitlConf, target); err != nil {
		return "", fmt.Errorf("更新配置失败: %w", err)
	}
	return filepath.Base(target), nil
}

// applyAll 一次性应用 (可选的) 字体 + 壁纸, 只重启一次 xochitl.
// body: {"font": "name.ttf", "screen": "name.png"}, 任一字段可省/为空.
func (s *Server) applyAll(w http.ResponseWriter, r *http.Request) {
	var body struct {
		Font   string `json:"font"`
		Screen string `json:"screen"`
	}
	if r.Body != nil {
		_ = json.NewDecoder(r.Body).Decode(&body)
	}
	body.Font = strings.TrimSpace(body.Font)
	body.Screen = strings.TrimSpace(body.Screen)

	if body.Font == "" && body.Screen == "" {
		httpError(w, http.StatusBadRequest, "font 和 screen 至少需要一个")
		return
	}

	resp := map[string]any{}
	fontTouched := false
	if body.Font != "" {
		applied, err := s.applyFontInternal(body.Font)
		if err != nil {
			httpError(w, applyFontStatus(err), err.Error())
			return
		}
		resp["font"] = applied
		fontTouched = true
	}
	if body.Screen != "" {
		applied, err := s.applyScreenInternal(body.Screen)
		if err != nil {
			httpError(w, applyFontStatus(err), err.Error())
			return
		}
		resp["screen"] = applied
	}
	resp["restart"] = true

	log.Printf("applyAll: font=%q screen=%q -> %v (will restart xochitl)", body.Font, body.Screen, resp)
	go func() {
		if fontTouched {
			if path, err := exec.LookPath("fc-cache"); err == nil {
				if err := exec.Command(path, "-f").Run(); err != nil {
					log.Printf("applyAll: fc-cache failed: %v", err)
				}
			}
		}
		time.Sleep(500 * time.Millisecond)
		path, err := exec.LookPath("systemctl")
		if err != nil {
			log.Printf("applyAll: systemctl not in PATH: %v", err)
			return
		}
		if err := exec.Command(path, "restart", "xochitl").Run(); err != nil {
			log.Printf("applyAll: systemctl restart xochitl failed: %v", err)
		} else {
			log.Printf("applyAll: xochitl restart issued")
		}
	}()

	writeJSON(w, http.StatusOK, resp)
}

func (s *Server) previewScreen(w http.ResponseWriter, r *http.Request) {
	name := r.PathValue("name")
	target, err := safeJoin(s.cfg.ScreensDir, name)
	if err != nil {
		httpError(w, http.StatusBadRequest, err.Error())
		return
	}
	if _, err := os.Stat(target); err != nil {
		httpError(w, http.StatusNotFound, "壁纸文件不存在")
		return
	}
	w.Header().Set("Cache-Control", "max-age=60")
	http.ServeFile(w, r, target)
}

// ---- KOReader 启动 ----
//
// 参考 xovi-apploader (Marvin-Brouwer/rmpp-appload library.cpp::ExternalApplication::launch):
// 它启动 KOReader 等外部应用时直接 QProcess.start(), 不停 xochitl. KOReader 自己接管屏幕,
// 退出后 xochitl 自动恢复. 关键: 必须从环境里清掉 LD_PRELOAD, 否则 xovi.so 会被注入到
// KOReader 进程里导致符号解析失败.
//
// 我们这里直接 fire-and-forget: 起一个独立进程组的 koreader.sh, HTTP 立即返回.
// 不等待退出, 也不需要清理 (xochitl 仍在跑).

const koreaderScript = "/home/root/xovi/exthome/appload/koreader/koreader.sh"

func (s *Server) launchKoreader(w http.ResponseWriter, r *http.Request) {
	if _, err := os.Stat(koreaderScript); err != nil {
		httpError(w, http.StatusNotFound, "未检测到 KOReader: "+koreaderScript)
		return
	}

	cmd := exec.Command(koreaderScript)
	cmd.Dir = filepath.Dir(koreaderScript)
	// RMPP 上 KOReader 必须经 qtfb-shim 转发到 xochitl 内嵌的 QTFB server.
	// 清掉 xochitl 继承下来的 LD_PRELOAD (xovi.so + ime_hook.so), 单独把
	// qtfb-shim.so 注入给 KOReader, 并设置 N_RGB565 (KOReader device.lua 强校验).
	shimPath := filepath.Join(filepath.Dir(koreaderScript), "libs/qtfb-shim.so")
	env := os.Environ()
	cleaned := env[:0]
	for _, kv := range env {
		if strings.HasPrefix(kv, "LD_PRELOAD=") ||
			strings.HasPrefix(kv, "QTFB_SHIM_MODE=") {
			continue
		}
		cleaned = append(cleaned, kv)
	}
	cleaned = append(cleaned,
		"LD_PRELOAD="+shimPath,
		"QTFB_SHIM_MODE=N_RGB565",
	)
	cmd.Env = cleaned
	// 独立进程组, 让 KOReader 不随 upload-server 退出而中止
	cmd.SysProcAttr = newSessionLeader()

	if err := cmd.Start(); err != nil {
		httpError(w, http.StatusInternalServerError, "启动 KOReader 失败: "+err.Error())
		return
	}
	// 防止僵尸: 后台 wait, 不阻塞 HTTP
	go func() { _ = cmd.Wait() }()

	writeJSON(w, http.StatusOK, map[string]any{
		"launched": "koreader",
		"pid":      cmd.Process.Pid,
	})
}

// ---- xochitl.conf 解析 ----

func readSleepScreenPath(confPath string) string {
	f, err := os.Open(confPath)
	if err != nil {
		return ""
	}
	defer f.Close()
	scan := bufio.NewScanner(f)
	for scan.Scan() {
		line := scan.Text()
		if strings.HasPrefix(line, sleepScreenKey+"=") {
			return strings.TrimPrefix(line, sleepScreenKey+"=")
		}
	}
	return ""
}

// writeSleepScreenPath 原子地更新 xochitl.conf 里 [General] section 下的 SleepScreenPath=.
// xochitl 用 QSettings 解析 INI, key 必须落在 [General] 里; 直接 append 到文件末尾会落到最后一个 section
// (比如 [Wifi]), 导致 xochitl 读不到.
func writeSleepScreenPath(confPath, value string) error {
	if err := os.MkdirAll(filepath.Dir(confPath), 0o755); err != nil {
		return fmt.Errorf("mkdir conf dir: %w", err)
	}

	var existing []byte
	if b, err := os.ReadFile(confPath); err == nil {
		existing = b
	} else if os.IsNotExist(err) {
		existing = []byte("[General]\n")
	} else {
		return fmt.Errorf("read conf: %w", err)
	}

	lines := strings.Split(string(existing), "\n")
	// 末尾 split 出来的空字符串会让我们多写一个 \n, 单独处理
	trailingNewline := strings.HasSuffix(string(existing), "\n")
	if trailingNewline {
		lines = lines[:len(lines)-1]
	}

	// 找到 [General] section 的范围 [generalStart, generalEnd)
	// generalStart: [General] 行的下一行; generalEnd: 下一个 [section] 行 (或 len(lines))
	generalStart := -1
	generalEnd := len(lines)
	for i, line := range lines {
		t := strings.TrimSpace(line)
		if t == "[General]" {
			generalStart = i + 1
			continue
		}
		if generalStart >= 0 && strings.HasPrefix(t, "[") && strings.HasSuffix(t, "]") {
			generalEnd = i
			break
		}
	}

	// 没有 [General]: 在文件最前面建一个, 写入 key
	if generalStart < 0 {
		newLines := []string{"[General]", sleepScreenKey + "=" + value}
		newLines = append(newLines, lines...)
		lines = newLines
	} else {
		// 在 [General] 段内找现存的 key, 替换; 找不到则在段末追加
		replaced := false
		for i := generalStart; i < generalEnd; i++ {
			if strings.HasPrefix(lines[i], sleepScreenKey+"=") {
				lines[i] = sleepScreenKey + "=" + value
				replaced = true
				break
			}
		}
		if !replaced {
			// 在段末插入 (generalEnd 位置)
			lines = append(lines[:generalEnd], append([]string{sleepScreenKey + "=" + value}, lines[generalEnd:]...)...)
		}
	}

	out := strings.Join(lines, "\n") + "\n"

	tmp := confPath + ".tmp"
	if err := os.WriteFile(tmp, []byte(out), 0o644); err != nil {
		return fmt.Errorf("write tmp: %w", err)
	}
	if err := os.Rename(tmp, confPath); err != nil {
		return fmt.Errorf("rename: %w", err)
	}
	return nil
}
