package main

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"

	"github.com/rmkit-cn/desktop/internal/android"
	"github.com/rmkit-cn/desktop/internal/bundle"
	"github.com/rmkit-cn/desktop/internal/probe"
	"github.com/rmkit-cn/desktop/internal/rmkit"
	"github.com/rmkit-cn/desktop/internal/sshx"
	"github.com/wailsapp/wails/v2/pkg/runtime"
)

// App 是 Wails 绑定层: 前端只能通过这里的方法与设备交互, 每个动作都会写审计日志。
type App struct {
	ctx    context.Context
	mu     sync.Mutex
	client *sshx.Client
	info   *probe.Info
	bundle *bundle.Bundle
	logF   *os.File
	logDir string
	cancel context.CancelFunc
}

// NewApp 创建应用。
func NewApp() *App { return &App{} }

func (a *App) startup(ctx context.Context) {
	a.ctx = ctx
	dir, err := os.UserConfigDir()
	if err != nil {
		dir = os.TempDir()
	}
	a.logDir = filepath.Join(dir, "rmkit-assistant", "logs")
	_ = os.MkdirAll(a.logDir, 0o755)
	a.logF, _ = os.Create(filepath.Join(a.logDir, time.Now().Format("20060102-150405")+".log"))
	a.log("rmkit 助手启动; 审计日志目录 " + a.logDir)
}

func (a *App) shutdown(context.Context) {
	if a.client != nil {
		_ = a.client.Close()
	}
	if a.logF != nil {
		_ = a.logF.Close()
	}
}

// log 同时送前端 (事件 "log") 与本地审计文件。
func (a *App) log(line string) {
	ts := time.Now().Format("15:04:05")
	if a.logF != nil {
		_, _ = a.logF.WriteString(ts + " " + line + "\n")
	}
	if a.ctx != nil {
		runtime.EventsEmit(a.ctx, "log", ts+"  "+line)
	}
}

// LogDir 返回审计日志目录。
func (a *App) LogDir() string { return a.logDir }

// OpenLogDir 用系统文件管理器打开日志目录。
func (a *App) OpenLogDir() { runtime.BrowserOpenURL(a.ctx, "file://"+a.logDir) }

// Connect 连接设备并探测。密码只保存在本次连接的内存里。
func (a *App) Connect(host, password string) (*probe.Info, error) {
	a.mu.Lock()
	defer a.mu.Unlock()
	if a.client != nil {
		_ = a.client.Close()
		a.client = nil
	}
	host = strings.TrimSpace(host)
	if host == "" {
		host = "10.11.99.1"
	}
	ctx, cancel := context.WithTimeout(a.ctx, 20*time.Second)
	defer cancel()
	c, err := sshx.Dial(ctx, host, password, a.log)
	if err != nil {
		a.log("连接失败: " + err.Error())
		return nil, err
	}
	a.client = c
	return a.probeLocked()
}

// Probe 重新探测已连接设备。
func (a *App) Probe() (*probe.Info, error) {
	a.mu.Lock()
	defer a.mu.Unlock()
	return a.probeLocked()
}

func (a *App) probeLocked() (*probe.Info, error) {
	if a.client == nil {
		return nil, errors.New("未连接设备")
	}
	ctx, cancel := context.WithTimeout(a.ctx, 30*time.Second)
	defer cancel()
	info, err := probe.Run(ctx, a.client)
	if err != nil {
		a.log("探测失败: " + err.Error())
		return nil, err
	}
	a.info = &info
	mode := "reMarkable"
	if info.InAndroidMode {
		mode = "Android"
	}
	a.log(fmt.Sprintf("设备: %s / %s / 固件 %s / 槽 %s / 模式 %s / rootfs 剩 %dMB / home 剩 %dMB",
		info.Model, info.Arch, info.FWVersion, info.ActiveSlot, mode, info.RootFreeMB, info.HomeFreeMB))
	return &info, nil
}

// Disconnect 断开。
func (a *App) Disconnect() {
	a.mu.Lock()
	defer a.mu.Unlock()
	if a.client != nil {
		_ = a.client.Close()
		a.client = nil
		a.info = nil
		a.log("已断开")
	}
}

