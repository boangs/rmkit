// Package android 是 RMPPM 单槽 Android 的安装计划与执行 (主机侧)。
// 设备端逻辑在 scripts/android-install.sh; 这里负责预检、把载荷流式送到设备的暂存目录、
// 调用设备端脚本, 以及"进 Android / 回原厂"两个便捷动作。
package android

import (
	"archive/tar"
	"compress/gzip"
	"context"
	"errors"
	"fmt"
	"io"
	"strings"
	"time"

	"github.com/rmkit-cn/desktop/internal/bundle"
	"github.com/rmkit-cn/desktop/internal/probe"
	"github.com/rmkit-cn/desktop/internal/rmkit"
	"github.com/rmkit-cn/desktop/internal/scripts"
	"github.com/rmkit-cn/desktop/internal/sshx"
)

// 暂存目录放 /home (磁盘) 而非 /tmp (tmpfs, 2GB 内存放不下 Android 系统包)。
const stageDir = "/home/root/.rmkit-android-stage"

// 单槽 Android 只验证过这一条固件线: 3.28 (Qt 6.10.3, libqsgepaper 无 EPContentMap API)。
// 显示桥 v55 按这条线的 ABI 编译, 更早固件 (3.27, Qt 6.8) 需要另一套桥, 直接拒绝。
const minFW = 20260702000000

// 需要的载荷 (bundle 内 android/ 下的名字); android-system.tar.gz 可选 (设备已有时可省)。
var required = []string{"fitImage.ahab-android", "modules.tar.gz", "rm-android-init-ss", "rm-touch-relay",
	"rm-epd-bridge", "rm-native-controls", "propset", "boot-android.sh", "init-wrapper.tmpl.sh",
	"android-kernel-revert.service.tmpl", "udhcpd-usb.conf"}

// Plan 是一次单槽 Android 安装的计划。
type Plan struct {
	FWVersion     string   `json:"fwVersion"`
	Slot          string   `json:"slot"`
	HasSystemPkg  bool     `json:"hasSystemPkg"`  // 载荷含 Android 系统包
	ReplaceSystem bool     `json:"replaceSystem"` // 用户勾选: 覆盖设备已有系统
	SystemPresent bool     `json:"systemPresent"` // 设备已有 /home/root/android-system
	Files         []string `json:"files"`
	TotalBytes    int64    `json:"totalBytes"`
	Warnings      []string `json:"warnings"`
	Blockers      []string `json:"blockers"` // 非空则不允许执行
}

// NewPlan 做预检并生成计划 (纯计算)。
func NewPlan(info probe.Info, b *bundle.Bundle, systemPresent, replaceSystem bool) (*Plan, error) {
	if b.Manifest.Component != bundle.ComponentAndroid {
		return nil, fmt.Errorf("载荷包组件是 %s, 不是 android-rmppm", b.Manifest.Component)
	}
	p := &Plan{FWVersion: info.FWVersion, Slot: info.ActiveSlot, SystemPresent: systemPresent, ReplaceSystem: replaceSystem}
	block := func(s string) { p.Blockers = append(p.Blockers, s) }
	warn := func(s string) { p.Warnings = append(p.Warnings, s) }

	if info.ModelKey != "rmppm" {
		block("单槽 Android 目前只支持 reMarkable Paper Pro Move (检测到 " + info.Model + ")")
	}
	if info.Arch != "aarch64" {
		block("需要 aarch64 设备")
	}
	if info.InAndroidMode {
		block("设备当前在 Android 模式, 请先回到 reMarkable 系统")
	}
	if rmkit.FWNumber(info.FWVersion) < minFW {
		block(fmt.Sprintf("固件 %s 早于 3.28 (20260702), 显示桥不兼容该固件的 EPD 库", info.FWVersion))
	}
	if info.Secboot != "" && info.Secboot != "unlocked" {
		block("secboot=" + info.Secboot + ", 自定义内核无法启动")
	}
	if strings.HasSuffix(info.ActiveSlot, "p2") && info.ErrcntA > 0 || strings.HasSuffix(info.ActiveSlot, "p3") && info.ErrcntB > 0 {
		block(fmt.Sprintf("当前槽启动错误计数不为 0 (a=%d b=%d), 先正常重启一次让计数清零", info.ErrcntA, info.ErrcntB))
	}
	if info.RootFreeMB < 45 {
		block(fmt.Sprintf("rootfs 剩余 %d MB, 需要至少 45 MB (内核 15 + 模块 10 + 二进制 + 余量)", info.RootFreeMB))
	}
	for _, r := range required {
		if !b.Has("android/" + r) {
			block("载荷包缺 android/" + r)
		}
	}
	p.HasSystemPkg = b.Has("android/android-system.tar.gz")
	if !p.HasSystemPkg && !systemPresent {
		block("载荷包不含 Android 系统包, 设备上也没有 /home/root/android-system")
	}
	if p.HasSystemPkg && (!systemPresent || replaceSystem) && info.HomeFreeMB < 4096 {
		block(fmt.Sprintf("/home 剩余 %d MB, 解包 Android 系统需要至少 4 GB", info.HomeFreeMB))
	}
	if info.AndroidInstalled {
		warn("本槽已装过单槽 Android, 本次为覆盖更新 (数据目录保留)")
	}
	if !info.RmkitInstalled {
		warn("未检测到 rmkit-cn; 高级面板里的 Android 按钮需要 rmkit-cn, 装完可用 boot-android.sh 或本助手进入 Android")
	}
	for _, n := range b.Names() {
		if !strings.HasPrefix(n, "android/") {
			continue
		}
		if n == "android/android-system.tar.gz" && systemPresent && !replaceSystem {
			continue
		}
		p.Files = append(p.Files, n)
		p.TotalBytes += b.Size(n)
	}
	return p, nil
}

