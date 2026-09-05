// 回退后端: 未带 -tags librime 构建时使用, 保持原有自研 Go 引擎的行为
// (词级候选, 无整句/无 userdb)。
//
// 存在意义: ① 本地开发/CI 无需 librime 静态库即可 go build;
// ② 某架构的 librime 尚未编出来时, ime-server 仍可工作。
// 对外接口 (inputState) 与 librime 后端完全一致, 上层 HTTP handler 无感。
//go:build !librime

package main

import (
	"strings"
	"sync"
	"unicode"
)

// fallbackBackend 用自研引擎模拟有状态会话: 自己攒拼音串, 每次查候选。
// 行为对齐旧版 QML 逻辑 —— 空格上首选、退格删字母。
type fallbackBackend struct {
	mu     sync.Mutex
	buffer string
}

func newFallbackBackend() *fallbackBackend { return &fallbackBackend{} }

func (b *fallbackBackend) Feed(chars string) inputState {
	b.mu.Lock()
	defer b.mu.Unlock()

	var committed string
	for _, ch := range chars {
		switch {
		case ch == '\b':
			if b.buffer != "" {
				b.buffer = b.buffer[:len(b.buffer)-1]
			}
		case ch == ' ' || ch == '\r' || ch == '\n':
			// 空格/回车: 上首选 (无候选则上原拼音)
			if b.buffer == "" {
				break
			}
			if c := engine.CandidatesFor(b.buffer); len(c) > 0 {
				committed += c[0]
			} else {
				committed += b.buffer
			}
			b.buffer = ""
		case unicode.IsLetter(ch):
			b.buffer += strings.ToLower(string(ch))
		default:
			// 其他字符: 有拼音先上首选再插该字符
			if b.buffer != "" {
				if c := engine.CandidatesFor(b.buffer); len(c) > 0 {
					committed += c[0]
				}
				b.buffer = ""
			}
			committed += string(ch)
		}
	}
	return b.snapshot(committed)
}

func (b *fallbackBackend) Snapshot() inputState {
	b.mu.Lock()
	defer b.mu.Unlock()
	return b.snapshot("")
}

func (b *fallbackBackend) SelectCandidate(idx int) inputState {
	b.mu.Lock()
	defer b.mu.Unlock()
	var committed string
	if c := engine.CandidatesFor(b.buffer); idx >= 0 && idx < len(c) {
		committed = c[idx]
		b.buffer = ""
	}
	return b.snapshot(committed)
}

// 自研引擎无分页概念, 翻页交给 QML 侧对完整候选列表切片, 这里空实现。
func (b *fallbackBackend) ChangePage(backward bool) inputState {
	b.mu.Lock()
	defer b.mu.Unlock()
	return b.snapshot("")
}

func (b *fallbackBackend) Clear() {
	b.mu.Lock()
	defer b.mu.Unlock()
	b.buffer = ""
}

func (b *fallbackBackend) snapshot(committed string) inputState {
	return inputState{
		Preedit:    b.buffer,
		Commit:     committed,
		Candidates: engine.CandidatesFor(b.buffer),
		IsLastPage: true,
	}
}

// newBackend 构造回退后端 (未带 -tags librime 时选中此实现)。
// 参数保留同签名以便两个实现可互换, 自研引擎不需要词库目录。
func newBackend(_, _ string) backend { return newFallbackBackend() }

// 回退引擎没有方案概念: 只报一个内置拼音项, 切换一律失败。
func (b *fallbackBackend) Schemas() []schemaInfo {
	return []schemaInfo{{ID: "pinyin_go", Name: "拼音 (内置回退引擎)"}}
}
func (b *fallbackBackend) CurrentSchema() string    { return "pinyin_go" }
func (b *fallbackBackend) SelectSchema(string) bool { return false }