// BundleInfo 是给前端看的载荷包摘要。
type BundleInfo struct {
	Path      string `json:"path"`
	Component string `json:"component"`
	Version   string `json:"version"`
	Created   string `json:"created"`
	Notes     string `json:"notes"`
	Files     int    `json:"files"`
	Bytes     int64  `json:"bytes"`
}

// ChooseBundle 弹文件选择框选本地载荷包。
func (a *App) ChooseBundle() (*BundleInfo, error) {
	path, err := runtime.OpenFileDialog(a.ctx, runtime.OpenDialogOptions{
		Title:   "选择载荷包 (rmkit-cn-bundle-*.zip / android-rmppm-bundle-*.zip)",
		Filters: []runtime.FileFilter{{DisplayName: "载荷包 (*.zip)", Pattern: "*.zip"}},
	})
	if err != nil || path == "" {
		return nil, err
	}
	return a.OpenBundle(path)
}

// OpenBundle 打开并校验载荷包 (逐文件 sha256)。
func (a *App) OpenBundle(path string) (*BundleInfo, error) {
	a.mu.Lock()
	defer a.mu.Unlock()
	if a.bundle != nil {
		_ = a.bundle.Close()
		a.bundle = nil
	}
	a.log("校验载荷包 " + path)
	b, err := bundle.Open(path, true)
	if err != nil {
		a.log("载荷包无效: " + err.Error())
		return nil, err
	}
	a.bundle = b
	var total int64
	for _, e := range b.Manifest.Files {
		total += e.Size
	}
	a.log(fmt.Sprintf("载荷包 OK: %s 版本 %s, %d 个文件", b.Manifest.Component, b.Manifest.Version, len(b.Manifest.Files)))
	return &BundleInfo{Path: path, Component: string(b.Manifest.Component), Version: b.Manifest.Version,
		Created: b.Manifest.Created, Notes: b.Manifest.Notes, Files: len(b.Manifest.Files), Bytes: total}, nil
}

