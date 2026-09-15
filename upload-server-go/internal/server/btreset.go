//go:build linux

// 蓝牙控制器硬复位: RMPPM (chiappa) 的 NXP IW612 蓝牙走串口 (btnxpuart), 实测 `bluetoothctl power off/on`
// 之后控制器会卡死 (内核 "hci0: command tx timeout", 重载驱动报 "FW already running" 且 HCI Reset 超时),
// 之后什么都连不上。设备树里蓝牙节点有独立的 reset-gpios (gpiochip2 线 6, 低有效; Wi-Fi 的复位在线 15,
// 互不影响), 拉一下再重载 btnxpuart 就活了, 不用整机重启。
// 用 GPIO 字符设备 uAPI v2 (设备上没有 sysfs gpio, 也没有 gpioset)。
package server

import (
	"errors"
	"fmt"
	"log"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"time"
	"unsafe"

	"golang.org/x/sys/unix"
)

const (
	btResetChip = "/dev/gpiochip2"
	btResetLine = 6
	btWakeLine  = 9 // device-wakeup-gpios
	btDTNode    = "/sys/firmware/devicetree/base/soc@0/bus@42000000/serial@42570000/bluetooth/reset-gpios"
)

// gpio uAPI v2 结构 (linux/gpio.h)
type gpioV2LineConfig struct {
	Flags    uint64
	NumAttrs uint32
	_        [5]uint32
	Attrs    [10][3]uint64 // 未用, 占位对齐 (每个 attr 24 字节)
}

type gpioV2LineRequest struct {
	Offsets      [64]uint32
	Consumer     [32]byte
	Config       gpioV2LineConfig
	NumLines     uint32
	EventBufSize uint32
	_            [5]uint32
	Fd           int32
}

type gpioV2LineValues struct {
	Bits uint64
	Mask uint64
}

const (
	gpioV2LineFlagOutput    = 1 << 3     // GPIO_V2_LINE_FLAG_OUTPUT (1<<2 是 INPUT)
	gpioV2GetLineIoctl      = 0xc250b407 // _IOWR(0xB4, 0x07, struct gpio_v2_line_request)
	gpioV2LineSetValuesIoct = 0xc010b40f // _IOWR(0xB4, 0x0F, struct gpio_v2_line_values)
	gpioV2LineGetValuesIoct = 0xc010b40e // _IOWR(0xB4, 0x0E, struct gpio_v2_line_values)
)

// btResetSupported 只在设备树确实声明了蓝牙 reset-gpios 时才允许硬复位 (rm2 / ferrari 没有)。
func btResetSupported() bool {
	b, err := os.ReadFile(btDTNode)
	if err != nil || len(b) < 12 {
		return false
	}
	// <phandle line flags>: 线号在第 2 个 cell
	line := uint32(b[4])<<24 | uint32(b[5])<<16 | uint32(b[6])<<8 | uint32(b[7])
	return line == btResetLine
}

// btPulseReset 拉低复位脚 300ms 再放开 (线是低有效, 由 DT flags=1 得知)。
func btPulseReset() error {
	return btPulseLine(btResetLine, 0, 300*time.Millisecond, 1)
}

// btPulseWake 抖一下 device-wakeup 线 (线 9, 高有效): 芯片被 `power off` 带进休眠后只认这根线。
func btPulseWake() error {
	if err := btPulseLine(btWakeLine, 1, 200*time.Millisecond, 0); err != nil {
		return err
	}
	return btPulseLine(btWakeLine, 1, 200*time.Millisecond, 1)
}

func btPulseLine(line uint32, active uint64, hold time.Duration, rest uint64) error {
	f, err := os.OpenFile(btResetChip, os.O_RDWR, 0)
	if err != nil {
		return err
	}
	defer f.Close()
	var req gpioV2LineRequest
	req.Offsets[0] = line
	copy(req.Consumer[:], "rmkit-bt-reset")
	req.Config.Flags = gpioV2LineFlagOutput
	req.NumLines = 1
	if _, _, e := unix.Syscall(unix.SYS_IOCTL, f.Fd(), uintptr(gpioV2GetLineIoctl), uintptr(unsafe.Pointer(&req))); e != 0 {
		return fmt.Errorf("GPIO_V2_GET_LINE 线 %d: %v (占用者: %q)", line, e, gpioLineConsumer(f, line))
	}
	lf := os.NewFile(uintptr(req.Fd), "bt-reset-line")
	defer lf.Close()
	set := func(v uint64) error {
		vals := gpioV2LineValues{Bits: v, Mask: 1}
		if _, _, e := unix.Syscall(unix.SYS_IOCTL, lf.Fd(), uintptr(gpioV2LineSetValuesIoct), uintptr(unsafe.Pointer(&vals))); e != 0 {
			return fmt.Errorf("GPIO_V2_LINE_SET_VALUES: %v", e)
		}
		return nil
	}
	get := func() string {
		vals := gpioV2LineValues{Mask: 1}
		if _, _, e := unix.Syscall(unix.SYS_IOCTL, lf.Fd(), uintptr(gpioV2LineGetValuesIoct), uintptr(unsafe.Pointer(&vals))); e != 0 {
			return "?"
		}
		return fmt.Sprint(vals.Bits & 1)
	}
	before := get()
	if err := set(active); err != nil {
		return err
	}
	time.Sleep(hold)
	mid := get()
	if err := set(rest); err != nil {
		return err
	}
	log.Printf("bt reset: 线 %d: %s -> %s -> %s", line, before, mid, get())
	return nil
}

