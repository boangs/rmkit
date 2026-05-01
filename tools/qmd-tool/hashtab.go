package main

import (
	"encoding/binary"
	"fmt"
	"os"
)

// hashtab 二进制格式 (与设备 xovi/qt-resource-rebuilder 写出格式一致):
//
//	repeat:
//	    u64 BE  hash
//	    u32 BE  len
//	    bytes   identifier (utf-8, len 字节)
//
// 第一条记录通常是 hash=0 占位 + ASCII header ("Hashtab file for QMLDIFF..."),
// 之后是 (固件版本字符串 → 版本魔数) 等系统级条目, 再后是真正的 identifier 映射.

// loadHashtab 读 hashtab 文件, 返回 identifier → hash 映射.
// hash=0 的条目跳过 (header 占位).
func loadHashtab(path string) (map[string]uint64, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, fmt.Errorf("读 %s: %w", path, err)
	}
	table := make(map[string]uint64, 1024)
	for pos := 0; pos+12 <= len(data); {
		h := binary.BigEndian.Uint64(data[pos : pos+8])
		n := int(binary.BigEndian.Uint32(data[pos+8 : pos+12]))
		end := pos + 12 + n
		if end > len(data) {
			break
		}
		ident := string(data[pos+12 : end])
		if h != 0 && ident != "" {
			table[ident] = h
		}
		pos = end
	}
	return table, nil
}

// loadHashSet 读 hashtab 文件, 返回所有非零 hash 的集合 (用于 check 子命令的命中校验).
func loadHashSet(path string) (map[uint64]struct{}, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, fmt.Errorf("读 %s: %w", path, err)
	}
	hashes := make(map[uint64]struct{}, 1024)
	for pos := 0; pos+12 <= len(data); {
		h := binary.BigEndian.Uint64(data[pos : pos+8])
		n := int(binary.BigEndian.Uint32(data[pos+8 : pos+12]))
		end := pos + 12 + n
		if end > len(data) {
			break
		}
		if h != 0 {
			hashes[h] = struct{}{}
		}
		pos = end
	}
	return hashes, nil
}
