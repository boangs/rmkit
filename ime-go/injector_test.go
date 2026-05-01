package ime

import (
	"testing"

	"github.com/holoplot/go-evdev"
)

func TestMockInjectChar(t *testing.T) {
	inj := NewMockInjector()
	_ = inj.InjectChar('你')
	if len(inj.Log) != 1 {
		t.Fatalf("expected 1 log entry, got %d", len(inj.Log))
	}
	if inj.Log[0].Type != "char" || inj.Log[0].Val != "你" {
		t.Errorf("expected char 你, got %s %s", inj.Log[0].Type, inj.Log[0].Val)
	}
}

func TestMockInjectKey(t *testing.T) {
	inj := NewMockInjector()
	_ = inj.InjectKey(evdev.KEY_ENTER)
	if len(inj.Log) != 1 {
		t.Fatalf("expected 1 log entry, got %d", len(inj.Log))
	}
	if inj.Log[0].Type != "key" {
		t.Errorf("expected key type, got %s", inj.Log[0].Type)
	}
}

func TestMockInjectMultiple(t *testing.T) {
	inj := NewMockInjector()
	_ = inj.InjectChar('你')
	_ = inj.InjectChar('好')
	_ = inj.InjectKey(evdev.KEY_SPACE)
	if len(inj.Log) != 3 {
		t.Errorf("expected 3 log entries, got %d", len(inj.Log))
	}
}

func TestMockInjectClose(t *testing.T) {
	inj := NewMockInjector()
	if err := inj.Close(); err != nil {
		t.Errorf("close failed: %v", err)
	}
}