// btHardReset 硬复位控制器并重载驱动, 然后等 hci0 回来并上电。
func btHardReset() error {
	if !btResetSupported() {
		return errors.New("这台机器的设备树没有蓝牙复位脚, 只能重启设备")
	}
	_ = exec.Command("rmmod", "btnxpuart").Run()
	time.Sleep(300 * time.Millisecond)
	// 复位脚被内核 reset-gpio 复位控制器 (6.9+ 由 reset 核心按 reset-gpios 自动实例化, 消费者名 "reset") 常驻占着,
	// 驱动卸了也不放; 逐个解绑 reset-gpio.N 找到放开线 6 的那个, 脉冲后再绑回去。
	pulsed := false
	devs, _ := filepath.Glob("/sys/bus/platform/devices/reset-gpio.*")
	for _, d := range devs {
		name := filepath.Base(d)
		if err := os.WriteFile("/sys/bus/platform/drivers/reset-gpio/unbind", []byte(name), 0o200); err != nil {
			continue
		}
		time.Sleep(100 * time.Millisecond)
		err := btPulseReset()
		_ = os.WriteFile("/sys/bus/platform/drivers/reset-gpio/bind", []byte(name), 0o200)
		if err == nil {
			log.Printf("bt reset: 通过解绑 %s 拉了复位脚", name)
			pulsed = true
			break
		}
		log.Printf("bt reset: 解绑 %s 后仍拿不到线: %v", name, err)
	}
	if !pulsed {
		if err := btPulseReset(); err != nil {
			return err
		}
	}
	if err := btPulseWake(); err != nil {
		log.Printf("bt reset: 唤醒线不可用: %v", err)
	}
	time.Sleep(2 * time.Second)
	log.Printf("bt reset: 复位/唤醒脚已脉冲, 重载 btnxpuart")
	if out, err := exec.Command("modprobe", "btnxpuart").CombinedOutput(); err != nil {
		return fmt.Errorf("modprobe btnxpuart: %v %s", err, strings.TrimSpace(string(out)))
	}
	for i := 0; i < 40; i++ {
		if _, err := os.Stat("/sys/class/bluetooth/hci0"); err == nil {
			break
		}
		time.Sleep(250 * time.Millisecond)
	}
	time.Sleep(1500 * time.Millisecond)
	_ = exec.Command("rfkill", "unblock", "bluetooth").Run()
	out, _ := btctl(10*time.Second, "power", "on")
	if !strings.Contains(out, "succeeded") {
		return errors.New("复位后仍上不了电: " + lastLine(out))
	}
	return nil
}

// btControllerWedged 判断控制器是否卡死: 上电命令没成功, 或最近内核日志有 tx timeout。
func btControllerWedged() bool {
	show, _ := btctl(8*time.Second, "show")
	if strings.Contains(show, "Powered: yes") {
		return false
	}
	if strings.Contains(show, "No default controller") {
		return true
	}
	out, _ := btctl(8*time.Second, "power", "on")
	if strings.Contains(out, "succeeded") {
		return false
	}
	dm, _ := exec.Command("dmesg").Output()
	lines := strings.Split(string(dm), "\n")
	if len(lines) > 30 {
		lines = lines[len(lines)-30:]
	}
	return strings.Contains(strings.Join(lines, "\n"), "hci0: command tx timeout")
}

// gpioV2LineInfo 对应 struct gpio_v2_line_info (256 字节)。
type gpioV2LineInfo struct {
	Name     [32]byte
	Consumer [32]byte
	Offset   uint32
	NumAttrs uint32
	Flags    uint64
	Attrs    [10][2]uint64
	_        [4]uint32
}

const gpioV2GetLineInfoIoctl = 0xc100b405 // _IOWR(0xB4, 0x05, struct gpio_v2_line_info)

// gpioLineConsumer 返回某条线当前的内核/用户态占用者名字 (排障用)。
func gpioLineConsumer(chip *os.File, line uint32) string {
	var info gpioV2LineInfo
	info.Offset = line
	if _, _, e := unix.Syscall(unix.SYS_IOCTL, chip.Fd(), uintptr(gpioV2GetLineInfoIoctl), uintptr(unsafe.Pointer(&info))); e != 0 {
		return "?" + e.Error()
	}
	c := strings.TrimRight(string(info.Consumer[:]), "\x00")
	return fmt.Sprintf("%s used=%v flags=%#x", c, info.Flags&1 != 0, info.Flags)
}

// btWakeChip 芯片进省电后叫不醒时的抢救: 卸驱动 → 手工抖唤醒线 → 重载。实验性, 面板不暴露。
func btWakeChip() error {
	_ = exec.Command("rmmod", "btnxpuart").Run()
	time.Sleep(300 * time.Millisecond)
	for i := 0; i < 3; i++ {
		if err := btPulseLine(btWakeLine, 1, 500*time.Millisecond, 0); err != nil {
			return err
		}
		time.Sleep(200 * time.Millisecond)
	}
	if err := btPulseLine(btWakeLine, 1, 200*time.Millisecond, 1); err != nil {
		return err
	}
	time.Sleep(500 * time.Millisecond)
	if out, err := exec.Command("modprobe", "btnxpuart").CombinedOutput(); err != nil {
		return fmt.Errorf("modprobe: %v %s", err, out)
	}
	time.Sleep(4 * time.Second)
	out, _ := btctl(10*time.Second, "power", "on")
	if !strings.Contains(out, "succeeded") {
		return errors.New("仍无响应: " + lastLine(out))
	}
	return nil
}
