// 老黄历日历页生成器 — 输出单日 PDF, 供 reMarkable 导入后用笔批注。
//
// 设计取舍:
//   - 不用扫描图模板: 日期是动态的, 扫描件糊且有版权。全部矢量绘制。
//   - 数据全部来自 lunar-go (纯 Go 零依赖), 覆盖宜忌/吉神方位/胎神/冲煞/
//     纳音/星宿/建除/九星/八字/彭祖百忌等。歇后语、潮汐、彩票号码不可计算,
//     留占位或省略。
//   - 用黑色而非原版的绿色: rm2 是灰阶屏, 绿色会变成中灰, 对比度大降。
//     rmpp 是彩屏, 后续可按机型切换。
package main

import (
	"container/list"
	"flag"
	"fmt"
	"image"
	"image/color"
	"image/png"
	"math"
	"os"
	"path/filepath"
	"strings"
	"time"

	"github.com/6tail/lunar-go/HolidayUtil"
	"github.com/6tail/lunar-go/calendar"
	"github.com/signintech/gopdf"
)

// 页面尺寸: rmpp 屏幕 1620x2160 px @229dpi → 510x679 pt, 比例 3:4。
// rm2 (1404x1872) 比例相同, 同一份 PDF 两台都不变形。
const (
	pageW  = 510.0
	pageH  = 679.0
	margin = 16.0
)

const (
	fontRegular = "wk"  // 正文中文字体
	fontCal     = "cal" // 日曆體: 专为日期设计的展示字体 (仅 32 个字形)
	fontDisp    = "hp"  // 展示字体 (方正琥珀等): 农历日 / 星期, 需全 CJK 覆盖
)

// calChars 是日曆體 (LahlitFont, MIT) 实际覆盖的字符 —— 全字体只有 32 个字形,
// 数字加上日历专用汉字。它是展示字体不是正文字体, 所以只用在日期元素上;
// 遇到它没有的字 (如"第""天"), 调用方自动回退到正文字体, 不会出豆腐块。
const calChars = "0123456789H 一二三四五六七八九十廿卅元年月日星期旦"

// hasCal 判断整串是否都在日曆體覆盖范围内
func hasCal(s string) bool {
	for _, r := range s {
		if !strings.ContainsRune(calChars, r) {
			return false
		}
	}
	return true
}

// curTheme 当天的墨色, main 里按日期定好后全程复用
var curTheme = inkGreen

// 生肖剪纸素材目录与配色模式 (由命令行设置)
var (
	assetDir   string
	inkMode    string
	calPath    string
	calLoaded  bool
	dispPath   string
	dispLoaded bool
)

// 老黄历是彩印的: 平日绿墨, 周末与节假日红墨 (传统挂历的惯例)。
// mono 模式给灰阶屏 (rm2) 用 —— 绿色在灰阶上会变中灰, 剪纸的镂空细线会糊掉。
type theme struct{ r, g, b uint8 }

var (
	// 绿墨亮度是给彩色墨水屏定的: 最初用印刷绿 (20,92,58), 在 rmpp 的
	// Kaleido 面板上直接显示为黑 —— 彩墨屏色域窄, 暗色一律趋黑, 亮度决定一切。
	// (55,170,100) 是用户拿真机对着 7 档色卡挑出来的。
	inkGreen = theme{55, 170, 100}
	inkRed   = theme{178, 34, 34}
	inkMono  = theme{0, 0, 0}
)

// pickTheme 平日绿、周末与节假日红。
// 节假日走 lunar-go 的 HolidayUtil (中国法定节假日表, 含调休);
// 调休上班日 (holiday.IsWork()) 虽落在周末, 但要按工作日处理, 仍用绿墨。
func pickTheme(t time.Time) theme {
	if inkMode == "mono" {
		return inkMono
	}
	if h := HolidayUtil.GetHolidayByYmd(t.Year(), int(t.Month()), t.Day()); h != nil {
		if h.IsWork() {
			return inkGreen // 调休上班
		}
		return inkRed
	}
	if wd := t.Weekday(); wd == time.Saturday || wd == time.Sunday {
		return inkRed
	}
	return inkGreen
}

// zodiacFile 地支 → 剪纸文件名。素材是 RGBA 透明底的红色剪纸, 尺寸约 800~900px 见方。
var zodiacFile = map[string]string{
	"子": "老鼠", "丑": "牛", "寅": "老虎", "卯": "兔",
	"辰": "龙", "巳": "蛇", "午": "马", "未": "羊",
	"申": "猴", "酉": "鸡", "戌": "狗", "亥": "猪",
}

func main() {
	var dateStr, out, fontPath string
	flag.StringVar(&dateStr, "date", time.Now().Format("2006-01-02"), "日期 YYYY-MM-DD")
	flag.StringVar(&out, "out", "almanac.pdf", "输出 PDF 路径")
	flag.StringVar(&fontPath, "font", os.Getenv("HOME")+"/Library/Fonts/LXGWWenKaiGBScreen.ttf", "中文 TTF 字体")
	flag.StringVar(&calPath, "calfont", "assets/LahlitFont.ttf", "日曆體 TTF (年份/日号专用, 仅 32 字形)")
	flag.StringVar(&dispPath, "dispfont", "/Users/xurx/tmp/fonts/方正琥珀.TTF", "展示字体 TTF (农历日/星期, 需全 CJK)")
	flag.StringVar(&assetDir, "assets", "assets/zodiac", "生肖剪纸 PNG 目录")
	flag.StringVar(&inkMode, "ink", "color", "配色: color(平日绿/周末节假日红) | mono(灰阶屏) | keep(剪纸保留原色)")
	flag.Parse()

	t, err := time.Parse("2006-01-02", dateStr)
	if err != nil {
		fmt.Fprintln(os.Stderr, "日期格式错误:", err)
		os.Exit(1)
	}

	d := collect(t)

	pdf := &gopdf.GoPdf{}
	pdf.Start(gopdf.Config{PageSize: gopdf.Rect{W: pageW, H: pageH}})
	if err := pdf.AddTTFFont(fontRegular, fontPath); err != nil {
		fmt.Fprintf(os.Stderr, "加载字体失败 (%s): %v\n", fontPath, err)
		os.Exit(1)
	}
	// 日曆體是可选的: 缺失时全部回退正文字体, 只是少了日期的设计感
	if calPath != "" {
		if err := pdf.AddTTFFont(fontCal, calPath); err != nil {
			fmt.Fprintf(os.Stderr, "日曆體加载失败, 回退正文字体: %v\n", err)
		} else {
			calLoaded = true
		}
	}
	if dispPath != "" {
		if err := pdf.AddTTFFont(fontDisp, dispPath); err != nil {
			fmt.Fprintf(os.Stderr, "展示字体加载失败, 回退正文字体: %v\n", err)
		} else {
			dispLoaded = true
		}
	}
	pdf.AddPage()

	// 全页统一墨色 (gopdf 的颜色是状态, 设一次即可)
	curTheme = pickTheme(t)
	pdf.SetTextColor(curTheme.r, curTheme.g, curTheme.b)
	pdf.SetStrokeColor(curTheme.r, curTheme.g, curTheme.b)

	c := &canvas{pdf: pdf}
	draw(c, d)

	if err := pdf.WritePdf(out); err != nil {
		fmt.Fprintln(os.Stderr, "写 PDF 失败:", err)
		os.Exit(1)
	}
	fmt.Printf("已生成 %s (%s %s)\n", out, dateStr, d.weekCN)
}