// DownloadBundle 从 URL 下载载荷包到本机缓存目录 (进度走事件 "progress"), 然后打开校验。
// 可选 sha256 与整个 zip 比对 (Release 页公布的值)。
func (a *App) DownloadBundle(url, sha string) (*BundleInfo, error) {
	dir, _ := os.UserCacheDir()
	dir = filepath.Join(dir, "rmkit-assistant")
	_ = os.MkdirAll(dir, 0o755)
	dst := filepath.Join(dir, filepath.Base(strings.Split(url, "?")[0]))
	a.log("下载 " + url)
	req, err := http.NewRequestWithContext(a.ctx, http.MethodGet, url, nil)
	if err != nil {
		return nil, err
	}
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		return nil, fmt.Errorf("下载失败: %w", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != 200 {
		return nil, fmt.Errorf("下载失败: HTTP %d", resp.StatusCode)
	}
	f, err := os.Create(dst + ".part")
	if err != nil {
		return nil, err
	}
	h := sha256.New()
	pw := &progressWriter{total: resp.ContentLength, emit: func(done, total int64) {
		runtime.EventsEmit(a.ctx, "progress", map[string]int64{"done": done, "total": total})
	}}
	_, err = io.Copy(io.MultiWriter(f, h, pw), resp.Body)
	_ = f.Close()
	if err != nil {
		_ = os.Remove(dst + ".part")
		return nil, fmt.Errorf("下载中断: %w", err)
	}
	if sha != "" && !strings.EqualFold(hex.EncodeToString(h.Sum(nil)), strings.TrimSpace(sha)) {
		_ = os.Remove(dst + ".part")
		return nil, errors.New("下载文件 sha256 与给定值不符, 已丢弃")
	}
	if err := os.Rename(dst+".part", dst); err != nil {
		return nil, err
	}
	return a.OpenBundle(dst)
}

// PlanRmkit 生成 rmkit-cn 安装计划。
func (a *App) PlanRmkit() (*rmkit.Plan, error) {
	a.mu.Lock()
	defer a.mu.Unlock()
	if a.info == nil || a.bundle == nil {
		return nil, errors.New("先连接设备并选择载荷包")
	}
	return rmkit.NewPlan(*a.info, a.bundle)
}

// RunRmkit 执行 rmkit-cn 安装/更新。
func (a *App) RunRmkit() error {
	return a.runTask("安装 rmkit-cn", func(ctx context.Context) error {
		p, err := rmkit.NewPlan(*a.info, a.bundle)
		if err != nil {
			return err
		}
		return rmkit.Run(ctx, a.client, a.bundle, p, a.log)
	})
}

// UninstallRmkit 卸载 rmkit-cn。
func (a *App) UninstallRmkit() error {
	return a.runTask("卸载 rmkit-cn", func(ctx context.Context) error { return rmkit.Uninstall(ctx, a.client) })
}

// PlanAndroid 生成单槽 Android 安装计划 (含预检阻断项)。
func (a *App) PlanAndroid(replaceSystem bool) (*android.Plan, error) {
	a.mu.Lock()
	defer a.mu.Unlock()
	if a.info == nil || a.bundle == nil {
		return nil, errors.New("先连接设备并选择载荷包")
	}
	present, err := a.androidSystemPresent()
	if err != nil {
		return nil, err
	}
	return android.NewPlan(*a.info, a.bundle, present, replaceSystem)
}

func (a *App) androidSystemPresent() (bool, error) {
	ctx, cancel := context.WithTimeout(a.ctx, 15*time.Second)
	defer cancel()
	res, err := a.client.Run(ctx, "[ -e /home/root/android-system/system/bin/init ] && echo yes || echo no")
	if err != nil {
		return false, err
	}
	return strings.TrimSpace(res.Stdout) == "yes", nil
}

// RunAndroid 执行单槽 Android 安装。
func (a *App) RunAndroid(replaceSystem bool) error {
	return a.runTask("安装单槽 Android", func(ctx context.Context) error {
		present, err := a.androidSystemPresent()
		if err != nil {
			return err
		}
		p, err := android.NewPlan(*a.info, a.bundle, present, replaceSystem)
		if err != nil {
			return err
		}
		return android.Run(ctx, a.client, a.bundle, p, a.log)
	})
}

// UninstallAndroid 卸载单槽 Android。
func (a *App) UninstallAndroid(removeData bool) error {
	return a.runTask("卸载单槽 Android", func(ctx context.Context) error { return android.Uninstall(ctx, a.client, removeData) })
}

// BootAndroid 重启进 Android。
func (a *App) BootAndroid() error {
	return a.runTask("重启进 Android", func(ctx context.Context) error { return android.BootAndroid(ctx, a.client) })
}

// ReturnToStock 从 Android 模式回 reMarkable。
func (a *App) ReturnToStock() error {
	return a.runTask("回 reMarkable 系统", func(ctx context.Context) error { return android.ReturnToStock(ctx, a.client) })
}

// Cancel 取消正在执行的任务 (只是中断 SSH 会话; 设备端脚本自带 abort_safe 回退)。
func (a *App) Cancel() {
	a.mu.Lock()
	defer a.mu.Unlock()
	if a.cancel != nil {
		a.cancel()
	}
}

func (a *App) runTask(name string, fn func(ctx context.Context) error) error {
	a.mu.Lock()
	if a.client == nil || a.info == nil {
		a.mu.Unlock()
		return errors.New("未连接设备")
	}
	ctx, cancel := context.WithCancel(a.ctx)
	a.cancel = cancel
	a.mu.Unlock()
	defer cancel()
	a.log("===== " + name + " 开始 =====")
	err := fn(ctx)
	if err != nil {
		a.log("✗ " + name + " 失败: " + err.Error())
		return err
	}
	a.log("✓ " + name + " 完成")
	return nil
}

type progressWriter struct {
	done, total int64
	last        time.Time
	emit        func(done, total int64)
}

func (p *progressWriter) Write(b []byte) (int, error) {
	p.done += int64(len(b))
	if time.Since(p.last) > 200*time.Millisecond {
		p.last = time.Now()
		p.emit(p.done, p.total)
	}
	return len(b), nil
}
