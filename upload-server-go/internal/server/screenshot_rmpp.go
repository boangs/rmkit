package server

// RMPP/RMPPM 截图 via /proc/{pid}/mem
// 算法参考: /Users/xurx/ghostwriter/src/screenshot.rs
//
// 关键步骤:
//   1. 找 /proc/pid/maps 里 card0 之后跟着大匿名映射（6~8MB）的那行
//   2. 从该匿名映射起始地址用 ghostwriter 算法找帧指针
//   3. 读 960×1696×4 字节 RGBA 数据

import (
	"encoding/binary"
	"fmt"
	"image"
	"image/color"
	"io"
	"os"
	"os/exec"
	"strconv"
	"strings"
)

func xochitlPID() (int, error) {
	out, err := exec.Command("pidof", "xochitl").Output()
	if err != nil {
		return 0, fmt.Errorf("pidof: %w", err)
	}
	parts := strings.Fields(strings.TrimSpace(string(out)))
	if len(parts) == 0 {
		return 0, fmt.Errorf("xochitl not running")
	}
	pid, err := strconv.Atoi(parts[0])
	if err != nil {
		return 0, fmt.Errorf("parse pid: %w", err)
	}
	return pid, nil
}

func rmppScreenshot() (image.Image, error) {
	// RMPPM Chiappa: 960×1696 RGBA8 portrait
	const fbW, fbH = 960, 1696
	const frameSize = uint64(fbW * fbH * 4)

	pid, err := xochitlPID()
	if err != nil {
		return nil, err
	}

	// 找 card0 之后大匿名映射的起始地址（~6.5MB）
	maps, err := os.ReadFile(fmt.Sprintf("/proc/%d/maps", pid))
	if err != nil {
		return nil, fmt.Errorf("read maps: %w", err)
	}
	var anonStart uint64
	lines := strings.Split(string(maps), "\n")
	for i, line := range lines {
		if !strings.Contains(line, "/dev/dri/card0") {
			continue
		}
		if i+1 >= len(lines) {
			continue
		}
		next := lines[i+1]
		parts := strings.Fields(next)
		if len(parts) != 5 { // 匿名映射没有 pathname 字段
			continue
		}
		rng := strings.Split(parts[0], "-")
		if len(rng) != 2 {
			continue
		}
		s, _ := strconv.ParseUint(rng[0], 16, 64)
		e, _ := strconv.ParseUint(rng[1], 16, 64)
		if sz := e - s; sz > 6000000 && sz < 8000000 {
			anonStart = s
		}
	}
	if anonStart == 0 {
		return nil, fmt.Errorf("no framebuffer anonymous mapping found after card0")
	}

	// Ghostwriter 帧指针搜索算法
	f, err := os.Open(fmt.Sprintf("/proc/%d/mem", pid))
	if err != nil {
		return nil, fmt.Errorf("open mem: %w", err)
	}
	defer f.Close()

	var offset, length uint64 = 0, 2
	var frameOff int64
	for i := 0; i < 50; i++ {
		offset += length - 2
		if _, err := f.Seek(int64(anonStart+offset+8), io.SeekStart); err != nil {
			return nil, fmt.Errorf("seek at iter %d: %w", i, err)
		}
		var hdr [8]byte
		if _, err := io.ReadFull(f, hdr[:]); err != nil {
			return nil, fmt.Errorf("read hdr at iter %d offset %d: %w", i, offset, err)
		}
		length = uint64(binary.LittleEndian.Uint32(hdr[:4]))
		if length < 2 {
			return nil, fmt.Errorf("invalid length %d at offset %d", length, offset)
		}
		if length >= frameSize {
			frameOff = int64(anonStart + offset)
			break
		}
	}
	if frameOff == 0 {
		return nil, fmt.Errorf("frame pointer not found (anonStart=0x%x)", anonStart)
	}

	// 读帧缓冲
	if _, err := f.Seek(frameOff, io.SeekStart); err != nil {
		return nil, fmt.Errorf("seek frame: %w", err)
	}
	buf := make([]byte, fbW*fbH*4)
	if _, err := io.ReadFull(f, buf); err != nil {
		return nil, fmt.Errorf("read frame: %w", err)
	}

	img := image.NewNRGBA(image.Rect(0, 0, fbW, fbH))
	for y := 0; y < fbH; y++ {
		for x := 0; x < fbW; x++ {
			off := (y*fbW + x) * 4
			img.SetNRGBA(x, y, color.NRGBA{
				R: buf[off], G: buf[off+1], B: buf[off+2], A: buf[off+3],
			})
		}
	}
	return img, nil
}