// ─── 数据 ────────────────────────────────────────────────────────────

type almanac struct {
	year, month, day                            int
	monthCN, dayCN                              string // 农历月/日
	lunarYearCN                                 string // 农历年干支 + 生肖
	weekCN, weekEN                              string
	ganzhiY, ganzhiM, ganzhiD                   string
	yi, ji                                      []string
	jishen, xiongsha                            []string
	posXi, posCai, posFu, posGui                string // 喜神/财神/福神/贵神方位
	naYin, xiu, zhiXing, tianShen, tianShenLuck string
	chong, sha, taiShen                         string
	pengGan, pengZhi                            string
	nineStar, shuJiu, jieQi                     string
	nextJieQi                                   string // 下一个节气 (原版会预告"初二大寒")
	shengXiao                                   string
	dayGan, dayZhi, chongZhi                    string
	xiuSong, xiuLuck                            string
	dayZhiAnimal, chongAnimal                   string
	yearDay                                     int
	bazi                                        []string
	hourLuck                                    []hourCell
}

type hourCell struct {
	zhi  string // 子丑寅…
	span string // 23-01
	luck string // 吉/凶/中
}

func collect(t time.Time) almanac {
	s := calendar.NewSolar(t.Year(), int(t.Month()), t.Day(), 0, 0, 0)
	l := s.GetLunar()

	a := almanac{
		year: t.Year(), month: int(t.Month()), day: t.Day(),
		monthCN:      l.GetMonthInChinese(),
		dayCN:        l.GetDayInChinese(),
		lunarYearCN:  l.GetYearInGanZhi() + "年 " + l.GetYearShengXiao() + "年",
		weekCN:       "星期" + l.GetWeekInChinese(),
		weekEN:       t.Weekday().String(),
		ganzhiY:      l.GetYearInGanZhi(),
		ganzhiM:      l.GetMonthInGanZhi(),
		ganzhiD:      l.GetDayInGanZhi(),
		yi:           toSlice(l.GetDayYi()),
		ji:           toSlice(l.GetDayJi()),
		jishen:       toSlice(l.GetDayJiShen()),
		xiongsha:     toSlice(l.GetDayXiongSha()),
		posXi:        l.GetDayPositionXiDesc(),
		posCai:       l.GetDayPositionCaiDesc(),
		posFu:        l.GetDayPositionFuDesc(),
		posGui:       l.GetDayPositionYangGuiDesc(),
		naYin:        l.GetDayNaYin(),
		xiu:          l.GetXiu() + l.GetZheng() + l.GetAnimal(),
		zhiXing:      l.GetZhiXing(),
		tianShen:     l.GetDayTianShen(),
		tianShenLuck: l.GetDayTianShenType() + " " + l.GetDayTianShenLuck(),
		chong:        l.GetDayChongDesc(),
		sha:          l.GetDaySha(),
		taiShen:      l.GetDayPositionTai(),
		pengGan:      l.GetPengZuGan(),
		pengZhi:      l.GetPengZuZhi(),
		nineStar:     l.GetDayNineStar().String(),
		shuJiu:       shuJiuText(l),
		jieQi:        l.GetJieQi(),
		shengXiao:    l.GetYearShengXiao(),
		dayGan:       l.GetDayGan(),
		dayZhi:       l.GetDayZhi(),
		chongZhi:     l.GetDayChong(),
		dayZhiAnimal: l.GetDayShengXiao(),
		chongAnimal:  l.GetDayChongShengXiao(),
		xiuSong:      l.GetXiuSong(),
		xiuLuck:      "星宿" + l.GetXiuLuck(),
		yearDay:      t.YearDay(),
	}

	ec := l.GetEightChar()
	a.bazi = []string{ec.GetYear(), ec.GetMonth(), ec.GetDay(), ec.GetTime()}

	// 十二时辰吉凶: 逐时取天神吉凶 (吉/凶/中)
	spans := []string{"23-01", "01-03", "03-05", "05-07", "07-09", "09-11",
		"11-13", "13-15", "15-17", "17-19", "19-21", "21-23"}
	zhis := []string{"子", "丑", "寅", "卯", "辰", "巳", "午", "未", "申", "酉", "戌", "亥"}
	for i, lt := range l.GetTimes() {
		if i >= 12 {
			break
		}
		a.hourLuck = append(a.hourLuck, hourCell{zhi: zhis[i], span: spans[i], luck: lt.GetTianShenLuck()})
	}
	return a
}

// shuJiuText: 数九 (冬至后的"三九第九天"这类)。非数九期间返回空。
func shuJiuText(l *calendar.Lunar) string {
	sj := l.GetShuJiu()
	if sj == nil {
		return ""
	}
	return sj.GetName() + "第" + numCN(sj.GetIndex()) + "天"
}

func numCN(n int) string {
	cn := []string{"", "一", "二", "三", "四", "五", "六", "七", "八", "九"}
	if n >= 1 && n <= 9 {
		return cn[n]
	}
	return fmt.Sprint(n)
}

// toSlice 把 lunar-go 返回的 *list.List 转成 []string。
func toSlice(l *list.List) []string {
	var out []string
	if l == nil {
		return out
	}
	for e := l.Front(); e != nil; e = e.Next() {
		if s, ok := e.Value.(string); ok {
			out = append(out, s)
		}
	}
	return out
}

// ─── 绘制原语 ─────────────────────────────────────────────────────────

type canvas struct{ pdf *gopdf.GoPdf }

func (c *canvas) font(size float64) {
	_ = c.pdf.SetFont(fontRegular, "", size)
}

// fontCalIf 整串都被日曆體覆盖时用它, 否则回退正文字体
func (c *canvas) fontCalIf(s string, size float64) {
	if calLoaded && hasCal(s) {
		_ = c.pdf.SetFont(fontCal, "", size)
		return
	}
	_ = c.pdf.SetFont(fontRegular, "", size)
}

// textCal / textCenterCal / textRightCal: 日期元素专用 (年份/日号/星期/农历日)
func (c *canvas) textCal(x, y, size float64, s string) {
	c.fontCalIf(s, size)
	c.cellAt(x, y, s)
}

// textCenterDisp 农历日 / 星期专用。
//
// 为什么不用日曆體: 它只有 32 个字形, "廿八日"能覆盖但"初一日"的"初"没有 →
// 整串回退到正文字体, 于是同一行里农历日是细黑、星期是日曆體, 字重明显不一致
// (用户实测)。这两处改用全 CJK 覆盖的展示字体, 任何日期都保持同一副面孔。
func (c *canvas) textCenterDisp(x, y, w, size float64, s string) {
	if dispLoaded {
		_ = c.pdf.SetFont(fontDisp, "", size)
	} else {
		c.fontCalIf(s, size)
	}
	tw, _ := c.pdf.MeasureTextWidth(s)
	c.cellAt(x+(w-tw)/2, y, s)
}

