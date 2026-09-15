//go:build linux

// 蓝牙保活: btnxpuart (6.12) 在 chiappa 上的省电唤醒握手不可靠 —— 芯片空闲 2 秒进 ps_state=1 后, 主机再发数据
// 经常叫不醒 (dmesg: sending frame failed (-16) / command tx timeout), 之后整个控制器死到断电为止。
// 在驱动修好之前, 每秒往 hci0 发一条无副作用的 HCI 命令 (Read Local Version), 让驱动的空闲计时器永远到不了 2 秒,
// 芯片就不会进省电。代价是蓝牙开着时芯片不睡 (蓝牙只在用户用耳机功能时才会被加载)。
package server

import (
	"encoding/binary"
	"log"
	"os"
	"sync"
	"time"

	"golang.org/x/sys/unix"
)

var btKeepaliveOnce sync.Once

// btStartKeepalive 起一个后台循环; 多次调用只起一次。
func btStartKeepalive() {
	btKeepaliveOnce.Do(func() { go btKeepaliveLoop() })
}

func btKeepaliveLoop() {
	var fd int = -1
	defer func() {
		if fd >= 0 {
			unix.Close(fd)
		}
	}()
	// HCI 命令包: 0x01 | opcode(LE) | plen. Read Local Version Information = OGF 0x04 OCF 0x0001 → 0x1001
	pkt := []byte{0x01, 0, 0, 0}
	binary.LittleEndian.PutUint16(pkt[1:3], 0x1001)
	buf := make([]byte, 512)
	for {
		time.Sleep(1 * time.Second)
		if _, err := os.Stat("/sys/class/bluetooth/hci0"); err != nil {
			if fd >= 0 {
				unix.Close(fd)
				fd = -1
			}
			continue
		}
		if fd < 0 {
			s, err := unix.Socket(unix.AF_BLUETOOTH, unix.SOCK_RAW|unix.SOCK_NONBLOCK|unix.SOCK_CLOEXEC, unix.BTPROTO_HCI)
			if err != nil {
				log.Printf("bt keepalive: socket: %v", err)
				continue
			}
			if err := unix.Bind(s, &unix.SockaddrHCI{Dev: 0, Channel: unix.HCI_CHANNEL_RAW}); err != nil {
				log.Printf("bt keepalive: bind: %v", err)
				unix.Close(s)
				continue
			}
			fd = s
		}
		// 把攒下来的事件读掉, 免得 socket 缓冲区堆满
		for {
			if _, err := unix.Read(fd, buf); err != nil {
				break
			}
		}
		if _, err := unix.Write(fd, pkt); err != nil {
			// 控制器没了 (rmmod) 或者已经死了: 关掉重开, 下一轮重试
			unix.Close(fd)
			fd = -1
		}
	}
}