// Run 执行计划: 流式上传到暂存目录 → 设备端脚本落盘。
func Run(ctx context.Context, c *sshx.Client, b *bundle.Bundle, p *Plan, log sshx.Logger) error {
	if len(p.Blockers) > 0 {
		return errors.New("预检未通过: " + strings.Join(p.Blockers, "; "))
	}
	log(fmt.Sprintf("上传 Android 载荷到 %s (%.0f MB)...", stageDir, float64(p.TotalBytes)/1e6))
	start := time.Now()
	pr, pw := io.Pipe()
	go func() { pw.CloseWithError(writeTar(pw, b, p.Files)) }()
	recv := fmt.Sprintf("set -e; rm -rf %[1]s; mkdir -p %[1]s; cd %[1]s && tar -xzf - --no-same-owner", stageDir)
	if err := c.StreamTar(ctx, pr, recv); err != nil {
		_ = pr.Close()
		return fmt.Errorf("上传失败: %w", err)
	}
	log(fmt.Sprintf("上传完成 (%.0fs)", time.Since(start).Seconds()))
	env := map[string]string{"STAGE": stageDir, "REPLACE_SYSTEM": "0"}
	if p.ReplaceSystem {
		env["REPLACE_SYSTEM"] = "1"
	}
	log("设备端安装 (内核/模块/二进制/init 包装)...")
	if err := c.RunScript(ctx, scripts.AndroidInstall, env); err != nil {
		_ = c.RunLogged(ctx, "rm -rf "+stageDir, nil)
		return fmt.Errorf("设备端安装失败: %w", err)
	}
	return nil
}

// Uninstall 卸载单槽 Android。
func Uninstall(ctx context.Context, c *sshx.Client, removeData bool) error {
	env := map[string]string{"REMOVE_DATA": "0"}
	if removeData {
		env["REMOVE_DATA"] = "1"
	}
	return c.RunScript(ctx, scripts.AndroidUninstall, env)
}

// BootAndroid 让设备重启进 Android (本槽, 不切槽)。
func BootAndroid(ctx context.Context, c *sshx.Client) error {
	res, err := c.Run(ctx, "sh /home/root/boot-android.sh --check")
	if err != nil {
		return err
	}
	if res.ExitCode != 0 {
		return errors.New(strings.TrimSpace(res.Stdout + res.Stderr))
	}
	// 启动器自己 sleep 3 后 reboot; setsid 让它脱离本次 SSH 会话
	return c.RunLogged(ctx, "setsid sh /home/root/boot-android.sh >/dev/null 2>&1 < /dev/null & echo '已请求重启进 Android (约 1-3 分钟)'", nil)
}

// ReturnToStock 在 Android 模式下请求优雅回 reMarkable。
func ReturnToStock(ctx context.Context, c *sshx.Client) error {
	return c.RunLogged(ctx, "touch /run/paper-stock-orderly-requested && echo '已请求回 reMarkable 系统 (约 30 秒)'", nil)
}

func writeTar(w io.Writer, b *bundle.Bundle, files []string) error {
	gz := gzip.NewWriter(w)
	tw := tar.NewWriter(gz)
	now := time.Now()
	for _, f := range files {
		name := strings.TrimPrefix(f, "android/")
		if err := tw.WriteHeader(&tar.Header{Typeflag: tar.TypeReg, Name: name, Mode: 0o644, Size: b.Size(f), ModTime: now}); err != nil {
			return err
		}
		rc, err := b.Open(f)
		if err != nil {
			return err
		}
		_, err = io.Copy(tw, rc)
		_ = rc.Close()
		if err != nil {
			return fmt.Errorf("打包 %s: %w", f, err)
		}
	}
	if err := tw.Close(); err != nil {
		return err
	}
	return gz.Close()
}
