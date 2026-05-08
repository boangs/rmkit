package server

import (
	"bytes"
	"context"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"image"
	"image/color"
	"image/png"
	"io"
	"net/http"
	"os"
	"strings"
	"unsafe"

	"github.com/rmkit-cn/upload-server/internal/handwriting"
	"golang.org/x/sys/unix"
)

// /ai-glyph-chat
//
// 输入: {"prompt_prefix":"...","sel_x":x,"sel_y":y,"sel_w":w,"sel_h":h}
// 行为:
//  1. 用 DRM 截取屏幕 → 按选区坐标裁剪 → base64 PNG
//  2. 发给 Claude vision: 先识别手写内容, 再按 prompt_prefix 处理
//  3. 流式返回结果 (同 /ai-page-chat 格式)
//
// 若截图失败, 降级为纯文字 prompt (告知 Claude 无法截图).

func (s *Server) aiGlyphChat(w http.ResponseWriter, r *http.Request) {
	var in struct {
		PromptPrefix string  `json:"prompt_prefix"`
		SelX         float64 `json:"sel_x"`
		SelY         float64 `json:"sel_y"`
		SelW         float64 `json:"sel_w"`
		SelH         float64 `json:"sel_h"`
	}
	if err := json.NewDecoder(io.LimitReader(r.Body, 64<<10)).Decode(&in); err != nil {
		httpError(w, http.StatusBadRequest, "JSON 解析失败: "+err.Error())
		return
	}
	if in.PromptPrefix == "" {
		in.PromptPrefix = "请识别以下手写内容并用中文回答。"
	}

	cfg := defaultAIConfig()
	if data, err := os.ReadFile(AIConfigPath); err == nil {
		var disk aiConfig
		if json.Unmarshal(data, &disk) == nil {
			cfg = disk
		}
	}
	if cfg.Key == "" {
		httpError(w, http.StatusBadRequest, "未配置 API Key")
		return
	}

	flusher, ok := w.(http.Flusher)
	if !ok {
		httpError(w, http.StatusInternalServerError, "不支持 streaming")
		return
	}
	w.Header().Set("Content-Type", "application/x-ndjson; charset=utf-8")
	w.Header().Set("Cache-Control", "no-cache")
	w.Header().Set("X-Accel-Buffering", "no")
	w.WriteHeader(http.StatusOK)

	enc := json.NewEncoder(w)
	writeLine := func(v any) { _ = enc.Encode(v); flusher.Flush() }

	// 尝试截图 (优先用 proc/mem 方案, 降级用 DRM ioctl)
	var screenshotLog string
	imgData, screenshotErr := rmppScreenshot()
	if screenshotErr != nil {
		screenshotLog = "proc/mem: " + screenshotErr.Error()
		imgData, screenshotErr = drmScreenshot()
		if screenshotErr != nil {
			screenshotLog += " | drm: " + screenshotErr.Error()
		}
	}
	var err error
	var prompt string
	if screenshotErr == nil && imgData != nil {
		// 裁剪选区
		cropped := cropImage(imgData, int(in.SelX), int(in.SelY), int(in.SelW), int(in.SelH))
		// 保存裁剪后的图片到 /tmp 供调试查看
		if df, err := os.Create("/tmp/rmkit_glyph_crop.png"); err == nil {
			png.Encode(df, cropped)
			df.Close()
		}
		var buf bytes.Buffer
		if pngErr := png.Encode(&buf, cropped); pngErr == nil {
			b64 := base64.StdEncoding.EncodeToString(buf.Bytes())
			// 用 vision API: 先识别手写, 再处理
			prompt = "【任务指令】" + in.PromptPrefix +
				"\n\n【输入素材】图片是一段中文手写笔迹（电子墨水屏截图，可能带半透明灰色遮罩和角上小方块，那是 UI 元素请忽略）。" +
				"请先在心里把图片识别成中文文本，把识别结果作为【任务指令】要处理的对象/问题/主题。" +
				"\n\n【输出要求】" +
				"\n- 严格按【任务指令】的要求输出，不要 OCR 复述原文" +
				"\n- **字数严格控制在 100 字以内**，宁可精简到 50 字也不要超过 100 字" +
				"\n- 不要说「图片中显示」「你写的是」「我识别到」之类的元话语" +
				"\n- 不要使用 Markdown 标记（不要 # 不要星号 不要反引号）" +
				"\n- 用中文回答（除非任务是翻译为英文）" +
				"\n- 标点必须用中文全角:「。，？！：；（）」, 严禁用半角「. , ? ! : ; ( )」或破折号「-」「—」" +
				"\n- 如果识别出的是一个不完整的问题或主题，按【任务指令】把它当作要回答/展开的主题处理，不要原样返回" +
				"\n- 如果图片完全无法识别（一片噪声/空白/严重失真），明确说「图片识别失败，请重试」，不要编造内容"
			err = callAIStreamWithImage(r.Context(), cfg, prompt, b64, func(chunk string) {
				writeLine(map[string]string{"text": chunk})
			})
		} else {
			err = pngErr
		}
	}

	if screenshotErr != nil || imgData == nil {
		// 截图失败, 降级纯文字，错误信息放第一行让用户看到
		prompt = "[截图失败: " + screenshotLog + "]\n\n" + in.PromptPrefix
		err = callAIStream(r.Context(), cfg, prompt, func(chunk string) {
			writeLine(map[string]string{"text": chunk})
		})
	}

	if err != nil {
		writeLine(map[string]string{"error": err.Error()})
		return
	}
	writeLine(map[string]bool{"done": true})
}