// textCenterBold 巨大日号专用: 同一串字按细密偏移多画几遍做"仿粗体"。
//
// gopdf 没有文字描边/渲染模式接口, 而日曆體只有一个字重 —— 参考图上的日号是
// 极粗的, 单画一遍明显偏细。偏移量取字号的 0.5% 左右: 太小看不出, 太大糊边。
func (c *canvas) textCenterBold(x, y, w, size float64, s string) {
	c.fontCalIf(s, size)
	tw, _ := c.pdf.MeasureTextWidth(s)
	bx, by := x+(w-tw)/2, y
	d := size * 0.005
	for _, o := range [][2]float64{{0, 0}, {d, 0}, {-d, 0}, {0, d}, {0, -d}, {d, d}, {-d, -d}, {d, -d}, {-d, d}} {
		c.pdf.SetXY(bx+o[0], by+o[1])
		_ = c.pdf.Cell(nil, s)
	}
}

func (c *canvas) textRightCal(x, y, w, size float64, s string) {
	c.fontCalIf(s, size)
	tw, _ := c.pdf.MeasureTextWidth(s)
	c.cellAt(x+w-tw, y, s)
}

func (c *canvas) textCenterCal(x, y, w, size float64, s string) {
	c.fontCalIf(s, size)
	tw, _ := c.pdf.MeasureTextWidth(s)
	c.cellAt(x+(w-tw)/2, y, s)
}

// cellAt 在 (x,y) 写字并叠一遍微偏移 —— 全局仿粗。
// 华文细黑在墨水屏上偏细 (用户实测费劲), 而它没有粗体字重文件,
// 双重绘制是零依赖的粗化手段; 大标题另有 textCenterBold 的 9 遍版本。
func (c *canvas) cellAt(x, y float64, s string) {
	c.pdf.SetXY(x, y)
	_ = c.pdf.Cell(nil, s)
	c.pdf.SetXY(x+0.35, y)
	_ = c.pdf.Cell(nil, s)
}

// text 左上角对齐写一行 (gopdf 的 SetXY 以基线上方为准, 这里统一按上沿)
func (c *canvas) text(x, y, size float64, s string) {
	c.font(size)
	c.cellAt(x, y, s)
}

// textCenter 在 [x, x+w] 区间水平居中
func (c *canvas) textCenter(x, y, w, size float64, s string) {
	c.font(size)
	tw, _ := c.pdf.MeasureTextWidth(s)
	c.cellAt(x+(w-tw)/2, y, s)
}

// textRight 右对齐到 x+w
func (c *canvas) textRight(x, y, w, size float64, s string) {
	c.font(size)
	tw, _ := c.pdf.MeasureTextWidth(s)
	c.cellAt(x+w-tw, y, s)
}

// vtext 竖排文字 (中文按字逐行下落)
func (c *canvas) vtext(x, y, size, lead float64, s string) {
	c.font(size)
	cy := y
	for _, r := range s {
		ch := string(r)
		tw, _ := c.pdf.MeasureTextWidth(ch)
		c.cellAt(x-tw/2, cy, ch)
		cy += lead
	}
}

// vtextCols 竖排多列 (传统右起: 先右列后左列), 区高内垂直居中。
// 给长文本用 (如星宿诗 30+ 字), 单列放不下时自动分列, 不再截断。
func (c *canvas) vtextCols(cx, y0, h, size, lead, colGap float64, s string, perCol int) {
	r := []rune(s)
	var cols [][]rune
	for len(r) > 0 {
		n := perCol
		if n > len(r) {
			n = len(r)
		}
		cols = append(cols, r[:n])
		r = r[n:]
	}
	if len(cols) == 0 {
		return
	}
	maxLen := 0
	for _, c2 := range cols {
		if len(c2) > maxLen {
			maxLen = len(c2)
		}
	}
	y := y0 + (h-float64(maxLen)*lead)/2
	totalW := float64(len(cols)-1) * colGap
	for i, col := range cols {
		x := cx + totalW/2 - float64(i)*colGap
		c.vtext(x, y, size, lead, string(col))
	}
}

// fillPill 圆角胶囊 (多边形近似两端半圆), 填主题墨色 —— 反白标题的底
func (c *canvas) fillPill(x, y, w, h float64) {
	c.inkFill()
	r := h / 2
	var pts []gopdf.Point
	for i := 0; i <= 10; i++ {
		a := -1.5708 + 3.1416*float64(i)/10
		pts = append(pts, gopdf.Point{X: x + w - r + r*math.Cos(a), Y: y + r + r*math.Sin(a)})
	}
	for i := 0; i <= 10; i++ {
		a := 1.5708 + 3.1416*float64(i)/10
		pts = append(pts, gopdf.Point{X: x + r + r*math.Cos(a), Y: y + r + r*math.Sin(a)})
	}
	c.pdf.Polygon(pts, "F")
}

// pillTitle 胶囊反白标题: 主题色底 + 白字 (参考实体日历的栏目标题样式)。
// SetTextColor 连设两次是打断 gopdf 颜色缓存去重 (见 fillRect 注释)。
func (c *canvas) pillTitle(x, y, w, size float64, title string) {
	c.font(size)
	tw, _ := c.pdf.MeasureTextWidth(title)
	capW, capH := tw+18, size+7
	px := x + (w-capW)/2
	c.fillPill(px, y, capW, capH)
	c.pdf.SetTextColor(1, 1, 1)
	c.pdf.SetTextColor(255, 255, 255)
	c.textCenter(x, y+3, w, size, title)
	c.pdf.SetTextColor(0, 0, 0)
	c.pdf.SetTextColor(curTheme.r, curTheme.g, curTheme.b)
}

// vtextColList 竖排指定列 (传统右起), 区高内垂直居中 —— 每列一句诗用
func (c *canvas) vtextColList(cx, y0, h, size, lead, colGap float64, cols []string) {
	if len(cols) == 0 {
		return
	}
	maxLen := 0
	for _, col := range cols {
		if n := len([]rune(col)); n > maxLen {
			maxLen = n
		}
	}
	y := y0 + (h-float64(maxLen)*lead)/2
	totalW := float64(len(cols)-1) * colGap
	for i, col := range cols {
		x := cx + totalW/2 - float64(i)*colGap
		c.vtext(x, y, size, lead, col)
	}
}

// splitSentences 按中文句读切分 (标点跟在句尾)
func splitSentences(s string) []string {
	var out []string
	var cur []rune
	for _, r := range s {
		cur = append(cur, r)
		if r == '，' || r == '。' || r == '；' || r == '、' {
			out = append(out, string(cur))
			cur = nil
		}
	}
	if len(cur) > 0 {
		out = append(out, string(cur))
	}
	return out
}

func (c *canvas) rect(x, y, w, h, lw float64) {
	c.pdf.SetLineWidth(lw)
	c.pdf.RectFromUpperLeftWithStyle(x, y, w, h, "D")
}

func (c *canvas) line(x1, y1, x2, y2, lw float64) {
	c.pdf.SetLineWidth(lw)
	c.pdf.Line(x1, y1, x2, y2)
}

// fillRect 实心矩形。
//
// 坑: gopdf 的颜色指令会和上一次缓存去重 —— 把填充色设成与当前文字色相同的值时,
// 它判定"没变化"就不写指令, 于是填充状态是空的, 矩形画出来是白的 (实测: 同一段
// 代码传红色能填, 传主题绿就填不上)。先设一个不同的颜色打断缓存, 再设目标色。
func (c *canvas) fillRect(x, y, w, h float64, r, g, b uint8) {
	c.pdf.SetFillColor(r^0xFF, g^0xFF, b^0xFF)
	c.pdf.SetFillColor(r, g, b)
	c.pdf.RectFromUpperLeftWithStyle(x, y, w, h, "FD")
	c.pdf.SetFillColor(curTheme.r, curTheme.g, curTheme.b)
}

