// Package rmkit 是 installer/install.sh 主机侧逻辑的 Go 移植: 按机型选产物、构造与设备
// 文件树一致的 payload、单次 tar 流式传输, 再把设备端六阶段防砖脚本原样交给设备执行。
//
// 设备路径、文件清单、条件判断均与 install.sh 一一对应 (注释里标了行号), 改任一边请同步。
package rmkit

import (
	"archive/tar"
	"compress/gzip"
	"context"
	"errors"
	"fmt"
	"io"
	"path"
	"sort"
	"strconv"
	"strings"
	"time"

	"github.com/rmkit-cn/desktop/internal/bundle"
	"github.com/rmkit-cn/desktop/internal/probe"
	"github.com/rmkit-cn/desktop/internal/scripts"
	"github.com/rmkit-cn/desktop/internal/sshx"
)

// FileEntry 是 payload 里一个文件: 载荷包内路径 → 设备路径。
type FileEntry struct {
	Device string `json:"device"`
	Source string `json:"source"`
	Mode   int64  `json:"mode"`
	Size   int64  `json:"size"`
}

// Plan 是一次 rmkit-cn 安装的完整计划, 先给用户过目再执行。
type Plan struct {
	Arch       string `json:"arch"`
	ModelKey   string `json:"modelKey"`
	FWVersion  string `json:"fwVersion"`
	NeedXovi   bool   `json:"needXovi"`
	DeployRime bool   `json:"deployRime"`
	QMLInject  bool   `json:"qmlInject"`
	Librarian  bool   `json:"librarian"`

	Files      []FileEntry `json:"files"`
	TotalBytes int64       `json:"totalBytes"`
	Warnings   []string    `json:"warnings"`

	zzHeader  string
	xoviTar   string
	xoviArch  string
	uploadBin string
	imeBin    string
}

type arch struct {
	uploadBin, imeBin, imeHook, ext, xovi, qmdTool, qmlInject, qmlInjectImpl, rimeBin string
}

// install.sh 97-127
func archFor(a string) (arch, error) {
	switch a {
	case "aarch64":
		return arch{"upload-server-aarch64", "ime-server", "ime_hook.so", "aarch64", "aarch64", "qmd-tool-aarch64",
			"qml_inject-aarch64.so", "qml_inject_impl-aarch64.so", "ime-server-rime-aarch64"}, nil
	case "armv7l":
		return arch{"upload-server-armv7", "ime-server-armv7", "ime_hook-armv7.so", "armv7", "arm32", "qmd-tool-armv7",
			"qml_inject-armv7.so", "qml_inject_impl-armv7.so", "ime-server-rime-armv7"}, nil
	}
	return arch{}, fmt.Errorf("不支持的架构: %s (仅支持 aarch64 / armv7l)", a)
}

