package ime

import (
	"testing"

	"github.com/holoplot/go-evdev"
	"github.com/rmkit-cn/ime/pinyin"
)

// 辅助：构造按键按下事件
func pressKey(code evdev.EvCode) KeyEvent {
	return KeyEvent{Code: code, Action: KeyPress}
}

func pressKeyRelease(code evdev.EvCode) KeyEvent {
	return KeyEvent{Code: code, Action: KeyRelease}
}

func TestTypePinyinAndSelect(t *testing.T) {
	kb := NewMockKeyboard(
		pressKey(evdev.KEY_N),
		pressKey(evdev.KEY_I),
		pressKey(evdev.KEY_1),
	)
	inj := NewMockInjector()
	ov := NewMockOverlay()
	engine := pinyin.NewEngine()
	session := NewSession(kb, engine, ov, inj)

	_ = session.Run()

	if len(inj.Log) == 0 || inj.Log[len(inj.Log)-1].Type != "char" {
		t.Fatal("expected char injection")
	}
	if inj.Log[len(inj.Log)-1].Val != "你" {
		t.Errorf("expected '你', got '%s'", inj.Log[len(inj.Log)-1].Val)
	}
	if !ov.Cleared {
		t.Error("overlay should be cleared after selection")
	}
}

func TestTypeAndSpaceSelect(t *testing.T) {
	kb := NewMockKeyboard(
		pressKey(evdev.KEY_H),
		pressKey(evdev.KEY_A),
		pressKey(evdev.KEY_O),
		pressKey(evdev.KEY_SPACE),
	)
	inj := NewMockInjector()
	ov := NewMockOverlay()
	engine := pinyin.NewEngine()
	session := NewSession(kb, engine, ov, inj)

	_ = session.Run()

	if len(inj.Log) == 0 || inj.Log[len(inj.Log)-1].Val != "好" {
		t.Errorf("expected '好', got log: %v", inj.Log)
	}
}

func TestBackspaceInBuffer(t *testing.T) {
	kb := NewMockKeyboard(
		pressKey(evdev.KEY_N),
		pressKey(evdev.KEY_I),
		pressKey(evdev.KEY_BACKSPACE),
	)
	inj := NewMockInjector()
	ov := NewMockOverlay()
	engine := pinyin.NewEngine()
	session := NewSession(kb, engine, ov, inj)

	_ = session.Run()

	if engine.Buffer() != "n" {
		t.Errorf("expected buffer 'n', got '%s'", engine.Buffer())
	}
}

func TestBackspaceEmptyPassesThrough(t *testing.T) {
	kb := NewMockKeyboard(
		pressKey(evdev.KEY_BACKSPACE),
	)
	inj := NewMockInjector()
	ov := NewMockOverlay()
	engine := pinyin.NewEngine()
	session := NewSession(kb, engine, ov, inj)

	_ = session.Run()

	hasKey := false
	for _, entry := range inj.Log {
		if entry.Type == "key" {
			hasKey = true
		}
	}
	if !hasKey {
		t.Error("expected key passthrough for backspace when buffer empty")
	}
}

func TestEnterWithoutCandidates(t *testing.T) {
	kb := NewMockKeyboard(
		pressKey(evdev.KEY_ENTER),
	)
	inj := NewMockInjector()
	ov := NewMockOverlay()
	engine := pinyin.NewEngine()
	session := NewSession(kb, engine, ov, inj)

	_ = session.Run()

	hasKey := false
	for _, entry := range inj.Log {
		if entry.Type == "key" {
			hasKey = true
		}
	}
	if !hasKey {
		t.Error("expected key passthrough for enter without candidates")
	}
}

func TestSelectSecondCandidate(t *testing.T) {
	kb := NewMockKeyboard(
		pressKey(evdev.KEY_N),
		pressKey(evdev.KEY_I),
		pressKey(evdev.KEY_2),
	)
	inj := NewMockInjector()
	ov := NewMockOverlay()
	engine := pinyin.NewEngine()
	session := NewSession(kb, engine, ov, inj)

	_ = session.Run()

	probe := pinyin.NewEngine()
	probe.Append('n')
	probe.Append('i')
	cands := probe.Candidates()
	if len(cands) < 2 {
		t.Fatalf("expected at least 2 candidates for 'ni', got %v", cands)
	}
	if len(inj.Log) == 0 || inj.Log[len(inj.Log)-1].Val != cands[1] {
		t.Errorf("expected second candidate %q, got log: %v", cands[1], inj.Log)
	}
}

func TestReleaseEventsIgnored(t *testing.T) {
	kb := NewMockKeyboard(
		pressKeyRelease(evdev.KEY_A),
	)
	inj := NewMockInjector()
	ov := NewMockOverlay()
	engine := pinyin.NewEngine()
	session := NewSession(kb, engine, ov, inj)

	_ = session.Run()

	if len(inj.Log) != 0 {
		t.Errorf("expected no injections for release event, got %v", inj.Log)
	}
	if engine.Buffer() != "" {
		t.Errorf("expected empty buffer, got '%s'", engine.Buffer())
	}
}

func TestOverlayShowsCandidates(t *testing.T) {
	kb := NewMockKeyboard(
		pressKey(evdev.KEY_N),
		pressKey(evdev.KEY_I),
	)
	inj := NewMockInjector()
	ov := NewMockOverlay()
	engine := pinyin.NewEngine()
	session := NewSession(kb, engine, ov, inj)

	_ = session.Run()

	if ov.LastPinyin != "ni" {
		t.Errorf("expected 'ni', got '%s'", ov.LastPinyin)
	}
	if len(ov.LastCandidates) == 0 {
		t.Error("expected candidates to be shown")
	}
}
