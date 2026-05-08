// Package handwriting 提供笔迹模拟功能：把 AI 生成的文本通过 /dev/input/event2
// 一笔一画地写到 reMarkable 屏幕上。代码精简自 /Users/xurx/ghostwriter/go/，
// 字体数据 handstrokes.json 已 embed 进二进制。
package handwriting

import (
	_ "embed"
	"encoding/binary"
	"encoding/json"
	"fmt"
	"os"
	"strings"
	"sync"
	"syscall"
	"time"
	"unicode"
	"unsafe"
)

//go:embed handstrokes.json
var handstrokesData []byte

// 包加载时后台预热字体表，避免第一次手写时 2-3 秒解析停顿。
func init() {
	go func() {
		_ = loadFont()
	}()
}

// 设备参数（参考 /Users/xurx/ghostwriter/src/constants.rs）
type DeviceProfile struct {
	ScreenW, ScreenH int
	InputW, InputH   int
	InvertY, SwapXY  bool
	PenDev           string
}

// RMPPM Chiappa 参数
var ProfileChiappa = DeviceProfile{
	ScreenW: 960, ScreenH: 1696,
	InputW: 6760, InputH: 11960,
	InvertY: false, SwapXY: false,
	PenDev: "/dev/input/event2",
}

// RMPP Ferrari 参数
var ProfileFerrari = DeviceProfile{
	ScreenW: 1620, ScreenH: 2160,
	InputW: 11180, InputH: 15340,
	InvertY: false, SwapXY: false,
	PenDev: "/dev/input/event2",
}

// DetectProfile 通过 /proc/device-tree/model 自动选择
func DetectProfile() DeviceProfile {
	data, _ := os.ReadFile("/proc/device-tree/model")
	m := strings.ToLower(strings.TrimRight(string(data), "\x00\n"))
	if strings.Contains(m, "chiappa") {
		return ProfileChiappa
	}
	return ProfileFerrari
}

// ─── input event 二进制写入 ────────────────────────────────────────

const (
	evSyn = 0
	evKey = 1
	evAbs = 3

	btnTouch    = 330
	btnToolPen  = 320

	absX        = 0
	absY        = 1
	absPressure = 24
	absDistance = 25

	synReport = 0
)

type rawInputEvent struct {
	Time  syscall.Timeval
	Type  uint16
	Code  uint16
	Value int32
}

type Pen struct {
	dev      *os.File
	profile  DeviceProfile
}

func NewPen(profile DeviceProfile) (*Pen, error) {
	f, err := os.OpenFile(profile.PenDev, os.O_WRONLY, 0)
	if err != nil {
		return nil, fmt.Errorf("open %s: %w", profile.PenDev, err)
	}
	return &Pen{dev: f, profile: profile}, nil
}

func (p *Pen) Close() error {
	if p.dev != nil {
		return p.dev.Close()
	}
	return nil
}

func (p *Pen) sendEvents(events []struct{ T, C uint16; V int32 }) error {
	// 每个 event 单独一次 syscall, 跟 ghostwriter Rust 同款 —— Rust 那边 send_events
	// 在循环里也是每次只传一个 event, 利用 syscall 自带 overhead 作为天然限速。
	// 一次 batch write 会把所有 events 瞬间推进 kernel buffer, 屏幕渲染来不及。
	for _, e := range events {
		ev := rawInputEvent{Type: e.T, Code: e.C, Value: e.V}
		buf := (*[unsafe.Sizeof(ev)]byte)(unsafe.Pointer(&ev))[:]
		if _, err := p.dev.Write(buf); err != nil {
			return err
		}
	}
	_ = binary.Size(rawInputEvent{})
	return nil
}

// hoverEnter 进入"笔悬停"模式 (BTN_TOOL_PEN=1, 但还没接触屏幕)。
// 真人写字时笔从未完全离开 hover 区, xochitl 一直保持"笔输入模式";
// 我们必须模拟同样的状态机, 否则反复切换会累积触发 e-ink full refresh (第 ~8 字时屏闪)。
// 全文开始前调一次, 全文结束才 hoverLeave。
func (p *Pen) hoverEnter() error {
	return p.sendEvents([]struct{ T, C uint16; V int32 }{
		{evKey, btnToolPen, 1},
		{evAbs, absDistance, 30},
		{evSyn, synReport, 0},
	})
}

func (p *Pen) hoverLeave() error {
	return p.sendEvents([]struct{ T, C uint16; V int32 }{
		{evAbs, absDistance, 100},
		{evKey, btnToolPen, 0},
		{evSyn, synReport, 0},
	})
}

