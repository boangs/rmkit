package ime

import (
	"io"
	"testing"

	"github.com/holoplot/go-evdev"
)

func TestMockKeyboardPushAndRead(t *testing.T) {
	kb := NewMockKeyboard(
		KeyEvent{Code: evdev.KEY_A, Action: KeyPress},
		KeyEvent{Code: evdev.KEY_B, Action: KeyPress},
	)
	ev, err := kb.ReadEvent()
	if err != nil {
		t.Fatal(err)
	}
	if ev.Code != evdev.KEY_A {
		t.Errorf("expected KEY_A, got %d", ev.Code)
	}
	ev, err = kb.ReadEvent()
	if err != nil {
		t.Fatal(err)
	}
	if ev.Code != evdev.KEY_B {
		t.Errorf("expected KEY_B, got %d", ev.Code)
	}
}

func TestMockKeyboardEmptyRead(t *testing.T) {
	kb := NewMockKeyboard()
	_, err := kb.ReadEvent()
	if err != io.EOF {
		t.Errorf("expected EOF, got %v", err)
	}
}

func TestMockKeyboardClose(t *testing.T) {
	kb := NewMockKeyboard()
	if err := kb.Close(); err != nil {
		t.Errorf("close failed: %v", err)
	}
}
