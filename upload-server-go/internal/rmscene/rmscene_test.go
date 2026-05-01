package rmscene

import (
	"strings"
	"testing"
)

func TestExtractTypedTextZH(t *testing.T) {
	text, err := ExtractTextFile("testdata/typed_text_zh.rm")
	if err != nil {
		t.Fatalf("ExtractTextFile: %v", err)
	}
	t.Logf("extracted: %q", text)

	for _, want := range []string{"中国移动中心", "需求管理"} {
		if !strings.Contains(text, want) {
			t.Errorf("expected output to contain %q, got %q", want, text)
		}
	}
	if strings.Contains(text, "\u200b") {
		t.Errorf("output still contains ZWSP")
	}
}

func TestExtractPage2(t *testing.T) {
	text, err := ExtractTextFile("testdata/page2.rm")
	if err != nil {
		t.Fatalf("ExtractTextFile: %v", err)
	}
	t.Logf("page2 extracted: %q", text)
	if strings.Contains(text, "\u200b") {
		t.Errorf("page2 still contains ZWSP")
	}
}

func TestExtractPage3(t *testing.T) {
	text, err := ExtractTextFile("testdata/page3.rm")
	if err != nil {
		t.Fatalf("ExtractTextFile: %v", err)
	}
	t.Logf("page3 extracted: %q", text)
	if strings.Contains(text, "\u200b") {
		t.Errorf("page3 still contains ZWSP")
	}
}
