package pinyin

import (
	"testing"
)

func TestSingleChar(t *testing.T) {
	e := NewEngine()
	e.Append('n')
	if e.Buffer() != "n" {
		t.Errorf("expected buffer 'n', got '%s'", e.Buffer())
	}
}

func TestTwoChars(t *testing.T) {
	e := NewEngine()
	e.Append('n')
	e.Append('i')
	cands := e.Candidates()
	if len(cands) == 0 {
		t.Fatal("expected candidates for 'ni'")
	}
	if cands[0] != "你" {
		t.Errorf("expected first candidate '你', got '%s'", cands[0])
	}
}

func TestEmptyInput(t *testing.T) {
	e := NewEngine()
	cands := e.Candidates()
	if len(cands) != 0 {
		t.Errorf("expected no candidates for empty buffer, got %v", cands)
	}
}

func TestInvalidInput(t *testing.T) {
	e := NewEngine()
	e.Append('1')
	if e.Buffer() != "" {
		t.Errorf("expected empty buffer for digit input, got '%s'", e.Buffer())
	}
}

func TestMaxCandidates(t *testing.T) {
	e := NewEngine()
	e.Append('n')
	e.Append('i')
	cands := e.Candidates()
	if len(cands) > MaxCandidates {
		t.Errorf("expected at most %d candidates, got %d", MaxCandidates, len(cands))
	}
}

func TestClearBuffer(t *testing.T) {
	e := NewEngine()
	e.Append('n')
	e.Clear()
	if e.Buffer() != "" {
		t.Errorf("expected empty buffer after clear, got '%s'", e.Buffer())
	}
}

func TestAppendAndBackspace(t *testing.T) {
	e := NewEngine()
	e.Append('n')
	e.Append('i')
	e.Backspace()
	if e.Buffer() != "n" {
		t.Errorf("expected buffer 'n' after backspace, got '%s'", e.Buffer())
	}
}

func TestDictFallback(t *testing.T) {
	e := NewEngine()
	// "da" 不在高频词表里，应从 chars.json 词库查找
	e.Append('d')
	e.Append('a')
	cands := e.Candidates()
	if len(cands) == 0 {
		t.Fatal("expected candidates for 'da' from dict")
	}
}
