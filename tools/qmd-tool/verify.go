package main

import (
	"bytes"
	"fmt"
	"os"
)

// verifyQMD: 校验单个已编译 .qmd 能否安全交给 qmldiff 加载 (对指定的单个 hashtab).
// 与 checkQMD (目录级、hashtab 并集、开发期用) 不同, verify 是设备端 precheck 在
// 每次 xochitl 启动前逐文件调用的: 任何一项不过 → 该 qmd 会被隔离, 防止孤儿 hash
// 触发 qmldiff Rust panic → xochitl crash → A/B 回滚 (memory: 6 次砖机复盘).
//
// 检查项:
//  1. 文件非空且 > 100 bytes (空文件/截断)
//  2. 开头不含 Traceback/Error 特征 (历史上 hash-qmd.py 失败曾把 stderr 写进产物)
//  3. 所有 hash 引用都在 hashtab 中 (孤儿 hash = panic)
func verifyQMD(hashtabPath, qmdPath string) error {
	hashes, err := loadHashSet(hashtabPath)
	if err != nil {
		return fmt.Errorf("hashtab 加载失败: %w", err)
	}
	return verifyQMDAgainst(hashes, qmdPath)
}

func verifyQMDAgainst(hashes map[uint64]struct{}, qmdPath string) error {
	data, err := os.ReadFile(qmdPath)
	if err != nil {
		return err
	}
	if len(data) < 100 {
		return fmt.Errorf("文件过小 (%d bytes)", len(data))
	}
	head := data
	if len(head) > 256 {
		head = head[:256]
	}
	for _, marker := range [][]byte{[]byte("Traceback"), []byte("FileNotFound"), []byte("panic:")} {
		if bytes.Contains(head, marker) {
			return fmt.Errorf("文件头含错误特征 %q (产物被 stderr 污染?)", marker)
		}
	}
	orphans := 0
	var first uint64
	for _, m := range hashRE.FindAllSubmatch(data, -1) {
		h, err := parseU64(m[1])
		if err != nil {
			continue
		}
		if _, ok := hashes[h]; !ok {
			if orphans == 0 {
				first = h
			}
			orphans++
		}
	}
	if orphans > 0 {
		return fmt.Errorf("%d 个孤儿 hash (首个: %d)", orphans, first)
	}
	return nil
}

func parseU64(b []byte) (uint64, error) {
	var v uint64
	for _, c := range b {
		if c < '0' || c > '9' {
			return 0, fmt.Errorf("非数字")
		}
		v = v*10 + uint64(c-'0')
	}
	return v, nil
}