// penDown 笔接触屏幕。假设已 hoverEnter, 这里不再切 BTN_TOOL_PEN。
func (p *Pen) penDown() error {
	return p.sendEvents([]struct{ T, C uint16; V int32 }{
		{evKey, btnTouch, 1},
		{evAbs, absPressure, 2400},
		{evAbs, absDistance, 0},
		{evSyn, synReport, 0},
	})
}

// penUp 笔抬起但仍 hover (BTN_TOOL_PEN 保持 1)。模拟真人短暂离开屏幕换笔位。
func (p *Pen) penUp() error {
	return p.sendEvents([]struct{ T, C uint16; V int32 }{
		{evAbs, absPressure, 0},
		{evAbs, absDistance, 30},
		{evKey, btnTouch, 0},
		{evSyn, synReport, 0},
	})
}

func (p *Pen) gotoXY(x, y int) error {
	ix, iy := p.screenToInput(x, y)
	// 限速到约 200Hz, 接近真实笔采样速率 —— 让屏幕渲染管线跟得上, 也给视觉上"写字的过程感"。
	// gotoXY 只发位置 (BTN_TOUCH/PRESSURE/DISTANCE 由 penDown 设, 直到 penUp 才改)。
	// 实测重发 PRESSURE/DISTANCE 反而会让 e-ink 出现"突然刷一下"的现象, 删掉。
	defer time.Sleep(5 * time.Millisecond)
	return p.sendEvents([]struct{ T, C uint16; V int32 }{
		{evAbs, absX, int32(ix)},
		{evAbs, absY, int32(iy)},
		{evSyn, synReport, 0},
	})
}

func (p *Pen) screenToInput(x, y int) (int, int) {
	xn := float32(x) / float32(p.profile.ScreenW)
	yn := float32(y) / float32(p.profile.ScreenH)
	if p.profile.SwapXY {
		ix := int(yn * float32(p.profile.InputW))
		iy := int(xn * float32(p.profile.InputH))
		if p.profile.InvertY {
			iy = int((1 - xn) * float32(p.profile.InputH))
		}
		return ix, iy
	}
	ix := int(xn * float32(p.profile.InputW))
	iy := int(yn * float32(p.profile.InputH))
	if p.profile.InvertY {
		iy = int((1 - yn) * float32(p.profile.InputH))
	}
	return ix, iy
}

// ─── 字体数据（handstrokes.json）─────────────────────────────────

type charStrokeData struct {
	Coord     []float64 `json:"coord"`
	PointType []int     `json:"pointType"`
}

var (
	fontStrokes   map[rune]charStrokeData
	fontLoadOnce  sync.Once
	fontLoadErr   error
)

func loadFont() error {
	fontLoadOnce.Do(func() {
		var raw map[string]charStrokeData
		if err := json.Unmarshal(handstrokesData, &raw); err != nil {
			fontLoadErr = err
			return
		}
		fontStrokes = make(map[rune]charStrokeData, len(raw))
		for k, v := range raw {
			rs := []rune(k)
			if len(rs) == 0 {
				continue
			}
			fontStrokes[rs[0]] = v
		}
	})
	return fontLoadErr
}

// getCharStrokes 返回字符的笔画路径（[stroke[(x,y)...]]）和字符宽度
func getCharStrokes(c rune, fontSize float32) ([][][2]float32, float32) {
	if err := loadFont(); err != nil {
		return nil, fontSize * 0.8
	}
	stroke, ok := fontStrokes[c]
	if !ok {
		return fallbackStrokes(c, fontSize)
	}

	coords := make([][2]float32, 0, len(stroke.Coord)/2)
	for i := 0; i+1 < len(stroke.Coord); i += 2 {
		coords = append(coords, [2]float32{float32(stroke.Coord[i]), float32(stroke.Coord[i+1])})
	}
	if len(coords) != len(stroke.PointType) {
		return fallbackStrokes(c, fontSize)
	}

	var minX, maxX float32
	if len(coords) > 0 {
		minX, maxX = coords[0][0], coords[0][0]
		for _, p := range coords {
			if p[0] < minX {
				minX = p[0]
			}
			if p[0] > maxX {
				maxX = p[0]
			}
		}
	}

	scale := fontSize / 250.0
	padding := fontSize * 0.15

	var strokes [][][2]float32
	var current [][2]float32
	for i, coord := range coords {
		if stroke.PointType[i] == 0 || i == 0 {
			if len(current) > 0 {
				strokes = append(strokes, current)
			}
			current = nil
		}
		px := (coord[0]-minX)*scale + padding
		py := coord[1] * scale
		current = append(current, [2]float32{px, py})
	}
	if len(current) > 0 {
		strokes = append(strokes, current)
	}

	charWidth := (maxX-minX)*scale + padding*2
	return strokes, charWidth
}