// NewPlan 根据探测结果与载荷包内容生成计划 (纯计算, 不碰设备)。
func NewPlan(info probe.Info, b *bundle.Bundle) (*Plan, error) {
	if b.Manifest.Component != bundle.ComponentRmkit {
		return nil, fmt.Errorf("载荷包组件是 %s, 不是 rmkit-cn", b.Manifest.Component)
	}
	if info.InAndroidMode {
		return nil, errors.New("设备当前在 Android 模式, 请先回到 reMarkable 系统")
	}
	ar, err := archFor(info.Arch)
	if err != nil {
		return nil, err
	}
	p := &Plan{Arch: info.Arch, ModelKey: info.ModelKey, FWVersion: info.FWVersion, NeedXovi: !info.HaveXovi,
		Files: []FileEntry{}, Warnings: []string{}, // 保证 JSON 是 [] 而不是 null (前端直接 .map)
		xoviArch: ar.xovi, uploadBin: ar.uploadBin, imeBin: ar.imeBin}
	if info.ModelKey == "unknown" {
		p.Warnings = append(p.Warnings, "未识别的机型 (分辨率 "+info.Resolution+"), 按架构 "+info.Arch+" 部署; 未适配固件会由 fail-open 预检自动降级为不注入")
	}

	// install.sh 165-184: librime 三条硬门槛 (② 的 /rime/schema 检查由 mkbundle 打包时完成)
	if b.Has("dist/"+ar.rimeBin) && b.Has("dist/rime-prebuilt.tar.gz") && b.Has("dist/rime-runtime-data.tar.gz") {
		p.DeployRime = true
		p.imeBin = ar.rimeBin
	}
	// install.sh 375-394: 必备产物
	for _, f := range []string{"dist/" + ar.uploadBin, "dist/" + p.imeBin, "dist/" + ar.imeHook, "dist/" + ar.qmdTool,
		"vendor/extensions/xovi-message-broker-" + ar.ext + ".so", "dist/reMarkable_zh_CN.qm", "qmd/zh_CN.rcc"} {
		if !b.Has(f) {
			return nil, fmt.Errorf("载荷包缺必备产物 %s", f)
		}
	}
	p.Librarian = ar.ext != "armv7" // install.sh 377-381: rm2 上 librarian 漏堆, 只部署 aarch64
	if p.Librarian && !b.Has("vendor/extensions/librarian-"+ar.ext+".so") {
		return nil, errors.New("载荷包缺 vendor/extensions/librarian-" + ar.ext + ".so")
	}
	if p.NeedXovi {
		p.xoviTar = "vendor/xovi/xovi-" + ar.xovi + ".tar.gz"
		if !b.Has(p.xoviTar) || !b.Has("vendor/xovi/xochitl-xovi") {
			return nil, errors.New("设备没有 xovi 且载荷包不含 vendor/xovi, 无法自动部署")
		}
	}
	// install.sh 223-241: 按架构的 drop-in [Unit] 头
	if info.Arch == "armv7l" {
		p.zzHeader = "[Unit]"
	} else {
		p.zzHeader = "[Unit]\nAfter=home.mount\nConditionPathExists=/home/root/xovi/xovi.so\nConditionPathExists=/home/root/rmkit-cn/bin/ime_hook.so"
	}

	add := func(device, source string, mode int64) {
		if !b.Has(source) {
			return
		}
		p.Files = append(p.Files, FileEntry{Device: device, Source: source, Mode: mode, Size: b.Size(source)})
	}
	must := func(device, source string, mode int64) error {
		if !b.Has(source) {
			return fmt.Errorf("载荷包缺 %s", source)
		}
		add(device, source, mode)
		return nil
	}
	const base = "/home/root/rmkit-cn"
	const deploy = "/home/root/xovi/exthome/qt-resource-rebuilder"

	// install.sh 416-434: bin/
	for _, s := range []string{"scripts/version-switcher.sh", "installer/reenable.sh", "installer/fw-upgrade.sh",
		"installer/precheck.sh", "installer/qml-inject-lib.sh", "installer/ota-watch.sh"} {
		add(base+"/bin/"+path.Base(s), s, 0o755)
	}
	if err := must(base+"/bin/ime-server", "dist/"+p.imeBin, 0o755); err != nil {
		return nil, err
	}
	if p.DeployRime {
		add(base+"/rime-stage/rime-prebuilt.tar.gz", "dist/rime-prebuilt.tar.gz", 0o644)
		add(base+"/rime-stage/rime-runtime-data.tar.gz", "dist/rime-runtime-data.tar.gz", 0o644)
	}
	add(base+"/bin/ime_hook.so", "dist/"+ar.imeHook, 0o755)
	add(base+"/bin/qmd-tool", "dist/"+ar.qmdTool, 0o755)
	// install.sh 436-453: 运行时 QML 注入 (可选)
	if b.Has("dist/"+ar.qmlInject) && b.Has("dist/"+ar.qmlInjectImpl) {
		p.QMLInject = true
		add(base+"/bin/qml_inject.so", "dist/"+ar.qmlInject, 0o755)
		add(base+"/bin/qml_inject_impl.so", "dist/"+ar.qmlInjectImpl, 0o755)
		for _, r := range []string{"adv_panel.qml", "glyph_ai_button.qml", "text_ai_button.qml", "pinyin_ime.qml", "icon_ai.svg"} {
			add(base+"/bin/"+r, "intercept/qml-inject/"+r, 0o755)
		}
	}
	// install.sh 456-466: qmd-src (+compat)
	for _, n := range b.Names() {
		if strings.HasPrefix(n, "qmd-src/") && strings.HasSuffix(n, ".qmd") {
			add(base+"/"+n, n, 0o644)
		}
	}
	// install.sh 468-479: compiled-qmd/<fw> 缓存种子 (设备端阶段 3 会用设备 hashtab 重编覆盖)
	for _, n := range b.Names() {
		if strings.HasPrefix(n, "dist/") && strings.HasSuffix(n, ".qmd") {
			add(base+"/compiled-qmd/"+info.FWVersion+"/"+path.Base(n), n, 0o644)
		}
	}
	add(base+"/compiled-qmd/"+info.FWVersion+"/pinyin_interceptor.qmd", "qmd/pinyin_interceptor.qmd", 0o644)
	// install.sh 481-487: static/
	add(base+"/static/pinyin_interceptor.qmd", "qmd/pinyin_interceptor.qmd", 0o644)
	add(base+"/static/zh_CN.rcc", "qmd/zh_CN.rcc", 0o644)
	add(base+"/static/reMarkable_zh_CN.qm", "dist/reMarkable_zh_CN.qm", 0o644)
	// install.sh 489-494: upload-server
	add(base+"/upload-server/upload-server", "dist/"+ar.uploadBin, 0o755)
	add(base+"/upload-server/static/index.html", "upload-server-go/static/index.html", 0o644)
	add(base+"/upload-server/static/qr.html", "upload-server-go/static/qr.html", 0o644)
	// install.sh 496-502: qmd/
	add(base+"/qmd/pinyin_interceptor.qmd", "qmd/pinyin_interceptor.qmd", 0o644)
	add(base+"/qmd/zh_CN.rcc", "qmd/zh_CN.rcc", 0o644)
	add(base+"/qmd/zh_CN/keyboard_layout.json", "qmd/zh_CN/keyboard_layout.json", 0o644)
	// install.sh 504-511: qmldiff 加载目录 (阶段 2 会先清空再由阶段 3 重编, 这里是初始种子)
	for _, q := range []string{"advanced_panel.qmd", "language_zh_cn.qmd", "ai_text_button.qmd"} {
		add(deploy+"/"+q, "dist/"+q, 0o644)
	}
	add(deploy+"/pinyin_interceptor.qmd", "qmd/pinyin_interceptor.qmd", 0o644)
	add(deploy+"/zh_CN.rcc", "qmd/zh_CN.rcc", 0o644)
	// install.sh 513-517: 棋类资源
	for _, n := range b.Names() {
		if strings.HasPrefix(n, "assets/chess/") {
			add(deploy+"/chess/"+path.Base(n), n, 0o644)
		}
	}
	// install.sh 519-525: xovi 扩展
	if p.Librarian {
		add("/home/root/xovi/extensions.d/librarian.so", "vendor/extensions/librarian-"+ar.ext+".so", 0o755)
	}
	add("/home/root/xovi/extensions.d/xovi-message-broker.so", "vendor/extensions/xovi-message-broker-"+ar.ext+".so", 0o755)
	// install.sh 527-529: 中文 qm
	add("/usr/share/remarkable/xochitl/translations/reMarkable_zh_CN.qm", "dist/reMarkable_zh_CN.qm", 0o644)
	// install.sh 531-538: systemd 暂存 (设备端阶段 1 双写到 /etc)
	for _, n := range b.Names() {
		if strings.HasPrefix(n, "systemd/") {
			add("/tmp/rmkit-cn-systemd-staging/"+path.Base(n), n, 0o644)
		}
	}

	sort.Slice(p.Files, func(i, j int) bool { return p.Files[i].Device < p.Files[j].Device })
	for _, f := range p.Files {
		p.TotalBytes += f.Size
	}
	return p, nil
}

