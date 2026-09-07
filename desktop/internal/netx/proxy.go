// Package netx 处理下载用的代理: GUI 从 Finder / 开始菜单启动时不继承终端环境变量,
// 而 GitHub 直连在国内常常超时, 所以要主动探测系统代理并允许用户手填。
package netx

import (
	"net/http"
	"net/url"
	"os"
	"os/exec"
	"regexp"
	"runtime"
	"strings"
	"time"
)

// DetectProxy 按顺序探测: 环境变量 → macOS 系统代理 (scutil) → Windows 注册表。
// 返回形如 http://127.0.0.1:7890 或 socks5://127.0.0.1:1080 的地址, 探测不到返回空。
func DetectProxy() string {
	for _, k := range []string{"https_proxy", "HTTPS_PROXY", "all_proxy", "ALL_PROXY", "http_proxy", "HTTP_PROXY"} {
		if v := strings.TrimSpace(os.Getenv(k)); v != "" {
			return normalize(v)
		}
	}
	switch runtime.GOOS {
	case "darwin":
		out, err := exec.Command("scutil", "--proxy").Output()
		if err == nil {
			m := parseKV(string(out))
			if m["HTTPSEnable"] == "1" && m["HTTPSProxy"] != "" {
				return "http://" + m["HTTPSProxy"] + ":" + orDefault(m["HTTPSPort"], "80")
			}
			if m["HTTPEnable"] == "1" && m["HTTPProxy"] != "" {
				return "http://" + m["HTTPProxy"] + ":" + orDefault(m["HTTPPort"], "80")
			}
			if m["SOCKSEnable"] == "1" && m["SOCKSProxy"] != "" {
				return "socks5://" + m["SOCKSProxy"] + ":" + orDefault(m["SOCKSPort"], "1080")
			}
		}
	case "windows":
		out, err := exec.Command("reg", "query", `HKCU\Software\Microsoft\Windows\CurrentVersion\Internet Settings`, "/v", "ProxyEnable").Output()
		if err == nil && regexp.MustCompile(`ProxyEnable\s+REG_DWORD\s+0x1`).Match(out) {
			out, err = exec.Command("reg", "query", `HKCU\Software\Microsoft\Windows\CurrentVersion\Internet Settings`, "/v", "ProxyServer").Output()
			if err == nil {
				if m := regexp.MustCompile(`ProxyServer\s+REG_SZ\s+(\S+)`).FindSubmatch(out); m != nil {
					return normalize(pickWindowsProxy(string(m[1])))
				}
			}
		}
	}
	return ""
}

// Client 返回带代理与合理超时的 HTTP 客户端; proxy 为空则直连。
func Client(proxy string) (*http.Client, error) {
	tr := http.DefaultTransport.(*http.Transport).Clone()
	tr.TLSHandshakeTimeout = 20 * time.Second
	tr.ResponseHeaderTimeout = 60 * time.Second
	if p := strings.TrimSpace(proxy); p != "" {
		u, err := url.Parse(normalize(p))
		if err != nil {
			return nil, err
		}
		tr.Proxy = http.ProxyURL(u)
	} else {
		tr.Proxy = nil
	}
	return &http.Client{Transport: tr}, nil
}

// normalize 补协议头; socks5h (远端解析) Go 不认, 折成 socks5。
func normalize(p string) string {
	p = strings.TrimSpace(p)
	p = strings.Replace(p, "socks5h://", "socks5://", 1)
	if !strings.Contains(p, "://") {
		p = "http://" + p
	}
	return p
}

// Windows 的 ProxyServer 可能是 "host:port" 或 "http=host:port;https=host:port;socks=..."
func pickWindowsProxy(s string) string {
	if !strings.Contains(s, "=") {
		return s
	}
	parts := map[string]string{}
	for _, kv := range strings.Split(s, ";") {
		if k, v, ok := strings.Cut(kv, "="); ok {
			parts[strings.ToLower(k)] = v
		}
	}
	if v := parts["https"]; v != "" {
		return v
	}
	if v := parts["http"]; v != "" {
		return v
	}
	if v := parts["socks"]; v != "" {
		return "socks5://" + v
	}
	return ""
}

func parseKV(s string) map[string]string {
	m := map[string]string{}
	for _, line := range strings.Split(s, "\n") {
		if k, v, ok := strings.Cut(line, ":"); ok {
			m[strings.TrimSpace(k)] = strings.TrimSpace(v)
		}
	}
	return m
}

func orDefault(v, d string) string {
	if v == "" {
		return d
	}
	return v
}