// ─── 花纹矢量绘制 ────────────────────────────────────────────────────
// 数据在 ornaments_gen.go (从素材 .ai 提取的填充多边形, 归一化坐标)。

type vpt struct{ x, y float64 }

// inkFill 设置与主题墨色"视觉相同"的填充色。
// R 通道偏移 1: gopdf 会把与当前文字色相同的填充色指令静默去重掉 (踩过),
// 偏移 1 肉眼不可分且保证永不相等, 一劳永逸绕开这个坑。
func (c *canvas) inkFill() {
	r := curTheme.r
	if r < 255 {
		r++
	} else {
		r--
	}
	c.pdf.SetFillColor(r, curTheme.g, curTheme.b)
}

// drawVec 把归一化的多边形组画到 (x,y,w,h) 区域。
// flipX/flipY 镜像; rot90 顺时针转 90° (竖向回纹带用, 此时 w/h 为旋转后尺寸)。
func (c *canvas) drawVec(shapes [][]vpt, x, y, w, h float64, flipX, flipY, rot90 bool) {
	c.inkFill()
	c.drawVecRaw(shapes, x, y, w, h, flipX, flipY, rot90)
}

// drawVecRaw 用当前已设置的填充色绘制 (挖孔层需要背景白)
func (c *canvas) drawVecRaw(shapes [][]vpt, x, y, w, h float64, flipX, flipY, rot90 bool) {
	for _, poly := range shapes {
		pts := make([]gopdf.Point, 0, len(poly))
		for _, p := range poly {
			u, v := p.x, p.y
			if flipX {
				u = 1 - u
			}
			if flipY {
				v = 1 - v
			}
			if rot90 {
				u, v = 1-v, u
			}
			pts = append(pts, gopdf.Point{X: x + u*w, Y: y + v*h})
		}
		c.pdf.Polygon(pts, "F")
	}
}

// drawCloudFrame 顶栏如意云头框: 两端云头保形, 中段直线带按需拉伸 (三段式映射)。
// 素材比例 5.3:1, 顶栏区域 14:1 —— 整体拉伸会把云头拉扁, 只拉直线段没有失真。
func (c *canvas) drawCloudFrame(x, y, w, h float64) {
	la, ra := cloudLeftW*h, cloudRightW*h
	midSrc := cloudAspect - cloudLeftW - cloudRightW
	mapX := func(u float64) float64 {
		switch {
		case u <= cloudLeftW:
			return x + u*h
		case u >= cloudAspect-cloudRightW:
			return x + w - (cloudAspect-u)*h
		default:
			return x + la + (u-cloudLeftW)/midSrc*(w-la-ra)
		}
	}
	for _, dp := range cloudVec {
		if dp.depth%2 == 0 {
			c.inkFill()
		} else {
			c.pdf.SetFillColor(255, 255, 255)
		}
		pts := make([]gopdf.Point, 0, len(dp.pts))
		for _, p := range dp.pts {
			pts = append(pts, gopdf.Point{X: mapX(p.x), Y: y + p.y*h})
		}
		c.pdf.Polygon(pts, "F")
	}
}

// drawVecDepth 等比绘制带深度分层的矢量图形 (x 坐标以"高"为单位的素材)。
// 偶数层墨、奇数层背景白, 按数组顺序绘制 (生成时已排好)。
func (c *canvas) drawVecDepth(shapes []depthPoly, x, y, h float64) {
	for _, dp := range shapes {
		if dp.depth%2 == 0 {
			c.inkFill()
		} else {
			c.pdf.SetFillColor(255, 255, 255)
		}
		pts := make([]gopdf.Point, 0, len(dp.pts))
		for _, p := range dp.pts {
			pts = append(pts, gopdf.Point{X: x + p.x*h, Y: y + p.y*h})
		}
		c.pdf.Polygon(pts, "F")
	}
}

// scrollEdgeAt 求卷轴外轮廓 (depth 0 子路径) 在归一化高度 yn 处的左右边缘。
// 用途: 中带双线要"刚好抵到卷轴边缘就停" —— 横贯靠白底遮挡时, 线与拱弧、
// 轴杆的轮廓交叉重叠, 看着杂乱 (用户实测)。直接对矢量数据求交点最准。
func scrollEdgeAt(yn float64) (float64, float64) {
	minX, maxX := math.Inf(1), math.Inf(-1)
	for _, dp := range scrollVec {
		if dp.depth != 0 {
			continue
		}
		pts := dp.pts
		for i := 0; i < len(pts); i++ {
			p1, p2 := pts[i], pts[(i+1)%len(pts)]
			if (p1.y > yn) != (p2.y > yn) {
				x := p1.x + (yn-p1.y)/(p2.y-p1.y)*(p2.x-p1.x)
				if x < minX {
					minX = x
				}
				if x > maxX {
					maxX = x
				}
			}
		}
	}
	return minX, maxX
}

// drawCorner 在 (x,y) 处画边长 size 的角花 (矢量, 三层)。
// 主体 → 白色挖孔, 还原素材的 even-odd 镂空 (逐多边形 nonzero 填充画不出孔,
// 曾渲染成两个实心疙瘩)。
func (c *canvas) drawCorner(x, y, size float64, flipX, flipY bool) {
	c.drawVec(cornerVec, x, y, size, size, flipX, flipY, false)
	c.pdf.SetFillColor(255, 255, 255)
	c.drawVecRaw(cornerHoles, x, y, size, size, flipX, flipY, false)
}

// drawFretVecH / V: 回纹带, 按素材宽高比分段平铺避免明显拉伸
func (c *canvas) drawFretVecH(x, y, w, h float64) {
	n := int(w/(h*fretVecAspect) + 0.5)
	if n < 1 {
		n = 1
	}
	seg := w / float64(n)
	for i := 0; i < n; i++ {
		c.drawVec(fretVec, x+float64(i)*seg, y, seg, h, false, false, false)
	}
}

func (c *canvas) drawFretVecV(x, y, w, h float64) {
	n := int(h/(w*fretVecAspect) + 0.5)
	if n < 1 {
		n = 1
	}
	seg := h / float64(n)
	for i := 0; i < n; i++ {
		c.drawVec(fretVec, x, y+float64(i)*seg, w, seg, false, false, true)
	}
}

// ─── 生肖剪纸 ─────────────────────────────────────────────────────────

// loadZodiac 按地支载入剪纸并按 inkMode 重新着色。
//
// 素材本身是红色。rm2 是灰阶屏, 红色会被映射成中灰, 剪纸的细节 (镂空线条)
// 直接糊掉 —— 所以默认转成纯黑, 只保留 alpha 通道决定形状。rmpp 是彩屏,
// 想要年画感可以 -ink red 保留原色。
func loadZodiac(zhi string) image.Image {
	name, ok := zodiacFile[zhi]
	if !ok || assetDir == "" {
		return nil
	}
	f, err := os.Open(filepath.Join(assetDir, name+".png"))
	if err != nil {
		return nil
	}
	defer f.Close()
	src, err := png.Decode(f)
	if err != nil {
		return nil
	}
	if inkMode == "keep" {
		return src // 保留素材原本的红色
	}
	return tintImage(src)
}

