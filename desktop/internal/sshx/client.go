// Package sshx 是桌面助手与 reMarkable 之间唯一的通道: 纯 Go SSH (golang.org/x/crypto/ssh),
// 不依赖系统 ssh/scp 命令, Mac/Windows 行为一致。
//
// 隐私边界: 只连用户指定的地址 (默认 USB 网口 10.11.99.1), 密码只在内存里, 每条命令与
// 每个写入的文件都经 Logger 记录, 用户随时能审计工具对设备做了什么。
package sshx

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"io"
	"net"
	"os"
	"path/filepath"
	"strings"
	"time"

	"golang.org/x/crypto/ssh"
)

// Logger 接收人类可读的进度行 (面板实时显示 + 写本地日志)。
type Logger func(line string)

// Client 是一条已认证的 SSH 连接。
type Client struct {
	conn *ssh.Client
	host string
	log  Logger
}

// Dial 用密码登录 root@host。reMarkable 的主机密钥会随槽位/Android 模式变化
// (两个 rootfs 各有一套 sshd key, Android 模式是 dropbear), 而且这条链路是 USB 直连,
// 所以不做 known_hosts 校验。局域网 IP 模式下用户自行承担网络可信度。
func Dial(ctx context.Context, host, password string, log Logger) (*Client, error) {
	if log == nil {
		log = func(string) {}
	}
	if !strings.Contains(host, ":") {
		host += ":22"
	}
	// 认证顺序: 用户本机已有的 SSH 密钥 (~/.ssh/id_ed25519 / id_rsa, 老玩家常已给设备装过公钥) → 密码。
	var auth []ssh.AuthMethod
	if signers := localKeys(); len(signers) > 0 {
		auth = append(auth, ssh.PublicKeys(signers...))
	}
	if password != "" {
		auth = append(auth, ssh.Password(password))
	}
	if len(auth) == 0 {
		return nil, errors.New("请填写 SSH 密码 (设备上 设置 → 帮助 → 版权与许可 最底部)")
	}
	cfg := &ssh.ClientConfig{
		User:            "root",
		Auth:            auth,
		HostKeyCallback: ssh.InsecureIgnoreHostKey(), //nolint:gosec // 见函数注释
		Timeout:         10 * time.Second,
	}
	d := net.Dialer{Timeout: cfg.Timeout}
	raw, err := d.DialContext(ctx, "tcp", host)
	if err != nil {
		return nil, fmt.Errorf("连不上 %s: %w", host, err)
	}
	c, chans, reqs, err := ssh.NewClientConn(raw, host, cfg)
	if err != nil {
		_ = raw.Close()
		if strings.Contains(err.Error(), "unable to authenticate") {
			return nil, errors.New("SSH 密码不对 (设备上 设置 → 帮助 → 版权与许可 最底部)")
		}
		return nil, fmt.Errorf("SSH 握手失败: %w", err)
	}
	log("已连接 " + host)
	return &Client{conn: ssh.NewClient(c, chans, reqs), host: host, log: log}, nil
}

// Close 断开连接。
func (c *Client) Close() error { return c.conn.Close() }

// Host 返回连接地址。
func (c *Client) Host() string { return c.host }

// Result 是一条远端命令的结果。
type Result struct {
	Stdout   string
	Stderr   string
	ExitCode int
}

// Run 执行一条命令, 输出整体返回 (适合探测类短命令)。
func (c *Client) Run(ctx context.Context, cmd string) (Result, error) {
	var out, errb bytes.Buffer
	code, err := c.exec(ctx, cmd, nil, &out, &errb)
	return Result{Stdout: out.String(), Stderr: errb.String(), ExitCode: code}, err
}

// RunLogged 执行一条命令, 输出逐行送到 Logger (适合长时间的设备端脚本)。
// 退出码非零时返回错误。
func (c *Client) RunLogged(ctx context.Context, cmd string, stdin io.Reader) error {
	lw := &lineWriter{emit: c.log}
	code, err := c.exec(ctx, cmd, stdin, lw, lw)
	lw.flush()
	if err != nil {
		return err
	}
	if code != 0 {
		return fmt.Errorf("远端命令退出码 %d", code)
	}
	return nil
}