// callAIStreamWithImage: 用 OpenAI 兼容格式发送图像+文字请求（复用现有 callOpenAIStream 逻辑）
func callAIStreamWithImage(ctx context.Context, cfg aiConfig, prompt, imgBase64 string, onChunk func(string)) error {
	base := strings.TrimRight(cfg.URL, "/")
	// 构建 OpenAI vision 格式的 content 数组
	content := []map[string]any{
		{
			"type": "image_url",
			"image_url": map[string]string{
				"url": "data:image/png;base64," + imgBase64,
			},
		},
		{
			"type": "text",
			"text": prompt,
		},
	}
	payload := map[string]any{
		"model":      cfg.Model,
		"max_tokens": 4096,
		"stream":     true,
		"messages":   []map[string]any{{"role": "user", "content": content}},
	}
	body, _ := json.Marshal(payload)
	req, err := http.NewRequestWithContext(ctx, "POST", base+"/chat/completions", bytes.NewReader(body))
	if err != nil {
		return err
	}
	req.Header.Set("Authorization", "Bearer "+cfg.Key)
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("Accept", "text/event-stream")

	client := &http.Client{}
	resp, err := client.Do(req)
	if err != nil {
		return fmt.Errorf("请求 AI 失败: %w", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != 200 {
		b, _ := io.ReadAll(resp.Body)
		return fmt.Errorf("API 错误 %d: %s", resp.StatusCode, string(b))
	}

	// 解析 SSE 流（与 callOpenAIStream 相同）
	var accum strings.Builder
	buf := make([]byte, 4096)
	for {
		n, readErr := resp.Body.Read(buf)
		if n > 0 {
			accum.Write(buf[:n])
			data := accum.String()
			for {
				idx := strings.Index(data, "\n")
				if idx < 0 {
					break
				}
				line := data[:idx]
				data = data[idx+1:]
				if !strings.HasPrefix(line, "data: ") {
					continue
				}
				p := strings.TrimPrefix(line, "data: ")
				if p == "[DONE]" {
					break
				}
				var ev map[string]any
				if json.Unmarshal([]byte(p), &ev) == nil {
					if choices, ok := ev["choices"].([]any); ok && len(choices) > 0 {
						if c, ok := choices[0].(map[string]any); ok {
							if delta, ok := c["delta"].(map[string]any); ok {
								if txt, ok := delta["content"].(string); ok && txt != "" {
									onChunk(txt)
								}
							}
						}
					}
				}
			}
			accum.Reset()
			accum.WriteString(data)
		}
		if readErr != nil {
			break
		}
	}
	return nil
}

// ─── DRM 截图 ────────────────────────────────────────────────────────────────

const (
	drmIoctlBase              = 'd'
	drmIoctlModeGetResources  = 0xC04064A0
	drmIoctlModeGetCrtc       = 0xC06864A1
	drmIoctlModeGetFB         = 0xC01464AD
	drmIoctlModeMapDumb       = 0xC01064B3
	drmIoctlModeGetFB2        = 0xC05464CE
)

type drmModeResources struct {
	FBIDPtr         uint64
	CRTCIDPtr       uint64
	ConnIDPtr       uint64
	EncIDPtr        uint64
	CountFBs        uint32
	CountCRTCs      uint32
	CountConns      uint32
	CountEncs       uint32
	MinW, MaxW      uint32
	MinH, MaxH      uint32
}

type drmModeCrtc struct {
	SetConnsPtr  uint64
	CountConns   uint32
	CRTCID       uint32
	FBID         uint32
	X, Y         uint32
	GammaSize    uint32
	ModeValid    uint32
	Mode         [292]byte
}

type drmModeFBCmd struct {
	FBID   uint32
	Width  uint32
	Height uint32
	Pitch  uint32
	BPP    uint32
	Depth  uint32
	Handle uint32
}

type drmModeMapDumb struct {
	Handle uint32
	Pad    uint32
	Offset uint64
}

func drmIoctl(fd uintptr, req uintptr, arg unsafe.Pointer) error {
	_, _, errno := unix.Syscall(unix.SYS_IOCTL, fd, req, uintptr(arg))
	if errno != 0 {
		return errno
	}
	return nil
}

func drmScreenshot() (image.Image, error) {
	f, err := os.OpenFile("/dev/dri/card0", os.O_RDWR, 0)
	if err != nil {
		return nil, fmt.Errorf("open drm: %w", err)
	}
	defer f.Close()
	fd := f.Fd()

	var res drmModeResources
	if err := drmIoctl(fd, drmIoctlModeGetResources, unsafe.Pointer(&res)); err != nil {
		return nil, fmt.Errorf("GETRESOURCES: %w", err)
	}
	if res.CountCRTCs == 0 {
		return nil, fmt.Errorf("no CRTCs")
	}

	crtcIDs := make([]uint32, res.CountCRTCs)
	fbIDs := make([]uint32, max32(res.CountFBs, 1))
	res.CRTCIDPtr = uint64(uintptr(unsafe.Pointer(&crtcIDs[0])))
	res.FBIDPtr = uint64(uintptr(unsafe.Pointer(&fbIDs[0])))
	connIDs := make([]uint32, max32(res.CountConns, 1))
	encIDs := make([]uint32, max32(res.CountEncs, 1))
	res.ConnIDPtr = uint64(uintptr(unsafe.Pointer(&connIDs[0])))
	res.EncIDPtr = uint64(uintptr(unsafe.Pointer(&encIDs[0])))
	if err := drmIoctl(fd, drmIoctlModeGetResources, unsafe.Pointer(&res)); err != nil {
		return nil, fmt.Errorf("GETRESOURCES2: %w", err)
	}

	crtc := drmModeCrtc{CRTCID: crtcIDs[0]}
	if err := drmIoctl(fd, drmIoctlModeGetCrtc, unsafe.Pointer(&crtc)); err != nil {
		return nil, fmt.Errorf("GETCRTC: %w", err)
	}
	if crtc.FBID == 0 {
		return nil, fmt.Errorf("no FB on CRTC")
	}

	fb := drmModeFBCmd{FBID: crtc.FBID}
	if err := drmIoctl(fd, drmIoctlModeGetFB, unsafe.Pointer(&fb)); err != nil {
		return nil, fmt.Errorf("GETFB: %w", err)
	}
	if fb.Width == 0 || fb.Height == 0 {
		return nil, fmt.Errorf("invalid FB size")
	}

	mapDumb := drmModeMapDumb{Handle: fb.Handle}
	if err := drmIoctl(fd, drmIoctlModeMapDumb, unsafe.Pointer(&mapDumb)); err != nil {
		return nil, fmt.Errorf("MAP_DUMB: %w", err)
	}

	size := int(fb.Pitch) * int(fb.Height)
	data, err := unix.Mmap(int(fd), int64(mapDumb.Offset), size, unix.PROT_READ, unix.MAP_SHARED)
	if err != nil {
		return nil, fmt.Errorf("mmap: %w", err)
	}
	defer unix.Munmap(data)

	bytesPerPixel := int(fb.BPP) / 8
	if bytesPerPixel < 1 {
		bytesPerPixel = 1
	}
	img := image.NewGray(image.Rect(0, 0, int(fb.Width), int(fb.Height)))
	for y := 0; y < int(fb.Height); y++ {
		for x := 0; x < int(fb.Width); x++ {
			off := y*int(fb.Pitch) + x*bytesPerPixel
			if off >= len(data) {
				break
			}
			var gray uint8
			switch bytesPerPixel {
			case 1:
				gray = data[off]
			case 2:
				// RGB565: extract green (middle bits) as approximation
				lo, hi := data[off], data[off+1]
				r5 := (hi >> 3) & 0x1F
				g6 := ((hi & 0x7) << 3) | (lo >> 5)
				b5 := lo & 0x1F
				gray = uint8((int(r5)*8+int(g6)*4+int(b5)*8) / 3)
			default:
				// xRGB / BGRX: channel[1] is reasonable for grayscale
				gray = data[off+1]
			}
			img.SetGray(x, y, color.Gray{Y: gray})
		}
	}
	return img, nil
}

func cropImage(src image.Image, x, y, w, h int) image.Image {
	bounds := src.Bounds()
	// 加 30px 边距给 AI 更多视觉上下文（识别效果更好）
	const pad = 30
	x0 := clamp(x-pad, bounds.Min.X, bounds.Max.X)
	y0 := clamp(y-pad, bounds.Min.Y, bounds.Max.Y)
	x1 := clamp(x+w+pad, bounds.Min.X, bounds.Max.X)
	y1 := clamp(y+h+pad, bounds.Min.Y, bounds.Max.Y)
	if x0 >= x1 || y0 >= y1 {
		return src
	}
	type subImager interface {
		SubImage(r image.Rectangle) image.Image
	}
	if si, ok := src.(subImager); ok {
		return si.SubImage(image.Rect(x0, y0, x1, y1))
	}
	return src
}

func clamp(v, lo, hi int) int {
	if v < lo {
		return lo
	}
	if v > hi {
		return hi
	}
	return v
}

func max32(a, b uint32) uint32 {
	if a > b {
		return a
	}
	return b
}

// /ai-glyph-paste
//
// 输入: {"text":"要插入的文字"}
// 行为: 把文字写入 xclip/xsel 或直接用 xdotool type 注入到 xochitl
// (如果 xdotool 不可用, 尝试写 /tmp/rmkit_paste.txt 并发送 Ctrl+V 按键事件)

func (s *Server) aiGlyphPaste(w http.ResponseWriter, r *http.Request) {
	var in struct {
		Text string `json:"text"`
	}
	if err := json.NewDecoder(io.LimitReader(r.Body, 256<<10)).Decode(&in); err != nil {
		httpError(w, http.StatusBadRequest, "JSON 解析失败: "+err.Error())
		return
	}
	if in.Text == "" {
		httpError(w, http.StatusBadRequest, "text 不能为空")
		return
	}

	// 把文字写入临时文件，然后通过 xclip 写剪贴板
	// RMPP 上没有 xclip，改用 xdotool type (如果有的话)
	// 或者写 /proc/xochitl/fd 的 stdin (不可行)
	// 最实用: 写到 /tmp/rmkit_ai_result.txt，让 xochitl QML 读
	// 暂不使用 evdev（ESC 会导致记事本退出）
	if err := os.WriteFile("/tmp/rmkit_ai_result.txt", []byte(in.Text), 0644); err != nil {
		httpError(w, http.StatusInternalServerError, "写文件失败: "+err.Error())
		return
	}
	w.WriteHeader(http.StatusOK)
	w.Write([]byte(`{"ok":true}`))
}

// /ai-glyph-handwrite
//
// 输入: {"text":"...","sel_x":x,"sel_y":y,"sel_w":w}
// 行为: 在选区下方用 /dev/input/event2 模拟笔写出 text。
//       sel_y 已经是选区底部 y 坐标（QML 端传过来时 +sel.height）
func (s *Server) aiGlyphHandwrite(w http.ResponseWriter, r *http.Request) {
	var in struct {
		Text string  `json:"text"`
		SelX float64 `json:"sel_x"`
		SelY float64 `json:"sel_y"`
		SelW float64 `json:"sel_w"`
	}
	if err := json.NewDecoder(io.LimitReader(r.Body, 256<<10)).Decode(&in); err != nil {
		httpError(w, http.StatusBadRequest, "JSON 解析失败: "+err.Error())
		return
	}
	if in.Text == "" {
		httpError(w, http.StatusBadRequest, "text 不能为空")
		return
	}

	profile := handwriting.DetectProfile()
	// 起始位置：选区下方，左侧从选区起点（最左到 20px，再往左笔画会被裁掉）
	startX := int(in.SelX)
	if startX < 20 {
		startX = 20
	}
	startY := int(in.SelY) + 80

	// 异步执行 (写字耗时长), 立即返回 200 让前端立刻继续。
	// xochitl 自己会按节拍 partial refresh 显示笔画, 不需要主动 flash。
	go func() {
		const fontSize float32 = 24.0
		if err := handwriting.WriteText(profile, in.Text, startX, startY, fontSize); err != nil {
			fmt.Printf("[handwrite err] %v\n", err)
		}
	}()
	w.WriteHeader(http.StatusOK)
	w.Write([]byte(`{"ok":true}`))
}

// aiGlyphTap: 在 view 坐标 (sel_x, sel_y) 单击一次 — 让 xochitl 在 typingMode 下
// 把光标移到 view 坐标对应的文档位置, 再 replaceComposeText 就能精确插入文字。
// 复用手写已验证的 view 坐标精确性, 绕开 scene 坐标转换陷阱。
func (s *Server) aiGlyphTap(w http.ResponseWriter, r *http.Request) {
	var in struct {
		SelX float64 `json:"sel_x"`
		SelY float64 `json:"sel_y"`
	}
	if err := json.NewDecoder(io.LimitReader(r.Body, 1<<10)).Decode(&in); err != nil {
		httpError(w, http.StatusBadRequest, "JSON 解析失败: "+err.Error())
		return
	}
	profile := handwriting.DetectProfile()
	if err := handwriting.TapAt(profile, int(in.SelX), int(in.SelY)); err != nil {
		httpError(w, http.StatusInternalServerError, "tap: "+err.Error())
		return
	}
	w.WriteHeader(http.StatusOK)
	w.Write([]byte(`{"ok":true}`))
}
