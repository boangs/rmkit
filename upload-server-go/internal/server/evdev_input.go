//go:build linux

package server

import (
	"fmt"
	"os"
	"time"
	"unsafe"

	"golang.org/x/sys/unix"
)

const (
	uinputPath   = "/dev/uinput"
	uiDevCreate  = 0x5501
	uiDevDestroy = 0x5502
	uiSetEvBit   = 0x40045564
	uiSetKeyBit  = 0x40045565
	evKey        = 0x01
	evSync       = 0x00
	keyEsc       = 1
)

type uinputUserDev struct {
	Name         [80]byte
	ID           [8]byte
	FFEffectsMax uint32
	Absmax       [64]int32
	Absmin       [64]int32
	Absfuzz      [64]int32
	Absflat      [64]int32
}

type inputEvent struct {
	Sec   int64
	Usec  int64
	Type  uint16
	Code  uint16
	Value int32
}

func openUinput() (*os.File, error) {
	f, err := os.OpenFile(uinputPath, os.O_WRONLY, 0)
	if err != nil {
		return nil, fmt.Errorf("open uinput: %w", err)
	}
	if _, _, errno := unix.Syscall(unix.SYS_IOCTL, f.Fd(), uiSetEvBit, uintptr(evKey)); errno != 0 {
		f.Close()
		return nil, fmt.Errorf("UI_SET_EVBIT: %v", errno)
	}
	if _, _, errno := unix.Syscall(unix.SYS_IOCTL, f.Fd(), uiSetKeyBit, uintptr(keyEsc)); errno != 0 {
		f.Close()
		return nil, fmt.Errorf("UI_SET_KEYBIT: %v", errno)
	}
	var dev uinputUserDev
	copy(dev.Name[:], "rmkit-ai-kb")
	devBytes := (*[unsafe.Sizeof(dev)]byte)(unsafe.Pointer(&dev))[:]
	if _, err := f.Write(devBytes); err != nil {
		f.Close()
		return nil, fmt.Errorf("write dev: %w", err)
	}
	if _, _, errno := unix.Syscall(unix.SYS_IOCTL, f.Fd(), uiDevCreate, 0); errno != 0 {
		f.Close()
		return nil, fmt.Errorf("UI_DEV_CREATE: %v", errno)
	}
	time.Sleep(100 * time.Millisecond)
	return f, nil
}

func sendKey(f *os.File, code uint16) error {
	evs := []inputEvent{
		{Type: evKey, Code: code, Value: 1},
		{Type: evSync},
		{Type: evKey, Code: code, Value: 0},
		{Type: evSync},
	}
	for _, ev := range evs {
		b := (*[unsafe.Sizeof(ev)]byte)(unsafe.Pointer(&ev))[:]
		if _, err := f.Write(b); err != nil {
			return err
		}
	}
	return nil
}

// SendEsc: 发 ESC 清除选区（不发 Enter，避免关闭记事本）
func SendEsc() error {
	f, err := openUinput()
	if err != nil {
		return err
	}
	defer func() {
		unix.Syscall(unix.SYS_IOCTL, f.Fd(), uiDevDestroy, 0)
		f.Close()
	}()
	if err := sendKey(f, keyEsc); err != nil {
		return fmt.Errorf("ESC: %w", err)
	}
	time.Sleep(200 * time.Millisecond)
	return nil
}