// drawZodiac 在 (x,y) 处按给定边长绘制生肖剪纸, 等比缩放居中
func (c *canvas) drawZodiac(img image.Image, x, y, size float64) {
	if img == nil {
		return
	}
	b := img.Bounds()
	w, h := float64(b.Dx()), float64(b.Dy())
	s := size / w
	if size/h < s {
		s = size / h
	}
	dw, dh := w*s, h*s
	_ = c.pdf.ImageFrom(img, x+(size-dw)/2, y+(size-dh)/2, &gopdf.Rect{W: dw, H: dh})
}

// ─── 装饰原语 ─────────────────────────────────────────────────────────

// 回纹 (雷纹) 的螺旋单元。
//
// 归一化路径: 从单元左侧满高竖线起笔, 沿顶边右行, 折下, 回折, 再向内收成一个
// 半开的螺旋 —— 这是传统回纹的基本形。相邻单元共用起笔竖线, 连起来就是一条
// 连续的回环带。
//
// 踩过的坑: 单元取 11pt、带高 9pt 时, 上下折线间距不足 2pt, 整条带糊成一排
// 小方块 (实测截图像"口口口")。单元必须显著宽于带高, 折线才分得开。
var fretPath = [][2]float64{
	{0.00, 1.00}, {0.00, 0.12}, {0.82, 0.12}, {0.82, 0.72},
	{0.30, 0.72}, {0.30, 0.40}, {0.60, 0.40},
}

const fretUnitW = 19.0 // 单元宽度; 带高约 11pt 时比例合适

// fretBandH 水平回纹带。dir=-1 上下镜像 (页面上下两条带互为镜像才成一圈)
func (c *canvas) fretBandH(x, y, w, h float64, dir float64) {
	n := int(w / fretUnitW)
	if n < 1 {
		return
	}
	u := w / float64(n) // 匀分, 右端不留半个单元
	py := func(t float64) float64 {
		if dir > 0 {
			return y + t*h
		}
		return y + (1-t)*h
	}
	c.pdf.SetLineWidth(0.7)
	for k := 0; k < n; k++ {
		ox := x + float64(k)*u
		for i := 0; i < len(fretPath)-1; i++ {
			c.pdf.Line(ox+fretPath[i][0]*u, py(fretPath[i][1]),
				ox+fretPath[i+1][0]*u, py(fretPath[i+1][1]))
		}
	}
}

// fretBandV 竖直回纹带 (同一路径沿 90° 摆放)
func (c *canvas) fretBandV(x, y, w, h float64, dir float64) {
	n := int(h / fretUnitW)
	if n < 1 {
		return
	}
	u := h / float64(n)
	px := func(t float64) float64 {
		if dir > 0 {
			return x + t*w
		}
		return x + (1-t)*w
	}
	c.pdf.SetLineWidth(0.7)
	for k := 0; k < n; k++ {
		oy := y + float64(k)*u
		for i := 0; i < len(fretPath)-1; i++ {
			c.pdf.Line(px(fretPath[i][1]), oy+fretPath[i][0]*u,
				px(fretPath[i+1][1]), oy+fretPath[i+1][0]*u)
		}
	}
}

// fretFrame 给矩形加一圈回纹花边。
// 带子用素材图片铺 (自绘版单元比例总差点意思, 素材是设计好的回环+端头竖杠),
// 素材缺失时 drawFretImg* 内部自动回退手绘。
func (c *canvas) fretFrame(x, y, w, h, band float64) {
	c.drawFretVecH(x+band, y, w-2*band, band)
	c.drawFretVecH(x+band, y+h-band, w-2*band, band)
	c.drawFretVecV(x, y+band, band, h-2*band)
	c.drawFretVecV(x+w-band, y+band, band, h-2*band)
	// 四角回字方块: 外框 + 中心块, 全部用填充矩形拼, 笔画宽取素材带笔画
	// 占比 (12/94 ≈ 0.128), 与回纹带严格同粗 —— 早先的描边版 (0.7/0.5pt
	// 细线) 和带子质感对不上, 删掉又显得四角秃 (用户两轮反馈), 这版两头兼顾。
	for _, p := range [][2]float64{{x, y}, {x + w - band, y}, {x, y + h - band}, {x + w - band, y + h - band}} {
		c.huiSquare(p[0], p[1], band)
	}
}

// huiSquare 在 (x,y) 处画边长 s 的"回"字方块 (填充矩形拼: 空心外框 + 实心中心)
func (c *canvas) huiSquare(x, y, s float64) {
	t := s * 0.128 // 笔画宽 = 素材回纹带笔画占带高的比例
	c.inkFill()
	fill := func(x0, y0, w0, h0 float64) {
		c.pdf.Polygon([]gopdf.Point{
			{X: x0, Y: y0}, {X: x0 + w0, Y: y0},
			{X: x0 + w0, Y: y0 + h0}, {X: x0, Y: y0 + h0},
		}, "F")
	}
	fill(x, y, s, t)           // 上
	fill(x, y+s-t, s, t)       // 下
	fill(x, y+t, t, s-2*t)     // 左
	fill(x+s-t, y+t, t, s-2*t) // 右
	d := 2.2 * t               // 中心块与外框之间留一圈缝
	fill(x+d, y+d, s-2*d, s-2*d)
}

// cornerSpiral 角上的回旋方块, 让四条带的接缝看起来是收口而非断口
func (c *canvas) cornerSpiral(x, y, s float64) {
	c.pdf.SetLineWidth(0.7)
	for i, f := range []float64{0.18, 0.42} {
		d := s * f
		c.pdf.SetLineWidth(0.7 - float64(i)*0.2)
		c.pdf.RectFromUpperLeftWithStyle(x+d, y+d, s-2*d, s-2*d, "D")
	}
}

// seal 画一个印章式方框 + 居中文字 (原版"福"字的位置)
func (c *canvas) seal(cx, cy, size float64, s string) {
	c.rect(cx-size/2, cy-size/2, size, size, 1.2)
	c.rect(cx-size/2+2.5, cy-size/2+2.5, size-5, size-5, 0.5)
	c.textCenter(cx-size/2, cy-size/2+size*0.22, size, size*0.58, s)
}

// circleLabel 圆圈内的标题字 (宜 / 忌)
func (c *canvas) circleLabel(cx, cy, r float64, s string) {
	c.pdf.SetLineWidth(1.0)
	c.pdf.Oval(cx-r, cy-r, cx+r, cy+r)
	c.textCenter(cx-r, cy-r*0.72, 2*r, r*1.25, s)
}

// ─── 角花 (中式回纹角饰) ────────────────────────────────────────────
//
// 素材来自中式雕刻角饰 .ai (本体就是 PDF 1.4)。
//
// 走过一段弯路: 先从 PDF 内容流里抠出了矢量路径 (38 点折线 + 4 个矩形), 但原图
// 的路径是**填充**图形而非描边 —— 按描边画出来, 每根实心条都变成两条平行轮廓线,
// 放大一看完全不是那个花纹。改填充又撞上 gopdf 的填充色在与文字色相同时画不出来
// 的毛病 (见 fillRect 注释)。最后走已经验证可用的图片通路: 把角花裁成透明 PNG,
// 和生肖剪纸同一套重着色流程, 镜像出四个方向。
const cornerAsset = "corner.png"

