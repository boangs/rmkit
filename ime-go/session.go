package ime

import (
	"fmt"
	"io"
	"os"
	"os/signal"
	"syscall"

	"github.com/holoplot/go-evdev"
	"github.com/rmkit-cn/ime/pinyin"
)

// 选词键映射: KEY_1~KEY_5 → 索引 0~4
var selectKeys = map[evdev.EvCode]int{
	evdev.KEY_1: 0,
	evdev.KEY_2: 1,
	evdev.KEY_3: 2,
	evdev.KEY_4: 3,
	evdev.KEY_5: 4,
}

// 字母键码 → 小写字母 (QWERTY 布局)
var keyToChar = map[evdev.EvCode]rune{
	evdev.KEY_Q: 'q', evdev.KEY_W: 'w', evdev.KEY_E: 'e', evdev.KEY_R: 'r',
	evdev.KEY_T: 't', evdev.KEY_Y: 'y', evdev.KEY_U: 'u', evdev.KEY_I: 'i',
	evdev.KEY_O: 'o', evdev.KEY_P: 'p', evdev.KEY_A: 'a', evdev.KEY_S: 's',
	evdev.KEY_D: 'd', evdev.KEY_F: 'f', evdev.KEY_G: 'g', evdev.KEY_H: 'h',
	evdev.KEY_J: 'j', evdev.KEY_K: 'k', evdev.KEY_L: 'l', evdev.KEY_Z: 'z',
	evdev.KEY_X: 'x', evdev.KEY_C: 'c', evdev.KEY_V: 'v', evdev.KEY_B: 'b',
	evdev.KEY_N: 'n', evdev.KEY_M: 'm',
}

// Session IME 会话
type Session struct {
	kb       Keyboard
	engine   *pinyin.Engine
	overlay  Overlay
	injector Injector
	running  bool
}

func NewSession(kb Keyboard, engine *pinyin.Engine, overlay Overlay, injector Injector) *Session {
	return &Session{
		kb:       kb,
		engine:   engine,
		overlay:  overlay,
		injector: injector,
	}
}

func (s *Session) Stop() {
	s.running = false
}

func (s *Session) Run() error {
	s.running = true
	for s.running {
		ev, err := s.kb.ReadEvent()
		if err != nil {
			if err == io.EOF {
				return nil
			}
			return fmt.Errorf("read event: %w", err)
		}
		if ev.Action != KeyPress {
			continue
		}
		s.handleKey(ev)
	}
	return nil
}

func (s *Session) handleKey(ev KeyEvent) {
	code := ev.Code

	// ESC → 退出
	if code == evdev.KEY_ESC {
		s.Stop()
		return
	}

	// 退格
	if code == evdev.KEY_BACKSPACE {
		if s.engine.Buffer() != "" {
			s.engine.Backspace()
			s.refreshOverlay()
		} else {
			_ = s.injector.InjectKey(code)
		}
		return
	}

	// Enter / Space → 确认第一个候选 / 原样注入
	if code == evdev.KEY_ENTER || code == evdev.KEY_SPACE {
		if s.engine.Buffer() != "" && len(s.engine.Candidates()) > 0 {
			s.selectCandidate(0)
		} else {
			_ = s.injector.InjectKey(code)
		}
		return
	}

	// 数字键 1-5 → 选词
	if idx, ok := selectKeys[code]; ok && s.engine.Buffer() != "" {
		cands := s.engine.Candidates()
		if idx < len(cands) {
			s.selectCandidate(idx)
		}
		return
	}

	// 字母键 → 追加到拼音缓冲区
	if ch, ok := keyToChar[code]; ok {
		s.engine.Append(ch)
		s.refreshOverlay()
		return
	}

	// 其他键原样注入
	_ = s.injector.InjectKey(code)
}

func (s *Session) selectCandidate(idx int) {
	cands := s.engine.Candidates()
	if idx >= len(cands) {
		return
	}
	_ = s.injector.InjectChar([]rune(cands[idx])[0])
	s.engine.Clear()
	_ = s.overlay.Clear()
}

func (s *Session) refreshOverlay() {
	cands := s.engine.Candidates()
	if len(cands) > 0 {
		_ = s.overlay.ShowCandidates(s.engine.Buffer(), cands, 0)
	} else {
		_ = s.overlay.Clear()
	}
}

// RunMain 命令行入口
func RunMain() {
	if len(os.Args) < 2 {
		fmt.Fprintf(os.Stderr, "用法: ime <device-path>\n")
		os.Exit(1)
	}
	devicePath := os.Args[1]

	kb, err := NewEvdevKeyboard(devicePath)
	if err != nil {
		fmt.Fprintf(os.Stderr, "打开键盘设备失败: %v\n", err)
		os.Exit(1)
	}
	defer kb.Close()

	engine := pinyin.NewEngine()
	overlay := NewFramebufferOverlay("/dev/fb0", 1404, 1872)
	injector, err := NewUinputInjector()
	if err != nil {
		fmt.Fprintf(os.Stderr, "创建 uinput 设备失败: %v\n", err)
		os.Exit(1)
	}
	defer injector.Close()

	session := NewSession(kb, engine, overlay, injector)

	sigCh := make(chan os.Signal, 1)
	signal.Notify(sigCh, syscall.SIGTERM, syscall.SIGINT)
	go func() {
		<-sigCh
		session.Stop()
	}()

	if err := session.Run(); err != nil {
		fmt.Fprintf(os.Stderr, "IME 运行错误: %v\n", err)
		os.Exit(1)
	}
}