// RunScript 把一段 bash 脚本经 stdin 交给设备端 `bash -s` 执行, env 以 KEY='v' 前缀传入。
func (c *Client) RunScript(ctx context.Context, script string, env map[string]string) error {
	var sb strings.Builder
	for k, v := range env {
		sb.WriteString(k + "=" + shellQuote(v) + " ")
	}
	sb.WriteString("bash -s")
	return c.RunLogged(ctx, sb.String(), strings.NewReader(script))
}

// StreamTar 把一个 tar.gz 流交给设备端解包 (等价 install.sh 的 `tar -czf - | ssh tar -xzf -`)。
// remoteScript 是设备端接收脚本, 必须自己从 stdin 读 tar。
func (c *Client) StreamTar(ctx context.Context, tarGz io.Reader, remoteScript string) error {
	return c.RunLogged(ctx, "sh -c "+shellQuote(remoteScript), tarGz)
}

// WriteFile 把内容写到设备文件 (小文件用; 大文件走 StreamTar)。
func (c *Client) WriteFile(ctx context.Context, path string, content io.Reader, mode string) error {
	dir := path[:strings.LastIndex(path, "/")]
	cmd := fmt.Sprintf("mkdir -p %s && cat > %s && chmod %s %s", shellQuote(dir), shellQuote(path), mode, shellQuote(path))
	c.log("写入 " + path)
	res, err := c.exec(ctx, cmd, content, io.Discard, io.Discard)
	if err != nil {
		return err
	}
	if res != 0 {
		return fmt.Errorf("写 %s 失败 (退出码 %d)", path, res)
	}
	return nil
}

func (c *Client) exec(ctx context.Context, cmd string, stdin io.Reader, stdout, stderr io.Writer) (int, error) {
	sess, err := c.conn.NewSession()
	if err != nil {
		return -1, fmt.Errorf("开 SSH 会话失败: %w", err)
	}
	defer sess.Close()
	sess.Stdin = stdin
	sess.Stdout = stdout
	sess.Stderr = stderr
	if err := sess.Start(cmd); err != nil {
		return -1, fmt.Errorf("启动远端命令失败: %w", err)
	}
	done := make(chan error, 1)
	go func() { done <- sess.Wait() }()
	select {
	case <-ctx.Done():
		_ = sess.Signal(ssh.SIGKILL)
		return -1, ctx.Err()
	case err := <-done:
		var exitErr *ssh.ExitError
		if errors.As(err, &exitErr) {
			return exitErr.ExitStatus(), nil
		}
		if err != nil {
			return -1, fmt.Errorf("远端命令异常: %w", err)
		}
		return 0, nil
	}
}

// localKeys 读取本机默认位置的无口令私钥; 读不到就当没有 (走密码)。
func localKeys() []ssh.Signer {
	home, err := os.UserHomeDir()
	if err != nil {
		return nil
	}
	var signers []ssh.Signer
	for _, name := range []string{"id_ed25519", "id_rsa", "id_ecdsa"} {
		pem, err := os.ReadFile(filepath.Join(home, ".ssh", name))
		if err != nil {
			continue
		}
		if s, err := ssh.ParsePrivateKey(pem); err == nil {
			signers = append(signers, s)
		}
	}
	return signers
}

func shellQuote(s string) string {
	return "'" + strings.ReplaceAll(s, "'", `'\''`) + "'"
}

// lineWriter 把字节流切成行交给 Logger。
type lineWriter struct {
	emit Logger
	buf  []byte
}

func (w *lineWriter) Write(p []byte) (int, error) {
	w.buf = append(w.buf, p...)
	for {
		i := bytes.IndexByte(w.buf, '\n')
		if i < 0 {
			break
		}
		line := strings.TrimRight(string(w.buf[:i]), "\r")
		w.buf = w.buf[i+1:]
		if line != "" {
			w.emit(line)
		}
	}
	return len(p), nil
}

func (w *lineWriter) flush() {
	if len(w.buf) > 0 {
		w.emit(strings.TrimRight(string(w.buf), "\r\n"))
		w.buf = nil
	}
}