var cornerCache = map[[2]bool]image.Image{}

// tintImage 只保留 alpha 决定形状, 颜色统一换成当前墨色
func tintImage(src image.Image) image.Image {
	ink := color.RGBA{curTheme.r, curTheme.g, curTheme.b, 255}
	b := src.Bounds()
	dst := image.NewRGBA(b)
	for y := b.Min.Y; y < b.Max.Y; y++ {
		for x := b.Min.X; x < b.Max.X; x++ {
			_, _, _, a := src.At(x, y).RGBA()
			if a == 0 {
				continue
			}
			dst.Set(x, y, color.RGBA{ink.R, ink.G, ink.B, uint8(a >> 8)})
		}
	}
	return dst
}

// flipImage 按需水平/垂直镜像 (素材只提供左上角那一个方向)
func flipImage(src image.Image, fx, fy bool) image.Image {
	if !fx && !fy {
		return src
	}
	b := src.Bounds()
	dst := image.NewRGBA(b)
	for y := b.Min.Y; y < b.Max.Y; y++ {
		for x := b.Min.X; x < b.Max.X; x++ {
			sx, sy := x, y
			if fx {
				sx = b.Max.X - 1 - (x - b.Min.X)
			}
			if fy {
				sy = b.Max.Y - 1 - (y - b.Min.Y)
			}
			dst.Set(x, y, src.At(sx, sy))
		}
	}
	return dst
}

// ─── 版面 ────────────────────────────────────────────────────────────

