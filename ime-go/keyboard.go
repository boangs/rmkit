package ime

import (
	"io"

	"github.com/holoplot/go-evdev"
)

// KeyAction 键盘动作类型
type KeyAction int

const (
	KeyRelease KeyAction = iota
	KeyPress
	KeyHold
)

// KeyEvent 键盘事件
type KeyEvent struct {
	Code   evdev.EvCode
	Action KeyAction
}

// Keyboard 键盘设备接口
type Keyboard interface {
	ReadEvent() (KeyEvent, error)
	Close() error
}

// EvdevKeyboard 通过 evdev 读取真实键盘设备
type EvdevKeyboard struct {
	device *evdev.InputDevice
}

func NewEvdevKeyboard(devicePath string) (*EvdevKeyboard, error) {
	dev, err := evdev.Open(devicePath)
	if err != nil {
		return nil, err
	}
	return &EvdevKeyboard{device: dev}, nil
}

func (k *EvdevKeyboard) ReadEvent() (KeyEvent, error) {
	for {
		ev, err := k.device.ReadOne()
		if err != nil {
			return KeyEvent{}, err
		}
		if ev.Type == evdev.EV_KEY {
			var action KeyAction
			switch ev.Value {
			case 0:
				action = KeyRelease
			case 1:
				action = KeyPress
			case 2:
				action = KeyHold
			default:
				continue
			}
			return KeyEvent{Code: ev.Code, Action: action}, nil
		}
	}
}

func (k *EvdevKeyboard) Close() error {
	return k.device.Close()
}

// MockKeyboard 测试用 Mock 键盘
type MockKeyboard struct {
	events []KeyEvent
	pos    int
}

func NewMockKeyboard(events ...KeyEvent) *MockKeyboard {
	return &MockKeyboard{events: events}
}

func (m *MockKeyboard) PushEvent(e KeyEvent) {
	m.events = append(m.events, e)
}

func (m *MockKeyboard) ReadEvent() (KeyEvent, error) {
	if m.pos >= len(m.events) {
		return KeyEvent{}, io.EOF
	}
	ev := m.events[m.pos]
	m.pos++
	return ev, nil
}

func (m *MockKeyboard) Close() error {
	return nil
}