// elongateShortStroke 把总位移过短的笔画沿原方向中心放大，
// 保证 xochitl 笔锋引擎能识别到"笔在动"。保持笔画方向、形状、相对位置
// （围绕笔画几何中心缩放，不改变中心位置）。
func elongateShortStroke(stroke [][2]float32, minLen float32) [][2]float32 {
	if len(stroke) < 2 {
		return stroke
	}
	// 计算 bbox 对角线作为"长度"近似
	minX, minY := stroke[0][0], stroke[0][1]
	maxX, maxY := minX, minY
	for _, p := range stroke {
		if p[0] < minX {
			minX = p[0]
		}
		if p[0] > maxX {
			maxX = p[0]
		}
		if p[1] < minY {
			minY = p[1]
		}
		if p[1] > maxY {
			maxY = p[1]
		}
	}
	dx := maxX - minX
	dy := maxY - minY
	diag := float32Sqrt(dx*dx + dy*dy)
	if diag >= minLen {
		return stroke
	}
	scale := minLen / diag
	cx := (minX + maxX) / 2
	cy := (minY + maxY) / 2
	out := make([][2]float32, len(stroke))
	for i, p := range stroke {
		out[i] = [2]float32{
			cx + (p[0]-cx)*scale,
			cy + (p[1]-cy)*scale,
		}
	}
	return out
}

// densifyStroke 线性插值，让笔画至少包含 minPts 个采样点。
// xochitl stroke 引擎需要足够多的连续点才会渲染成完整笔锋；
// handstrokes.json 里的"点/短撇"等只有 2-3 个点，evdev 写入后会被吞掉方向。
func densifyStroke(stroke [][2]float32, minPts int) [][2]float32 {
	if len(stroke) >= minPts {
		return stroke
	}
	// 计算总长度
	totalLen := float32(0)
	for i := 1; i < len(stroke); i++ {
		dx := stroke[i][0] - stroke[i-1][0]
		dy := stroke[i][1] - stroke[i-1][1]
		totalLen += float32Sqrt(dx*dx + dy*dy)
	}
	if totalLen <= 0 {
		return stroke
	}
	step := totalLen / float32(minPts-1)
	out := make([][2]float32, 0, minPts)
	out = append(out, stroke[0])
	acc := float32(0)
	for i := 1; i < len(stroke); i++ {
		segDx := stroke[i][0] - stroke[i-1][0]
		segDy := stroke[i][1] - stroke[i-1][1]
		segLen := float32Sqrt(segDx*segDx + segDy*segDy)
		if segLen <= 0 {
			continue
		}
		// 在这一段里按 step 间隔插值
		for acc+step <= segLen {
			acc += step
			t := acc / segLen
			out = append(out, [2]float32{
				stroke[i-1][0] + segDx*t,
				stroke[i-1][1] + segDy*t,
			})
		}
		acc -= segLen
	}
	if len(out) < minPts {
		out = append(out, stroke[len(stroke)-1])
	}
	return out
}

func float32Sqrt(x float32) float32 {
	if x <= 0 {
		return 0
	}
	// 简单牛顿迭代避免引入 math 依赖；精度对插值足够
	z := x
	for i := 0; i < 8; i++ {
		z = (z + x/z) / 2
	}
	return z
}

func fallbackStrokes(c rune, fontSize float32) ([][][2]float32, float32) {
	w := fontSize * 0.8
	// 任意 Unicode 空白（含 　 全角空格）都不画，只占宽度
	if unicode.IsSpace(c) {
		return nil, w
	}
	// 简单画一个 X
	return [][][2]float32{
		{{0, 0}, {w, fontSize}},
		{{w, 0}, {0, fontSize}},
	}, w
}

// 触屏 (multi-touch) event codes
const (
	absMtSlot        = 47
	absMtTouchMajor  = 48
	absMtTouchMinor  = 49
	absMtOrientation = 52
	absMtPositionX   = 53
	absMtPositionY   = 54
	absMtTrackingID  = 57
	absMtPressure    = 58
)

// 触屏设备 profile (参考 ghostwriter/src/constants.rs RMPPM Chiappa)
// touch 设备坐标范围跟 pen 设备不同, Y 还是反向的
var touchProfileChiappa = struct {
	TouchW, TouchH int
}{1248, 2208}

