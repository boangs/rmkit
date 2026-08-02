// librime 后端: 把按键流喂给 librime session, 一次调用同时拿到 preedit、
// 候选列表和上屏文本 —— 全部是进程内函数调用, 无往返。
//
// 这是"候选随字符流一起返回"的实现基础: QML 每次 long-poll 拿字符时,
// 顺带就把该批按键处理后的完整输入状态带回去, 不再需要单独的候选查询请求。
//go:build librime

package main

import (
	"sync"

	"github.com/rmkit-cn/ime/rime"
)

// X11 keysym: librime 按 keysym 收键。可打印 ASCII 的 keysym 即其码值,
// 特殊键用这几个常量。
const (
	keyBackSpace = 0xff08
	keyReturn    = 0xff0d
	keyEscape    = 0xff1b
	keyPageUp    = 0xff55
	keyPageDown  = 0xff56
)

// rimeBackend 用 librime 维护有状态输入会话。
// librime 的 session 不是并发安全的, 全程串行访问。
type rimeBackend struct {
	mu   sync.Mutex
	sess *rime.Session
}

func newRimeBackend(sharedDir, userDir string) *rimeBackend {
	rime.Init(sharedDir, userDir)
	return &rimeBackend{sess: rime.NewSession()}
}

// Feed 把一批字符按键喂给 librime, 返回处理后的输入状态。
// 整句输入、候选排序、userdb 自学习都由 librime 内部完成。
func (b *rimeBackend) Feed(chars string) inputState {
	b.mu.Lock()
	defer b.mu.Unlock()

	var committed string
	for _, ch := range chars {
		var code int
		switch ch {
		case '\b':
			code = keyBackSpace
		case '\r', '\n':
			code = keyReturn
		default:
			code = int(ch) // 可打印 ASCII 的 keysym == 码值
		}
		b.sess.ProcessKey(code, 0)
		// 每个键都可能产生上屏 (回车/空格选词/整句成型), 逐键收集
		if c := b.sess.Commit(); c != "" {
			committed += c
		}
	}
	return b.snapshot(committed)
}

// Snapshot 只读当前状态, 不消费按键。长轮询超时返回它, 而不是伪造空状态 ——
// 空状态会让 writeState 误删 pinyin_active 标志 (hook 就不再吞空格, librime
// 永远收不到提交 → preedit 无限累积), 同时也会让 QML 侧候选框凭空消失。
func (b *rimeBackend) Snapshot() inputState {
	b.mu.Lock()
	defer b.mu.Unlock()
	return b.snapshot("")
}

// SelectCandidate 选中当前页第 idx 个候选 (点击候选框时用)。
func (b *rimeBackend) SelectCandidate(idx int) inputState {
	b.mu.Lock()
	defer b.mu.Unlock()
	b.sess.SelectCandidate(idx)
	return b.snapshot(b.sess.Commit())
}

// ChangePage 翻页。
func (b *rimeBackend) ChangePage(backward bool) inputState {
	b.mu.Lock()
	defer b.mu.Unlock()
	b.sess.ChangePage(backward)
	return b.snapshot("")
}

// Clear 放弃当前未上屏的输入 (焦点切换/退出中文模式时调)。
func (b *rimeBackend) Clear() {
	b.mu.Lock()
	defer b.mu.Unlock()
	b.sess.Clear()
}

// snapshot 读当前 librime 上下文, 组装成给 QML 的状态。调用方须持锁。
func (b *rimeBackend) snapshot(committed string) inputState {
	ctx := b.sess.Context()
	st := inputState{
		Preedit:     ctx.Preedit,
		Commit:      committed,
		Highlighted: ctx.Highlighted,
		PageNo:      ctx.PageNo,
		IsLastPage:  ctx.IsLastPage,
	}
	for _, c := range ctx.Candidates {
		st.Candidates = append(st.Candidates, c.Text)
	}
	return st
}

// newBackend 构造 librime 后端 (带 -tags librime 时选中此实现)。
func newBackend(sharedDir, userDir string) backend { return newRimeBackend(sharedDir, userDir) }
