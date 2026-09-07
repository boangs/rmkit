// Package probe 只读地探测 reMarkable 的型号/固件/槽位/空间/已装组件。
// 它刻意只读系统信息文件, 不进入 /home/root/.local/share/remarkable (用户文档)。
package probe

import (
	"context"
	"strconv"
	"strings"

	"github.com/rmkit-cn/desktop/internal/sshx"
)

// Info 是一次探测的结果, 直接给前端展示与预检使用。
type Info struct {
	Arch       string `json:"arch"`       // aarch64 / armv7l
	FWVersion  string `json:"fwVersion"`  // /etc/version, 如 20260806095513
	Resolution string `json:"resolution"` // fb0 virtual_size
	Model      string `json:"model"`      // 人类可读
	ModelKey   string `json:"modelKey"`   // rm2 / rmpp / rmppm / unknown

	ActiveSlot string `json:"activeSlot"` // /dev/mmcblk0p2 等 (rm2 没有 → 空)
	NextBoot   string `json:"nextBoot"`
	ErrcntA    int    `json:"errcntA"`
	ErrcntB    int    `json:"errcntB"`
	Secboot    string `json:"secboot"` // unlocked / locked / 空 (非 i.MX93)

	RootFreeMB int `json:"rootFreeMB"`
	HomeFreeMB int `json:"homeFreeMB"`

	HaveXovi       bool   `json:"haveXovi"`
	RmkitInstalled bool   `json:"rmkitInstalled"`
	RmkitFW        string `json:"rmkitFW"` // rmkit-cn 上次安装时记录的固件版本
	XochitlActive  bool   `json:"xochitlActive"`

	InAndroidMode    bool `json:"inAndroidMode"`    // 当前是 Android 模式 (dropbear 应答)
	AndroidInstalled bool `json:"androidInstalled"` // 本槽已有单槽 Android 组件
	InitIsWrapper    bool `json:"initIsWrapper"`
}

// 单次往返拿齐所有字段, 每行 key=value。
const probeScript = `
echo arch=$(uname -m)
echo fw=$(cat /etc/version 2>/dev/null | head -n 1 | tr -d '[:space:]')
echo dtmodel=$(tr -d '\0' < /proc/device-tree/model 2>/dev/null)
echo res=$(cat /sys/class/graphics/fb0/virtual_size 2>/dev/null)
echo slot=$(rootdev 2>/dev/null)
echo next=$(rootdev --next-boot 2>/dev/null)
echo erra=$(cat /sys/devices/platform/lpgpr/roota_errcnt 2>/dev/null)
echo errb=$(cat /sys/devices/platform/lpgpr/rootb_errcnt 2>/dev/null)
echo secboot=$(cat /sys/devices/platform/lpgpr/secboot 2>/dev/null)
echo rootfree=$(df -kP / 2>/dev/null | awk 'END{print $4}')
echo homefree=$(df -kP /home 2>/dev/null | awk 'END{print $4}')
[ -f /home/root/xovi/xovi.so ] && echo xovi=1
[ -d /home/root/rmkit-cn/bin ] && echo rmkit=1
echo rmkitfw=$(cat /home/root/rmkit-cn/.last_fw_version 2>/dev/null)
[ "$(cat /proc/1/comm 2>/dev/null)" = "systemd" ] && systemctl is-active xochitl >/dev/null 2>&1 && echo xochitl=1
[ -d /android ] && [ "$(cat /proc/1/comm 2>/dev/null)" != "systemd" ] && echo androidmode=1
grep -q boot-android-mode /sbin/init 2>/dev/null && echo initwrap=1
[ -f /boot/fitImage.ahab-android ] && [ -x /usr/bin/rm-android-init-ss ] && echo android=1
`

// Run 探测设备。
func Run(ctx context.Context, c *sshx.Client) (Info, error) {
	res, err := c.Run(ctx, probeScript)
	if err != nil {
		return Info{}, err
	}
	kv := map[string]string{}
	for _, line := range strings.Split(res.Stdout, "\n") {
		k, v, ok := strings.Cut(strings.TrimSpace(line), "=")
		if ok {
			kv[k] = strings.TrimSpace(v)
		}
	}
	info := Info{
		Arch:             kv["arch"],
		FWVersion:        kv["fw"],
		Resolution:       kv["res"],
		ActiveSlot:       kv["slot"],
		NextBoot:         kv["next"],
		ErrcntA:          atoi(kv["erra"]),
		ErrcntB:          atoi(kv["errb"]),
		Secboot:          kv["secboot"],
		RootFreeMB:       atoi(kv["rootfree"]) / 1024,
		HomeFreeMB:       atoi(kv["homefree"]) / 1024,
		HaveXovi:         kv["xovi"] == "1",
		RmkitInstalled:   kv["rmkit"] == "1",
		RmkitFW:          kv["rmkitfw"],
		XochitlActive:    kv["xochitl"] == "1",
		InAndroidMode:    kv["androidmode"] == "1",
		AndroidInstalled: kv["android"] == "1",
		InitIsWrapper:    kv["initwrap"] == "1",
	}
	info.ModelKey, info.Model = classify(kv["dtmodel"], info.Resolution, info.Arch)
	if info.Resolution == "" {
		info.Resolution = kv["dtmodel"]
	}
	return info, nil
}

// classify 优先按设备树型号 (3.28 起 /sys/class/graphics/fb0 不再存在), 再按分辨率
// (与 installer/install.sh 一致), 最后按架构兜底。
func classify(dtModel, res, arch string) (string, string) {
	switch {
	case strings.Contains(dtModel, "Chiappa"):
		return "rmppm", "reMarkable Paper Pro Move"
	case strings.Contains(dtModel, "Ferrari"):
		return "rmpp", "reMarkable Paper Pro"
	case strings.Contains(dtModel, "reMarkable 2"):
		return "rm2", "reMarkable 2"
	}
	switch res {
	case "1404,1872":
		return "rm2", "reMarkable 2"
	case "2160,2880":
		return "rmpp", "reMarkable Paper Pro"
	case "1696,954":
		return "rmppm", "reMarkable Paper Pro Move"
	}
	if arch == "armv7l" {
		return "unknown", "未知型号 (armv7l, " + res + ")"
	}
	return "unknown", "未知型号 (" + res + ")"
}

func atoi(s string) int {
	n, _ := strconv.Atoi(strings.TrimSpace(s))
	return n
}