// TapAt 在 view 坐标 (x, y) 用 multi-touch 协议在 /dev/input/event3 模拟一次手指点击。
// 用于文字模式: xochitl typingMode 下 touch event = 光标定位 (跟用户用屏幕键盘点击屏幕一样)。
// 不能用 event2 (pen) — 那是画笔输入, typingMode 下也会被识别为画字。
// 借用手写已验证的 view 坐标精确性, 绕开 scene 坐标转换陷阱。
func TapAt(profile DeviceProfile, x, y int) error {
	f, err := os.OpenFile("/dev/input/event3", os.O_WRONLY, 0)
	if err != nil {
		return fmt.Errorf("open touch device: %w", err)
	}
	defer f.Close()

	// view → touch 设备坐标。Y 不反向 (RMPP/RMPPM 跟 RM2 不同, 用户看到 'Q' 字母被触发说明落到屏幕键盘 = Y 反了)
	tw := touchProfileChiappa.TouchW
	th := touchProfileChiappa.TouchH
	xn := float32(x) / float32(profile.ScreenW)
	yn := float32(y) / float32(profile.ScreenH)
	tx := int32(xn * float32(tw))
	ty := int32(yn * float32(th))

	sendOne := func(events []struct{ T, C uint16; V int32 }) error {
		for _, e := range events {
			ev := rawInputEvent{Type: e.T, Code: e.C, Value: e.V}
			buf := (*[unsafe.Sizeof(ev)]byte)(unsafe.Pointer(&ev))[:]
			if _, err := f.Write(buf); err != nil {
				return err
			}
		}
		return nil
	}

	// touch_start
	if err := sendOne([]struct{ T, C uint16; V int32 }{
		{evAbs, absMtSlot, 0},
		{evAbs, absMtTrackingID, 1},
		{evAbs, absMtPositionX, tx},
		{evAbs, absMtPositionY, ty},
		{evAbs, absMtPressure, 81},
		{evAbs, absMtTouchMajor, 17},
		{evAbs, absMtTouchMinor, 17},
		{evAbs, absMtOrientation, 4},
		{evSyn, synReport, 0},
	}); err != nil {
		return err
	}
	time.Sleep(30 * time.Millisecond)

	// touch_stop
	if err := sendOne([]struct{ T, C uint16; V int32 }{
		{evAbs, absMtSlot, 0},
		{evAbs, absMtTrackingID, -1},
		{evSyn, synReport, 0},
	}); err != nil {
		return err
	}
	return nil
}

// ─── writeText 主函数 ───────────────────────────────────────────

// WriteText 模拟笔写出文本
//   text: 要写的文字（已格式化好，含换行）
//   startX, startY: 起始位置（屏幕坐标）
//   fontSize: 字体大小（建议 24~36）
func WriteText(profile DeviceProfile, text string, startX, startY int, fontSize float32) error {
	if err := loadFont(); err != nil {
		return fmt.Errorf("load font: %w", err)
	}
	pen, err := NewPen(profile)
	if err != nil {
		return err
	}
	defer pen.Close()
	// 全文用一次"笔进入 hover 区"包住所有笔画, 模拟真人笔不离开屏幕表面;
	// 全文结束才 hoverLeave。这样 xochitl 始终在笔输入模式, 不会反复切换触发 refresh。
	_ = pen.hoverEnter()
	defer pen.hoverLeave()
	time.Sleep(150 * time.Millisecond) // 等 xochitl 注册笔进入 hover 区

	const baseSpacingRatio float32 = 0.2
	minSpacing := fontSize * 0.1
	lineHeight := fontSize * 3.5
	bottomMargin := float32(100.0)

	curX := float32(startX)
	curY := float32(startY)

	for _, c := range text {
		if c == '\n' {
			curX = float32(startX)
			curY += lineHeight
			if curY > float32(profile.ScreenH)-bottomMargin {
				curY = float32(startY)
			}
			continue
		}

		strokes, charWidth := getCharStrokes(c, fontSize)
		if curY > float32(profile.ScreenH)-bottomMargin {
			curY = float32(startY)
			curX = float32(startX)
		}

		for _, stroke := range strokes {
			if len(stroke) < 2 {
				continue
			}
			elongated := elongateShortStroke(stroke, 16)
			dense := densifyStroke(elongated, 6)
			_ = pen.penUp()
			start := dense[0]
			if err := pen.gotoXY(int(start[0]+curX), int(start[1]+curY)); err != nil {
				return err
			}
			if err := pen.penDown(); err != nil {
				return err
			}
			for i := 1; i < len(dense); i++ {
				p := dense[i]
				if err := pen.gotoXY(int(p[0]+curX), int(p[1]+curY)); err != nil {
					return err
				}
			}
		}

		spacing := charWidth * baseSpacingRatio
		if spacing < minSpacing {
			spacing = minSpacing
		}
		if c < 128 {
			spacing *= 0.8
		}
		curX += charWidth + spacing

		if curX > float32(profile.ScreenW)-100.0 {
			curX = float32(startX)
			curY += lineHeight
			if curY > float32(profile.ScreenH)-bottomMargin {
				curY = float32(startY)
			}
			time.Sleep(10 * time.Millisecond)
		}
		time.Sleep(10 * time.Millisecond)
	}
	return pen.penUp()
}
