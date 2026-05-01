// Package qr 探测设备 LAN IP 并生成访问 URL 的 QR 码.
package qr

import (
	"errors"
	"net"
	"strings"

	qrcode "github.com/skip2/go-qrcode"
)

var ErrNoLAN = errors.New("未检测到 Wi-Fi 网络")

// DetectLanIP 返回设备在 WiFi 上的 IPv4, 跳过 loopback 和 reMarkable USB 网段.
func DetectLanIP() (string, error) {
	candidates := []string{}

	addrs, err := net.InterfaceAddrs()
	if err == nil {
		for _, a := range addrs {
			ipnet, ok := a.(*net.IPNet)
			if !ok || ipnet.IP.IsLoopback() {
				continue
			}
			ip4 := ipnet.IP.To4()
			if ip4 == nil {
				continue
			}
			s := ip4.String()
			if strings.HasPrefix(s, "10.11.99.") {
				continue
			}
			candidates = append(candidates, s)
		}
	}

	if len(candidates) == 0 {
		// 兜底: UDP dial 拿默认路由源 IP (不会真发包)
		conn, err := net.Dial("udp4", "8.8.8.8:80")
		if err == nil {
			defer conn.Close()
			if local, ok := conn.LocalAddr().(*net.UDPAddr); ok {
				s := local.IP.String()
				if !local.IP.IsLoopback() && !strings.HasPrefix(s, "10.11.99.") {
					candidates = append(candidates, s)
				}
			}
		}
	}

	if len(candidates) == 0 {
		return "", ErrNoLAN
	}
	return candidates[0], nil
}

// PNG 生成 url 的 QR PNG 数据.
func PNG(url string) ([]byte, error) {
	return qrcode.Encode(url, qrcode.Medium, 256)
}