func draw(c *canvas, a almanac) {
	const m = 12.0 // 页边距
	x0, x1 := m, pageW-m

	// 整页不加外框 —— 参考图就没有。顶栏、节气旗、主网格各自带框, 底部用实心色条
	// 收口, 整体反而更透气 (加了外框会显得像表格)。
	ix0, ix1 := x0+2, x1-2 // 内容可用区
	iw := ix1 - ix0

	// ── 顶栏: 年份 | 福印 | 月份, 两端配回纹块 ──
	// 如意云头框 (素材: 边框1-3.ai), 文字内缩避开两端云头
	ty, th := m+8, 40.0
	c.drawCloudFrame(ix0, ty, iw, th)
	endW := cloudLeftW*th + 6
	c.seal(pageW/2, ty+th/2, 25, "福")
	// 左组: 只放年份 (干支生肖撤掉 — 加上后拥挤不好看, 用户定稿), 字号 20
	tby := ty + 11.0
	yearS := fmt.Sprintf("%d", a.year)
	// 琥珀体试样: 与农历日/星期同一字体, 顶栏和中带呼应
	if dispLoaded {
		_ = c.pdf.SetFont(fontDisp, "", 21)
	} else {
		c.fontCalIf(yearS, 21)
	}
	w1, _ := c.pdf.MeasureTextWidth(yearS)
	lx0, lx1 := ix0+endW+4, pageW/2-24
	c.cellAt(lx0+(lx1-lx0-w1)/2, tby, yearS)
	// 月份拆两段: 中文用日曆體, 英文缩写它没有字形, 用正文字体
	// 右组: 一月大 JAN (第N天撤掉), 字号 20, 区域内居中
	moS := monthLabel(a) + monthSize(a)
	en := enMonth(a.month)
	if dispLoaded {
		_ = c.pdf.SetFont(fontDisp, "", 20)
	} else {
		c.font(20)
	}
	mW, _ := c.pdf.MeasureTextWidth(moS)
	eW, _ := c.pdf.MeasureTextWidth(en)
	rx0, rx1 := pageW/2+24, ix1-endW-4
	rstart := rx0 + (rx1-rx0-(mW+10+eW))/2
	c.cellAt(rstart, tby, moS)
	c.cellAt(rstart+mW+10, tby, en)
	_ = a.yearDay

	// ── 主区: 左右竖排 + 巨大日号 (副行已并入顶栏) ──
	my := ty + th + 8
	mh := 182.0 // 压缩日号区, 空间倒给主网格 (小字放大后底部溢出)
	sideW := 70.0
	// 星宿诗放这里: 日号区两侧空间大 (高 182), 长诗拆双列完整展示。
	// 原来放彭祖百忌 (短句) 浪费空间, 星宿诗挤在主网格窄条里被截断出
	// "内乱""三三"这种残句 —— 两者互换 (用户建议)。
	// 每列 11 字硬切, 标点保留 (试过按句分列和去标点留白, 都不如原样自然)
	song2 := []rune(a.xiuSong)
	half2 := (len(song2) + 1) / 2
	c.vtextCols(ix0+sideW/2, my+4, mh-10, 12, 15, 17, string(song2[:half2]), 11)
	c.vtextCols(ix1-sideW/2, my+4, mh-10, 12, 15, 17, string(song2[half2:]), 11)
	// 生肖剪纸: 左上"值日"、右下"冲", 对角摆放 (参考图就是这个构图)。
	// 先画剪纸再写日号, 让巨大的数字压在剪纸之上, 层次和原版一致。
	zSize := 62.0
	if img := loadZodiac(a.dayZhi); img != nil {
		c.drawZodiac(img, ix0+sideW+2, my+6, zSize)
		c.textCenter(ix0+sideW+2, my+6+zSize, zSize, 8.5, "值日·"+a.dayZhiAnimal)
	}
	if img := loadZodiac(a.chongZhi); img != nil {
		c.drawZodiac(img, ix1-sideW-2-zSize, my+mh-zSize-30, zSize)
		c.textCenter(ix1-sideW-2-zSize, my+mh-30, zSize, 8.5, "冲·"+a.chongAnimal)
	}
	c.textCenterBold(ix0+sideW, my-10, iw-2*sideW, 190, fmt.Sprintf("%d", a.day))
	// 值神 + 黄道黑道
	// 下移贴近日号区底: 原 my+mh-16 与巨大日号的字底重合 (用户实测)
	c.textCenter(ix0+sideW, my+mh-2, iw-2*sideW, 12.5, a.tianShen+" "+a.tianShenLuck)

	// ── 吉神宜趋 / 凶煞宜忌 (无框, 左右区域各自居中) ──
	// 中间空出来给卷轴框的上探部分 —— 卷轴顶伸进这一行, 文字靠两侧就不打架。
	by := my + mh
	bh := 30.0
	// 卷轴框高由对齐关系解出: 端翼大台阶线要与中带双线下线**完全重合**
	// (用户构图要求), 同时底部保持贴回纹带上沿。
	// 台阶线在素材里是外沿 y=0.295 / 内沿 y=0.314 的描边带 → 中心 0.3045,
	// 厚 0.019。第一版对齐外沿, 差半个线宽只是"挨着"; 必须对齐**线中心**:
	//   双线下线中心 lineY2 = cy + 3.967 (= fr0y + cs*0.117)
	//   底 bottom = cy + 51
	//   scH = (bottom - lineY2) / (1 - 0.3045) ≈ 67.6
	scH := 67.6
	scW := scH * scrollAspect
	sideW2 := (iw-scW)/2 - 10
	c.textCenter(ix0, by, sideW2, 10.5, "吉神宜趋")
	drawWrappedCenter(c, ix0+4, by+14, sideW2-8, 9.5, 11.5, joinSpace(a.jishen), 2)
	c.textCenter(ix1-sideW2, by, sideW2, 10.5, "凶煞宜忌")
	drawWrappedCenter(c, ix1-sideW2+4, by+14, sideW2-8, 9.5, 11.5, joinSpace(a.xiongsha), 2)

	// ── 中带: 农历日 | 节气旗 | 星期 ──
	cy := by + bh + 6
	ch := 52.0
	third := iw / 3
	c.textCenterDisp(ix0, cy+7, third, 29, a.dayCN+"日")
	c.textCenter(ix0, cy+38, third, 10.5, "农历"+a.ganzhiY+"年"+a.monthCN+"月")
	c.textCenterDisp(ix0+2*third, cy+7, third, 29, a.weekCN)
	c.textCenter(ix0+2*third, cy+38, third, 10.5, a.weekEN)
	if os.Getenv("CORNER_BIG") != "" {
		c.drawCorner(80, 100, 220, false, false)
	}
	// 中带装饰: 左右两个大角花把文字包起来, 顶部双线连接, 底部留空。
	// 素材角花是"顶臂横线 + 侧竖臂"的顶角造型: 原方向竖臂在右, 放右侧;
	// 水平镜像后竖臂在左, 放左侧。两个顶臂之间用双线补上, 视觉上连成
	// 一条完整的顶框 (参考实体日历的做法); 底部按用户要求先不封。
	// 尺寸约束: 顶部离上方"吉神宜趋"框底 4pt, 底部离下方主网格顶 3pt。
	// 原来 fr0y=cy-6 正好压着上框底线, cs=ch+10 又戳进主网格 4pt, 两头都重叠。
	fr0y := cy - 2
	cs := ch - 1
	c.drawCorner(ix1-cs, fr0y, cs, false, false) // 右侧 (原方向, 竖臂在右)
	c.drawCorner(ix0, fr0y, cs, true, false)     // 左侧 (镜像, 竖臂在左)
	// 顶部双线 = 角花自己两条横臂的延伸, 线宽和 y 都按素材归一坐标取:
	// 顶臂 y∈[0, 0.0344] → 宽 cs*0.0344; 第二短线 y∈[0.1027, 0.1314] → 宽 cs*0.0287。
	// 之前用 1.4/0.7 的固定线宽, 明显细于角花笔画, 接缝一眼看穿 (用户实测)。
	// 双线在卷轴边缘精确停住 (见卷轴绘制处, 需先确定卷轴几何) —— 曾试过
	// 横贯+白底遮挡, 线与拱弧轴杆的轮廓交叉重叠, 杂乱 (用户实测)。

	// 中间拱形卷轴框 (素材: 边框1-5.ai 第一款)。
	// 高度故意超出中带 (上下各出头 4pt), 作为压在带上的立体装饰 —— 参考
	// 实体日历的卷轴构图。白底后画, 遮住横贯的双线, 层次自然。
	// 尺寸在吉神段已定 (scH/scW)。底固定贴回纹带上沿, 顶随高度自然上探
	scX := ix0 + (iw-scW)/2
	scY := cy + 51 - scH
	// 双线: 从角花臂延伸, 精确断在卷轴该高度的外轮廓上 (对矢量数据求交)
	// 下线宽取台阶线厚 (0.019*scH ≈ 1.28), 中心与厚度双重合才是"融为一体";
	// 与角花短线 (1.46) 的差 0.18pt 在接缝处不可见
	for _, ln := range [][2]float64{{fr0y + cs*0.0172, cs * 0.0344}, {fr0y + cs*0.117, 0.019 * scH}} {
		ly, lw2 := ln[0], ln[1]
		yn := (ly - scY) / scH
		lx, rx := scrollEdgeAt(yn)
		// 线端向轮廓内伸 1.5pt: 原先留 1pt 空隙, 在接缝处露出细小豁口
		// (用户圈出两处)。墨色叠墨色只会融合, 伸进去才是"接上"。
		c.line(ix0+cs*0.5, ly, scX+lx*scH+1.5, ly, lw2)
		c.line(scX+rx*scH-1.5, ly, ix1-cs*0.5, ly, lw2)
	}
	c.drawVecDepth(scrollVec, scX, scY, scH)
	flag := []string{}
	if a.shuJiu != "" {
		flag = append(flag, a.shuJiu)
	}
	if a.jieQi != "" {
		flag = append(flag, a.jieQi)
	} else if a.nextJieQi != "" {
		flag = append(flag, a.nextJieQi)
	}
	fty := scY + (scH-float64(len(flag))*17)/2 - 4
	for i, t := range flag {
		c.textCenter(scX, fty+float64(i)*17, scW, 13.5, t)
	}

	// ── 主网格 (回纹花边) ──
	gy := cy + ch
	footH := 20.0
	gh := pageH - m - 9 - footH - gy
	band := 11.0
	c.fretFrame(ix0-2, gy, iw+4, gh, band)

	gx0 := ix0 - 2 + band + 3
	gx1 := ix0 - 2 + iw + 4 - band - 3
	gyy := gy + band + 3
	ghh := gh - 2*band - 6

	// 两侧竖排吉语 (星宿诗) + 宜/忌 列
	strip := 18.0
	colW := 62.0
	// 彭祖百忌: 固定 8 字上下, 工整不换行, 垂直居中 + 放大 (与星宿诗互换后)
	c.vtextCols(gx0+strip/2, gyy, ghh, 13, 17, 17, a.pengGan, 12)
	c.vtextCols(gx1-strip/2, gyy, ghh, 13, 17, 17, a.pengZhi, 12)

	yiX := gx0 + strip
	jiX := gx1 - strip - colW
	c.line(yiX+colW, gyy, yiX+colW, gyy+ghh, 0.5)
	c.line(jiX, gyy, jiX, gyy+ghh, 0.5)
	c.circleLabel(yiX+colW/2, gyy+14, 11, "宜")
	c.circleLabel(jiX+colW/2, gyy+14, 11, "忌")
	drawWordGrid(c, yiX+4, gyy+32, colW-8, ghh-36, a.yi, 13)
	drawWordGrid(c, jiX+4, gyy+32, colW-8, ghh-36, a.ji, 13)

	// ── 中区: 单一外框 + 共用分隔线的卡片组 (参考实体日历) ──
	// 原先每个区域各画一个 rect, 相邻框之间双线夹缝, 显得琐碎; 现在整个中区
	// 一个外框, 卡片之间只共用一条分隔线。栏目标题用胶囊反白。
	mx0, mx1 := yiX+colW, jiX
	mw := mx1 - mx0

	top2 := gyy + 2
	bot2 := gyy + ghh - 2
	c.rect(mx0+4, top2, mw-8, bot2-top2, 0.8)
	y1 := top2 + 44 // 时辰表底
	y2 := y1 + 100  // 三框底
	y3 := y2 + 58   // 胎神/八字底
	c.line(mx0+4, y1, mx0+mw-4, y1, 0.5)
	c.line(mx0+4, y2, mx0+mw-4, y2, 0.5)
	c.line(mx0+4, y3, mx0+mw-4, y3, 0.5)

	// 时辰吉凶: 一行 12 列
	drawHourTable(c, mx0+6, top2+2, mw-12, 40, a.hourLuck)

	// 三栏: 吉神方位 / 干支五行 / 择吉须知 (竖线共用)
	bw := (mw - 8) / 3
	c.line(mx0+4+bw, y1, mx0+4+bw, y2, 0.5)
	c.line(mx0+4+2*bw, y1, mx0+4+2*bw, y2, 0.5)
	drawBox(c, mx0+4, y1, bw, y2-y1, "吉神方位", [][2]string{
		{"喜神", a.posXi}, {"财神", a.posCai}, {"福神", a.posFu}, {"贵神", a.posGui},
	})
	drawBox(c, mx0+4+bw, y1, bw, y2-y1, "干支五行", [][2]string{
		{"天干", a.dayGan}, {"地支", a.dayZhi}, {"纳音", a.naYin}, {"值星", a.zhiXing},
	})
	drawBox(c, mx0+4+2*bw, y1, bw, y2-y1, "择吉须知", [][2]string{
		{"星宿", a.xiu}, {"九星", truncRunes(a.nineStar, 5)}, {"冲", a.chong}, {"煞", a.sha},
	})

	// 胎神 / 八字 (竖线共用)
	c.line(mx0+mw/2, y2, mx0+mw/2, y3, 0.5)
	c.pillTitle(mx0+4, y2+5, mw/2-4, 11, "每日胎神")
	c.textCenter(mx0+4, y2+30, mw/2-4, 14.5, a.taiShen)
	c.pillTitle(mx0+mw/2, y2+5, mw/2-4, 11, "今日八字")
	c.textCenter(mx0+mw/2, y2+30, mw/2-4, 14.5, joinSpace(a.bazi))

	// 今日提要 (占余下高度)
	if y3+22 < bot2 {
		c.pillTitle(mx0+4, y3+5, mw-8, 11, "今日提要")
		drawWrapped(c, mx0+12, y3+27, mw-24, 10.5, 13.5,
			"值神 "+a.tianShen+" "+a.tianShenLuck+"   星宿 "+a.xiu+" "+a.xiuLuck+
				"   冲 "+a.chong+" 煞"+a.sha+"   九星 "+a.nineStar, 3)
	}

	// ── 底栏: 文字 + 页脚实心色条 ──
	// 色条用"加粗的线"画, 不用填充矩形: gopdf 的填充色指令在与当前文字色相同时
	// 会被静默吞掉 (实测传红色能填、传主题绿填不上, 换几种写法都没绕过去), 而描边
	// 一直正常。文字放在色条上方而不是反白压在条上, 同时避开了反白字失效的问题。
	fy := pageH - m - 4 - footH
	c.text(ix0+4, fy+2, 11, fmt.Sprintf("干支  %s年 %s月 %s日", a.ganzhiY, a.ganzhiM, a.ganzhiD))
	c.textCenter(ix0, fy+2, iw, 11, "rmkit-cn 黄历")
	c.textRight(ix0, fy+2, iw-4, 11, a.xiuLuck)
	barY := fy + 16
	c.line(ix0, barY+3, ix1, barY+3, 6)
}

