package ime

import (
	"fmt"

	"github.com/holoplot/go-evdev"
)

// Injector 字符注入接口
type Injector interface {
	InjectChar(char rune) error
	InjectKey(code evdev.EvCode) error
	Close() error
}

// UinputInjector 通过 uinput 注入字符
type UinputInjector struct {
	ui *evdev.InputDevice
}

func NewUinputInjector() (*UinputInjector, error) {
	caps := map[evdev.EvType][]evdev.EvCode{
		evdev.EV_KEY: {
			evdev.KEY_0, evdev.KEY_1, evdev.KEY_2, evdev.KEY_3, evdev.KEY_4,
			evdev.KEY_5, evdev.KEY_6, evdev.KEY_7, evdev.KEY_8, evdev.KEY_9,
			evdev.KEY_A, evdev.KEY_B, evdev.KEY_C, evdev.KEY_D, evdev.KEY_E,
			evdev.KEY_F, evdev.KEY_G, evdev.KEY_H, evdev.KEY_I, evdev.KEY_J,
			evdev.KEY_K, evdev.KEY_L, evdev.KEY_M, evdev.KEY_N, evdev.KEY_O,
			evdev.KEY_P, evdev.KEY_Q, evdev.KEY_R, evdev.KEY_S, evdev.KEY_T,
			evdev.KEY_U, evdev.KEY_V, evdev.KEY_W, evdev.KEY_X, evdev.KEY_Y,
			evdev.KEY_Z, evdev.KEY_ENTER, evdev.KEY_LEFTCTRL, evdev.KEY_LEFTSHIFT,
			evdev.KEY_SPACE, evdev.KEY_BACKSPACE,
		},
	}
	ui, err := evdev.CreateDevice("rmkit-cn-ime", evdev.InputID{
		BusType: 0x03, // BUS_USB
	}, caps)
	if err != nil {
		return nil, fmt.Errorf("create uinput: %w", err)
	}
	return &UinputInjector{ui: ui}, nil
}

func (u *UinputInjector) InjectChar(char rune) error {
	hexStr := fmt.Sprintf("%x", char)

	// Ctrl+Shift 按下
	if err := u.writeKey(evdev.KEY_LEFTCTRL, 1); err != nil {
		return err
	}
	if err := u.writeKey(evdev.KEY_LEFTSHIFT, 1); err != nil {
		return err
	}
	// U
	if err := u.pressKey(evdev.KEY_U); err != nil {
		return err
	}
	// 释放 Shift+Ctrl
	if err := u.writeKey(evdev.KEY_LEFTSHIFT, 0); err != nil {
		return err
	}
	if err := u.writeKey(evdev.KEY_LEFTCTRL, 0); err != nil {
		return err
	}

	// 十六进制数字
	hexKeyMap := map[byte]evdev.EvCode{
		'0': evdev.KEY_0, '1': evdev.KEY_1, '2': evdev.KEY_2,
		'3': evdev.KEY_3, '4': evdev.KEY_4, '5': evdev.KEY_5,
		'6': evdev.KEY_6, '7': evdev.KEY_7, '8': evdev.KEY_8,
		'9': evdev.KEY_9, 'a': evdev.KEY_A, 'b': evdev.KEY_B,
		'c': evdev.KEY_C, 'd': evdev.KEY_D, 'e': evdev.KEY_E,
		'f': evdev.KEY_F,
	}
	for _, b := range []byte(hexStr) {
		if key, ok := hexKeyMap[b]; ok {
			if err := u.pressKey(key); err != nil {
				return err
			}
		}
	}

	return u.pressKey(evdev.KEY_ENTER)
}

func (u *UinputInjector) InjectKey(code evdev.EvCode) error {
	return u.pressKey(code)
}

func (u *UinputInjector) Close() error {
	return evdev.DestroyDevice(u.ui)
}

func (u *UinputInjector) pressKey(code evdev.EvCode) error {
	if err := u.writeKey(code, 1); err != nil {
		return err
	}
	return u.writeKey(code, 0)
}

func (u *UinputInjector) writeKey(code evdev.EvCode, value int32) error {
	return u.ui.WriteOne(&evdev.InputEvent{
		Type:  evdev.EV_KEY,
		Code:  code,
		Value: value,
	})
}

// MockInjector 测试用 Mock 注入器
type MockInjector struct {
	Log []InjectLogEntry
}

type InjectLogEntry struct {
	Type string // "char" or "key"
	Val  string
}

func NewMockInjector() *MockInjector {
	return &MockInjector{}
}

func (m *MockInjector) InjectChar(char rune) error {
	m.Log = append(m.Log, InjectLogEntry{Type: "char", Val: string(char)})
	return nil
}

func (m *MockInjector) InjectKey(code evdev.EvCode) error {
	m.Log = append(m.Log, InjectLogEntry{Type: "key", Val: fmt.Sprintf("%d", code)})
	return nil
}

func (m *MockInjector) Close() error {
	return nil
}
