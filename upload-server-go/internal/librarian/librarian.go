// Package librarian 通过 /run/xovi-mb 管道调用 librarian xovi 扩展.
//
// 协议: ">e<signal>:<value>\n" 写入 IN 管道, broker 在 OUT 写一段应答后 close OUT.
//   - importDocument 应答是 UUID
//   - renameEntry / deleteEntry 应答是 "ok" (broker ack), 命令本身在 broker 内同步执行
//   - 失败路径应答是 "ERROR: ..."
//
// 重要: 读完一段 (EOF) 后**不要 reopen** OUT, broker 看到新 reader 会进入异常状态
// 把当前正在执行的命令丢弃 (实测 renameEntry 会被中止, visibleName 不更新).
package librarian

import (
	"bytes"
	"errors"
	"fmt"
	"os"
	"syscall"
	"time"
)

const (
	InPipe  = "/run/xovi-mb"
	OutPipe = "/run/xovi-mb-out"
)

var (
	ErrPipeMissing = errors.New("xovi-message-broker 管道不存在 (扩展未启用?)")
	ErrTimeout     = errors.New("librarian 无响应 (超时)")
)

// Invoke 发送一条命令到 broker, 返回单段应答 (uuid / "ok" / "ERROR: ...").
//
// 关键顺序: **先 open OUT reader, 再 write IN**.
// 反过来会有 race: broker 收到 IN 立刻 open writer 写应答 close; 此时 server 还没
// open reader, 数据落进 kernel pipe buffer; 之后 server reopen 可能拿到下一次的应答, 错位一格.
// 先开 reader 让 broker writer 一开就能配对到稳定 reader, 数据落进同一次 read.
func Invoke(signal, value string, timeout time.Duration) (string, error) {
	if _, err := os.Stat(InPipe); err != nil {
		return "", ErrPipeMissing
	}

	// 1) 先 open OUT reader (NONBLOCK, FIFO 允许无 writer 时打开 reader)
	fd, err := syscall.Open(OutPipe, syscall.O_RDONLY|syscall.O_NONBLOCK, 0)
	if err != nil {
		return "", fmt.Errorf("open %s: %w", OutPipe, err)
	}
	defer syscall.Close(fd)

	// drain 上次调用残留的数据 (broker 异步写 OUT 可能在我们之前调用结束后才到达)
	drainBuf := make([]byte, 4096)
	for {
		n, err := syscall.Read(fd, drainBuf)
		if n <= 0 || err != nil {
			break
		}
	}

	// 2) 写命令 → broker 处理 → broker open writer 写 OUT (我们已经持有 reader)
	in, err := os.OpenFile(InPipe, os.O_WRONLY, 0)
	if err != nil {
		return "", fmt.Errorf("open %s: %w", InPipe, err)
	}
	cmd := fmt.Sprintf(">e%s:%s\n", signal, value)
	if _, err := in.Write([]byte(cmd)); err != nil {
		in.Close()
		return "", fmt.Errorf("write cmd: %w", err)
	}
	in.Close()

	// 3) poll 等数据 → read 直到 EOF (broker close writer) → 返回拼接结果
	deadline := time.Now().Add(timeout)
	var buf bytes.Buffer
	tmp := make([]byte, 4096)
	for {
		remaining := time.Until(deadline)
		if remaining <= 0 {
			return "", fmt.Errorf("%w (signal=%s)", ErrTimeout, signal)
		}
		pfd := []pollFd{{Fd: int32(fd), Events: pollIn}}
		nReady, err := poll(pfd, int(remaining.Milliseconds()))
		if err == syscall.EINTR {
			continue
		}
		if err != nil {
			return "", fmt.Errorf("poll pipe: %w", err)
		}
		if nReady == 0 {
			return "", fmt.Errorf("%w (signal=%s)", ErrTimeout, signal)
		}
		n, err := syscall.Read(fd, tmp)
		if err == syscall.EAGAIN {
			continue
		}
		if err != nil {
			return "", fmt.Errorf("read pipe: %w", err)
		}
		if n == 0 {
			return buf.String(), nil
		}
		buf.Write(tmp[:n])
	}
}