// Run 执行计划。log 收到的每一行都同时进本地审计日志。
func Run(ctx context.Context, c *sshx.Client, b *bundle.Bundle, p *Plan, log sshx.Logger) error {
	if p.NeedXovi { // install.sh 186-213
		log("设备无 xovi, 自动部署...")
		for _, s := range []string{p.xoviTar, "vendor/xovi/xochitl-xovi"} {
			rc, err := b.Open(s)
			if err != nil {
				return err
			}
			err = c.WriteFile(ctx, "/tmp/"+path.Base(s), rc, "644")
			_ = rc.Close()
			if err != nil {
				return err
			}
		}
		if err := c.RunLogged(ctx, fmt.Sprintf(`set -e
cd /home/root
tar -xzf /tmp/%[1]s --no-same-owner --no-same-permissions
cp /tmp/xochitl-xovi /home/root/xovi/xochitl-xovi
chmod +x /home/root/xovi/xochitl-xovi
chown -R root:root /home/root/xovi
rm /tmp/%[1]s /tmp/xochitl-xovi
echo '  ✓ xovi 部署完成'`, path.Base(p.xoviTar)), nil); err != nil {
			return fmt.Errorf("部署 xovi 失败: %w", err)
		}
	}

	// install.sh 543-566: 单次 tar 流式传输
	log(fmt.Sprintf("传输 payload (%d 个文件, %.1f MB, 单次 SSH 流式)...", len(p.Files), float64(p.TotalBytes)/1e6))
	start := time.Now()
	pr, pw := io.Pipe()
	go func() { pw.CloseWithError(writeTar(pw, b, p.Files)) }()
	if err := c.StreamTar(ctx, pr, scripts.ReceivePayload); err != nil {
		_ = pr.Close()
		return fmt.Errorf("传输失败: %w", err)
	}
	log(fmt.Sprintf("传输完成 (%.0fs)", time.Since(start).Seconds()))

	// install.sh 568-573: 必须在 reenable 之前写 .last_fw_version (防 fw-upgrade.sh 误触发)
	if err := c.WriteFile(ctx, "/home/root/rmkit-cn/.last_fw_version", strings.NewReader(p.FWVersion), "644"); err != nil {
		return err
	}
	log("✓ .last_fw_version 已写入 (" + p.FWVersion + ")")

	if p.DeployRime { // install.sh 575-612
		log("部署 rime 词库 (整句输入)...")
		if err := c.RunScript(ctx, scripts.RimeSetup, nil); err != nil {
			return fmt.Errorf("rime 词库部署失败: %w", err)
		}
	}

	// install.sh 614-855: 设备端六阶段防砖部署
	log("配置系统服务 + 编译 + 启动 (设备端六阶段)...")
	env := map[string]string{
		"FW_VERSION":          p.FWVersion,
		"ZZ_HEADER_FLAT":      strings.ReplaceAll(p.zzHeader, "\n", `\n`),
		"QML_INJECT_DEPLOYED": boolStr(p.QMLInject),
	}
	if err := c.RunScript(ctx, scripts.DeployStages, env); err != nil {
		return fmt.Errorf("设备端部署失败 (已按 abort_safe 回退到出厂启动): %w", err)
	}
	return nil
}

