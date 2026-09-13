package sshx

import (
	"context"
	"crypto/ed25519"
	"crypto/rand"
	"encoding/pem"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"

	"golang.org/x/crypto/ssh"
)

// 助手自己的 SSH 密钥。为什么需要它: reMarkable 的 root 密码由原厂系统开机时写进 /etc 的
// overlay 上层, rootfs 本体的 /etc/shadow 里 root 是锁定的; Android 模式没有 overlay,
// dropbear 只认下层, 任何密码都会被拒。密钥装在两种模式共享的 /home/root/.ssh 里, 两边都认。
// 私钥只放在用户电脑的应用目录 (0600), 不上传到任何地方。

const appKeyName = "id_ed25519_rmkit_assistant"

// AppKey 是助手的密钥对。
type AppKey struct {
	Signer ssh.Signer
	Public string // authorized_keys 一行 (不含换行)
}

// LoadOrCreateAppKey 读取或生成助手密钥 (dir 为应用配置目录)。
func LoadOrCreateAppKey(dir string) (*AppKey, error) {
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return nil, err
	}
	path := filepath.Join(dir, appKeyName)
	pemBytes, err := os.ReadFile(path)
	if err != nil {
		pub, priv, err := ed25519.GenerateKey(rand.Reader)
		if err != nil {
			return nil, err
		}
		_ = pub
		block, err := ssh.MarshalPrivateKey(priv, "rmkit-assistant")
		if err != nil {
			return nil, err
		}
		pemBytes = pem.EncodeToMemory(block)
		if err := os.WriteFile(path, pemBytes, 0o600); err != nil {
			return nil, err
		}
	}
	signer, err := ssh.ParsePrivateKey(pemBytes)
	if err != nil {
		return nil, fmt.Errorf("助手密钥损坏 (%s): %w", path, err)
	}
	pubLine := strings.TrimSpace(string(ssh.MarshalAuthorizedKey(signer.PublicKey()))) + " rmkit-assistant"
	return &AppKey{Signer: signer, Public: pubLine}, nil
}

// InstallAuthorizedKey 把公钥写进设备 /home/root/.ssh/authorized_keys (幂等)。
// 只在 reMarkable 模式下做 (Android 模式的 /home 也是同一份, 但保持简单)。
func (c *Client) InstallAuthorizedKey(ctx context.Context, pubLine string) error {
	if pubLine == "" {
		return errors.New("空公钥")
	}
	script := fmt.Sprintf(`set -e
mkdir -p /home/root/.ssh
touch /home/root/.ssh/authorized_keys
if ! grep -qF %s /home/root/.ssh/authorized_keys; then
  printf '%%s\n' %s >> /home/root/.ssh/authorized_keys
  echo installed
else
  echo present
fi
chown -R root:root /home/root/.ssh
chmod 700 /home/root/.ssh
chmod 600 /home/root/.ssh/authorized_keys`, shellQuote(strings.Fields(pubLine)[1]), shellQuote(pubLine))
	res, err := c.Run(ctx, script)
	if err != nil {
		return err
	}
	if res.ExitCode != 0 {
		return fmt.Errorf("写 authorized_keys 失败: %s", strings.TrimSpace(res.Stderr))
	}
	if strings.Contains(res.Stdout, "installed") {
		c.log("已把助手的 SSH 公钥装进设备 (/home/root/.ssh/authorized_keys), Android 模式下也能免密连接")
	}
	return nil
}
