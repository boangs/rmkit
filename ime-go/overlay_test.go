package ime

import (
	"testing"
)

func TestMockOverlayShowCandidates(t *testing.T) {
	ov := NewMockOverlay()
	_ = ov.ShowCandidates("ni", []string{"你", "泥"}, 0)
	if ov.LastPinyin != "ni" {
		t.Errorf("expected 'ni', got '%s'", ov.LastPinyin)
	}
	if len(ov.LastCandidates) != 2 {
		t.Errorf("expected 2 candidates, got %d", len(ov.LastCandidates))
	}
	if ov.Cleared {
		t.Error("should not be cleared after show")
	}
}

func TestMockOverlayClear(t *testing.T) {
	ov := NewMockOverlay()
	_ = ov.ShowCandidates("ni", []string{"你"}, 0)
	_ = ov.Clear()
	if !ov.Cleared {
		t.Error("should be cleared")
	}
}

func TestMockOverlayInitial(t *testing.T) {
	ov := NewMockOverlay()
	if ov.LastPinyin != "" {
		t.Errorf("expected empty pinyin, got '%s'", ov.LastPinyin)
	}
	if ov.Cleared {
		t.Error("should not be cleared initially")
	}
}

func TestFormatCandidates(t *testing.T) {
	result := FormatCandidates("ni", []string{"你", "泥"}, 0)
	expected := " ni | >1:你  2:泥"
	if result != expected {
		t.Errorf("expected '%s', got '%s'", expected, result)
	}
}
