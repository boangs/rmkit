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
	"os"
	"path/filepath"
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
	p := &Plan{FWVersion: info.FWVersion, Slot: info.ActiveSlot, SystemPresent: systemPresent, ReplaceSystem: replaceSystem,
		Files: []string{}, Warnings: []string{}, Blockers: []string{}} // JSON 保证 [] 而非 null
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

// Diagnose 收集一次 Android 启动诊断 (给用户复制发到 Issue): 固件/槽位/计数/内核链接/包装状态
// + /native-boot.log 最后一轮 + 内核日志摘要 (若开过采集)。只读, 任何模式下可用。
func Diagnose(ctx context.Context, c *sshx.Client) (string, error) {
	res, err := c.Run(ctx, `echo "== 基本 =="
echo "fw=$(cat /etc/version 2>/dev/null) pid1=$(cat /proc/1/comm) uptime=$(cut -d. -f1 /proc/uptime)s"
echo "slot=$(rootdev 2>/dev/null) boot_part=$(cat /sys/bus/mmc/devices/mmc0:0001/boot_part 2>/dev/null) errcnt a/b=$(cat /sys/devices/platform/lpgpr/roota_errcnt 2>/dev/null)/$(cat /sys/devices/platform/lpgpr/rootb_errcnt 2>/dev/null) secboot=$(cat /sys/devices/platform/lpgpr/secboot 2>/dev/null)"
echo "kernel_link=$(readlink /boot/fitImage.ahab 2>/dev/null) android_kernel=$(stat -c %s /boot/fitImage.ahab-android 2>/dev/null)B flag=$([ -e /.boot-android-mode ] && echo present || echo absent)"
echo "init_wrapper=$(grep -c boot-android-mode /sbin/init 2>/dev/null) init_ss=$(stat -c %s /usr/bin/rm-android-init-ss 2>/dev/null)B bridge=$(stat -c %s /usr/bin/rm-epd-bridge 2>/dev/null)B relay=$(stat -c %s /usr/bin/rm-touch-relay 2>/dev/null)B"
echo "modules=$(ls /lib/modules/ 2>/dev/null | tr '\n' ' ') ashmem=$(grep -c ashmem /lib/modules/6.12.49+git+f21cbcc9ed9a/modules.dep 2>/dev/null)"
echo "system=$([ -e /home/root/android-system/system/bin/init ] && echo ok || echo missing) data_sentinel=$([ -e /home/root/native-android-data-v1/.paper-expanded-data-v1 ] && echo ok || echo missing) udhcpd=$([ -e /etc/paperhome/udhcpd-usb.conf ] && echo ok || echo missing)"
echo "root_free=$(df -kP / | awk 'END{print $4}')KB home_free=$(df -kP /home | awk 'END{print $4}')KB"
echo "== boot-android.sh --check =="; sh /home/root/boot-android.sh --check 2>&1
echo "== /native-boot.log 最后一轮 =="
if [ -f /native-boot.log ]; then awk '/native Android boot wrapper started/{n++} {l[NR]=$0; s[NR]=n} END{for(i=1;i<=NR;i++) if(s[i]==n) print l[i]}' /native-boot.log | tail -n 60; else echo "(没有 /native-boot.log: android 内核从未起来过, 或包装脚本没进 Android 分支)"; fi
echo "== /native-kmsg.log 摘要 =="
if [ -f /native-kmsg.log ]; then sed 's/^[0-9]*,[0-9]*,\([0-9]*\),-;/\1 /' /native-kmsg.log | grep -iE "Linux version|Machine model|lpspi|lpi2c|elants|rm-android-init|panic|Oops|watchdog|init: Service .zygote|symbol lookup" | tail -n 40; else echo "(无内核日志; 下次进 Android 前助手会自动打开采集)"; fi`)
	if err != nil {
		return "", err
	}
	return res.Stdout + res.Stderr, nil
}

