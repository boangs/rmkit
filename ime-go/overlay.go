package ime

import (
	"fmt"
	"strings"
)

// Overlay 候选词覆盖层接口
type Overlay interface {
	// ShowCandidates 显示候选词列表
	ShowCandidates(pinyin string, candidates []string, selected int) error
	// Clear 清除覆盖层
	Clear() error
	// Close 关闭/释放资源
	Close() error
}

// FramebufferOverlay reMarkable 2 帧缓冲覆盖层 (8-bit 灰度)
// 注意：Paper Pro 使用 DRM 而非 fbdev，此实现仅适用于 rM2
type FramebufferOverlay struct {
	fbPath      string
	screenWidth  int
	screenHeight int
	savedRegion []byte
}

func NewFramebufferOverlay(fbPath string, width, height int) *FramebufferOverlay {
	return &FramebufferOverlay{
		fbPath:      fbPath,
		screenWidth:  width,
		screenHeight: height,
	}
}

func (f *FramebufferOverlay) ShowCandidates(pinyin string, candidates []string, selected int) error {
	// TODO: 实际 framebuffer 写入
	// Paper Pro 使用 DRM，rM2 使用 fbdev
	// 真实实现需要根据设备类型选择不同策略
	_ = fmt.Sprintf("%s %v %d", pinyin, candidates, selected)
	return nil
}

func (f *FramebufferOverlay) Clear() error {
	f.savedRegion = nil
	return nil
}

func (f *FramebufferOverlay) Close() error {
	return f.Clear()
}

// MockOverlay 测试用 Mock 覆盖层
type MockOverlay struct {
	LastPinyin     string
	LastCandidates []string
	LastSelected   int
	Cleared        bool
}

func NewMockOverlay() *MockOverlay {
	return &MockOverlay{}
}

func (m *MockOverlay) ShowCandidates(pinyin string, candidates []string, selected int) error {
	m.LastPinyin = pinyin
	m.LastCandidates = candidates
	m.LastSelected = selected
	m.Cleared = false
	return nil
}

func (m *MockOverlay) Clear() error {
	m.Cleared = true
	return nil
}

func (m *MockOverlay) Close() error {
	return nil
}

// FormatCandidates 格式化候选词显示文本
func FormatCandidates(pinyin string, candidates []string, selected int) string {
	parts := []string{fmt.Sprintf(" %s |", pinyin)}
	for i, c := range candidates {
		marker := " "
		if i == selected {
			marker = ">"
		}
		parts = append(parts, fmt.Sprintf("%s%d:%s", marker, i+1, c))
	}
	return strings.Join(parts, " ")
}