// drawBox 栏目内容 (框线由外层共线网格提供): 胶囊反白标题 + "标签 值"行
func drawBox(c *canvas, x, y, w, h float64, title string, rows [][2]string) {
	c.pillTitle(x, y+5, w, 11, title)
	for i, kv := range rows {
		ry := y + 28 + float64(i)*17.5
		if ry+11 > y+h {
			break
		}
		c.text(x+6, ry, 10.5, kv[0])
		c.textRight(x, ry, w-6, 10.5, truncRunes(kv[1], 6))
	}
}

// drawWordGrid 竖排词条 (宜/忌 各占一列, 每行一个词)
func drawWordGrid(c *canvas, x, y, w, maxH float64, words []string, size float64) {
	lead := size + 3.5
	for i, s := range words {
		if float64(i+1)*lead > maxH {
			break // 放不下就截断, 宁可少列几条也不能压到底栏 (实测 19 条会溢出)
		}
		c.textCenter(x, y+float64(i)*lead, w, size, s)
	}
}

// drawWrappedCenter 折行且每行水平居中
func drawWrappedCenter(c *canvas, x, y, w, size, lead float64, s string, maxLines int) {
	c.font(size)
	line, ln := "", 0
	flush := func() {
		if line == "" {
			return
		}
		c.textCenter(x, y+float64(ln)*lead, w, size, line)
		ln++
		line = ""
	}
	for _, r := range s {
		try := line + string(r)
		tw, _ := c.pdf.MeasureTextWidth(try)
		if tw > w {
			flush()
			if ln >= maxLines {
				return
			}
		}
		line += string(r)
	}
	flush()
}

// drawWrapped 按宽度折行, 最多 maxLines 行
func drawWrapped(c *canvas, x, y, w, size, lead float64, s string, maxLines int) {
	c.font(size)
	line, ln := "", 0
	flush := func() {
		if line == "" {
			return
		}
		c.text(x, y+float64(ln)*lead, size, line)
		ln++
		line = ""
	}
	for _, r := range s {
		try := line + string(r)
		tw, _ := c.pdf.MeasureTextWidth(try)
		if tw > w {
			flush()
			if ln >= maxLines {
				return
			}
		}
		line += string(r)
	}
	flush()
}

// drawHourTable 十二时辰吉凶: 一整行 12 列, 每列三层 (地支 / 时段 / 吉凶)。
// 参考图就是这个形态 —— 之前分两组 6 列会和下方方位块抢空间, 也不像原版。
func drawHourTable(c *canvas, x, y, w, h float64, cells []hourCell) {
	if len(cells) == 0 {
		return
	}
	cw := w / float64(len(cells))
	for i, hc := range cells {
		cx := x + float64(i)*cw
		if i > 0 {
			c.line(cx, y+1, cx, y+h-1, 0.3)
		}
		c.textCenter(cx, y+2, cw, 12, hc.zhi)
		c.textCenter(cx, y+16, cw, 6.5, hc.span)
		c.textCenter(cx, y+25, cw, 11, hc.luck)
	}
}

// drawKV 左标签右值的小表
func drawKV(c *canvas, x, y, w float64, rows [][2]string, size float64) {
	for i, kv := range rows {
		cy := y + float64(i)*13
		c.text(x, cy, size-2, kv[0])
		c.textRight(x, cy, w, size-2, truncRunes(kv[1], 12))
	}
}

func joinSpace(ss []string) string {
	out := ""
	for i, s := range ss {
		if i > 0 {
			out += " "
		}
		out += s
	}
	return out
}

func truncRunes(s string, n int) string {
	r := []rune(s)
	if len(r) <= n {
		return s
	}
	return string(r[:n])
}

func monthLabel(a almanac) string {
	cn := []string{"", "一", "二", "三", "四", "五", "六", "七", "八", "九", "十", "十一", "十二"}
	return cn[a.month] + "月"
}

// monthSize 公历月份的传统大小标注: 31 天为"大", 30/28/29 天为"小"
func monthSize(a almanac) string {
	days := time.Date(a.year, time.Month(a.month)+1, 0, 0, 0, 0, 0, time.UTC).Day()
	if days == 31 {
		return "大"
	}
	return "小"
}

func enMonth(m int) string {
	en := []string{"", "JAN", "FEB", "MAR", "APR", "MAY", "JUN",
		"JUL", "AUG", "SEP", "OCT", "NOV", "DEC"}
	return en[m]
}