// Uninstall 执行 install.sh --uninstall 的设备端脚本。
func Uninstall(ctx context.Context, c *sshx.Client) error {
	return c.RunScript(ctx, scripts.Uninstall, nil)
}

// writeTar 按 install.sh 547 的方式打包: uid/gid 0, 路径以 ./ 开头, gzip。
func writeTar(w io.Writer, b *bundle.Bundle, files []FileEntry) error {
	gz := gzip.NewWriter(w)
	tw := tar.NewWriter(gz)
	dirs := map[string]bool{}
	now := time.Now()
	for _, f := range files {
		dir := path.Dir(f.Device)
		var chain []string
		for d := dir; d != "/" && !dirs[d]; d = path.Dir(d) {
			chain = append([]string{d}, chain...)
		}
		for _, d := range chain {
			dirs[d] = true
			if err := tw.WriteHeader(&tar.Header{Typeflag: tar.TypeDir, Name: "." + d + "/", Mode: 0o755, ModTime: now}); err != nil {
				return err
			}
		}
		if err := tw.WriteHeader(&tar.Header{Typeflag: tar.TypeReg, Name: "." + f.Device, Mode: f.Mode, Size: f.Size, ModTime: now}); err != nil {
			return err
		}
		rc, err := b.Open(f.Source)
		if err != nil {
			return err
		}
		n, err := io.Copy(tw, rc)
		_ = rc.Close()
		if err != nil {
			return fmt.Errorf("打包 %s: %w", f.Source, err)
		}
		if n != f.Size {
			return fmt.Errorf("打包 %s: 大小 %d 与清单 %d 不符", f.Source, n, f.Size)
		}
	}
	if err := tw.Close(); err != nil {
		return err
	}
	return gz.Close()
}

func boolStr(b bool) string {
	if b {
		return "1"
	}
	return "0"
}

// FWNumber 把 /etc/version 转成可比较的整数 (非数字返回 0)。
func FWNumber(fw string) int64 {
	n, _ := strconv.ParseInt(strings.TrimSpace(fw), 10, 64)
	return n
}