// BootAndroid 让设备重启进 Android (本槽, 不切槽)。进入前打开一次性内核日志采集
// (/enable-native-kmsg), 失败时诊断里就有 android 内核的 dmesg。
func BootAndroid(ctx context.Context, c *sshx.Client) error {
	_, _ = c.Run(ctx, "mount -o remount,rw / 2>/dev/null; touch /enable-native-kmsg; rm -f /native-kmsg.log")
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

// ResetData 清空 Android 数据目录 (应用/设置全部重置, 下次进 Android 重新首启, 约 5 分钟)。
// 只允许在 reMarkable 模式下做 (Android 模式下该目录正被使用)。
func ResetData(ctx context.Context, c *sshx.Client) error {
	return c.RunLogged(ctx, `set -e
[ "$(cat /proc/1/comm)" = systemd ] || { echo '请先回到 reMarkable 系统'; exit 1; }
D=/home/root/native-android-data-v1
rm -rf "$D.old"; [ -d "$D" ] && mv "$D" "$D.old"
mkdir -p "$D"; chmod 771 "$D"
echo "provisioned $(date -u +%FT%TZ) rmkit-desktop reset" > "$D/.paper-expanded-data-v1"
rm -rf "$D.old"; sync
echo '  ✓ Android 数据已清空, 下次进 Android 将重新首次开机 (约 5 分钟)'`, nil)
}

// InstallAPKs 在 Android 模式下安装本机 APK: 上传到 Android 的 /data/local/tmp/apks, 经宿主→Android
// 命令通道 (propset 按 property_service 协议 setprop paper.exec → init 跑 /data/local/tmp/exec.sh)
// 执行 pm install -r -g, 轮询结果文件。
func InstallAPKs(ctx context.Context, c *sshx.Client, paths []string, log sshx.Logger) error {
	if len(paths) == 0 {
		return errors.New("没有选择 APK")
	}
	res, err := c.Run(ctx, "[ -d /android ] && [ \"$(cat /proc/1/comm)\" != systemd ] && [ -x /home/root/propset ] && echo ok")
	if err != nil {
		return err
	}
	if strings.TrimSpace(res.Stdout) != "ok" {
		return errors.New("设备不在 Android 模式 (或缺 propset), 请先重启进 Android")
	}
	const tmp = "/android-data/local/tmp"
	var names []string
	for _, p := range paths {
		f, err := os.Open(p)
		if err != nil {
			return err
		}
		name := filepath.Base(p)
		err = c.WriteFile(ctx, tmp+"/apks/"+name, f, "644")
		_ = f.Close()
		if err != nil {
			return err
		}
		names = append(names, name)
		log("已上传 " + name)
	}
	var sb strings.Builder
	sb.WriteString("#!/system/bin/sh\n{\n")
	for _, n := range names {
		sb.WriteString(fmt.Sprintf("echo \"== install %s\"; pm install -r -g /data/local/tmp/apks/%s 2>&1 | tail -n 2\n", n, n))
	}
	sb.WriteString("echo ALL_DONE\n} > /data/local/tmp/out.txt 2>&1\n")
	if err := c.WriteFile(ctx, tmp+"/exec.sh", strings.NewReader(sb.String()), "755"); err != nil {
		return err
	}
	trigger := `rm -f ` + tmp + `/out.txt
ADBD=""; for p in /proc/[0-9]*; do [ "$(cat $p/comm 2>/dev/null)" = "adbd" ] && ADBD=${p#/proc/} && break; done
[ -n "$ADBD" ] || { echo 'Android 还没起完 (无 adbd), 稍后再试'; exit 1; }
/home/root/propset /proc/$ADBD/root/dev/socket/property_service paper.exec install-$(date +%s) >/dev/null && echo '安装任务已交给 Android'`
	if err := c.RunLogged(ctx, trigger, nil); err != nil {
		return err
	}
	deadline := time.Now().Add(15 * time.Minute)
	for time.Now().Before(deadline) {
		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-time.After(5 * time.Second):
		}
		r, err := c.Run(ctx, "cat "+tmp+"/out.txt 2>/dev/null")
		if err != nil {
			return err
		}
		if strings.Contains(r.Stdout, "ALL_DONE") {
			for _, line := range strings.Split(strings.TrimSpace(r.Stdout), "\n") {
				if line != "ALL_DONE" {
					log("  " + line)
				}
			}
			return nil
		}
	}
	return errors.New("等待安装结果超时 (15 分钟)")
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
