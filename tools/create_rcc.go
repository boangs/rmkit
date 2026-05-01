package main

import (
	"encoding/binary"
	"fmt"
	"os"
	"time"
)

// Qt 6 RCC v3 format writer
// Header (24 bytes, big-endian):
//   magic(4) + version(4) + treeOffset(4) + dataOffset(4) + namesOffset(4) + flags(4)
//
// Data section (big-endian):
//   [size_u32_BE][data_bytes]
//
// Names section (big-endian):
//   length(u16) + hash(u32, qt_hash) + utf16-be string
//
// Tree section (big-endian, 22 bytes per node):
//   For dirs:  nameOff(u32) + flags(u16) + childCount(u32) + firstChild(u32) + lastMod(u64)
//   For files: nameOff(u32) + flags(u16) + territory(u16) + language(u16) + dataOff(u32) + lastMod(u64)

const TREE_ENTRY_SIZE = 22

func main() {
	if len(os.Args) != 3 {
		fmt.Fprintf(os.Stderr, "Usage: %s <input_file> <output.rcc>\n", os.Args[0])
		os.Exit(1)
	}

	realFile := os.Args[1]
	outputRcc := os.Args[2]

	data, err := os.ReadFile(realFile)
	if err != nil {
		fmt.Fprintf(os.Stderr, "Failed to read %s: %v\n", realFile, err)
		os.Exit(1)
	}

	// Names (NO root "" entry)
	names := []string{"misc", "keyboards", "zh_CN", "keyboard_layout.json"}
	namesSection := buildNamesSection(names)

	// Calculate name byte offsets
	nameOffsets := make([]uint32, len(names))
	offset := uint32(0)
	for i, name := range names {
		nameOffsets[i] = offset
		offset += 2 + 4 + uint32(len(name)*2)
	}

	// Tree: 5 nodes (ROOT + 4 path components)
	// Root node: nameOff=0 (placeholder), firstChild=1
	// "misc": nameOff=0, firstChild=2
	// "keyboards": nameOff=14, firstChild=3
	// "zh_CN": nameOff=38, firstChild=4
	// "keyboard_layout.json": nameOff=54, FILE
	treeSection := buildTreeSection(nameOffsets)

	// Data section: [size_u32_BE][data_bytes]
	dataSection := make([]byte, 4+len(data))
	binary.BigEndian.PutUint32(dataSection, uint32(len(data)))
	copy(dataSection[4:], data)

	// Calculate offsets
	headerSize := 24
	dataOffset := headerSize
	nameOffset := dataOffset + len(dataSection)
	treeOffset := nameOffset + len(namesSection)

	buf := make([]byte, 0, treeOffset+len(treeSection))

	// Magic "qres"
	buf = append(buf, []byte("qres")...)
	// Version 3 (big-endian)
	verBuf := make([]byte, 4)
	binary.BigEndian.PutUint32(verBuf, 3)
	buf = append(buf, verBuf...)

	// Offsets (all big-endian u32)
	offBuf := make([]byte, 4)
	binary.BigEndian.PutUint32(offBuf, uint32(treeOffset))
	buf = append(buf, offBuf...)
	binary.BigEndian.PutUint32(offBuf, uint32(dataOffset))
	buf = append(buf, offBuf...)
	binary.BigEndian.PutUint32(offBuf, uint32(nameOffset))
	buf = append(buf, offBuf...)

	// Flags (0)
	buf = append(buf, 0, 0, 0, 0)

	// Sections
	buf = append(buf, dataSection...)
	buf = append(buf, namesSection...)
	buf = append(buf, treeSection...)

	err = os.WriteFile(outputRcc, buf, 0644)
	if err != nil {
		fmt.Fprintf(os.Stderr, "Failed to write %s: %v\n", outputRcc, err)
		os.Exit(1)
	}

	fmt.Printf("Created %s (%d bytes)\n", outputRcc, len(buf))
	fmt.Printf("  Header: %d bytes\n", headerSize)
	fmt.Printf("  Data: %d bytes (offset %d)\n", len(dataSection), dataOffset)
	fmt.Printf("  Names: %d bytes (offset %d)\n", len(namesSection), nameOffset)
	fmt.Printf("  Tree: %d bytes (offset %d)\n", len(treeSection), treeOffset)
}

func stringToUtf16BE(s string) []byte {
	result := make([]byte, len(s)*2)
	for i, r := range s {
		result[i*2] = byte(r >> 8)
		result[i*2+1] = byte(r & 0xFF)
	}
	return result
}

// qt_hash - Qt 6 qHash for QString (ELF hash with >>23 fold)
func qtHash(s string) uint32 {
	var h uint32
	for _, r := range s {
		uc := uint32(r)
		h = (h << 4) + uc
		g := h & 0xf0000000
		if g != 0 {
			h ^= g >> 23 // Qt 6 uses >>23, not >>24
		}
		h &= 0x0fffffff
	}
	return h
}

func buildNamesSection(names []string) []byte {
	totalSize := 0
	for _, name := range names {
		totalSize += 2 + 4 + len(name)*2
	}

	buf := make([]byte, totalSize)
	pos := 0

	for _, name := range names {
		utf16 := stringToUtf16BE(name)
		// Length (u16 BE)
		binary.BigEndian.PutUint16(buf[pos:], uint16(len(name)))
		pos += 2
		// Hash (u32 BE)
		binary.BigEndian.PutUint32(buf[pos:], qtHash(name))
		pos += 4
		// UTF-16BE string
		copy(buf[pos:], utf16)
		pos += len(utf16)
	}

	return buf
}

func buildTreeSection(nameOffsets []uint32) []byte {
	// 5 nodes: ROOT + 4 path components
	tree := make([]byte, 5*TREE_ENTRY_SIZE)

	// Node 0: ROOT (nameOff=0 placeholder) -> firstChild=1
	writeDirNode(tree, 0, 0, 1, 1)
	// Node 1: "misc" (nameOff=0) -> firstChild=2
	writeDirNode(tree, 1, nameOffsets[0], 1, 2)
	// Node 2: "keyboards" (nameOff=14) -> firstChild=3
	writeDirNode(tree, 2, nameOffsets[1], 1, 3)
	// Node 3: "zh_CN" (nameOff=38) -> firstChild=4
	writeDirNode(tree, 3, nameOffsets[2], 1, 4)
	// Node 4: "keyboard_layout.json" (nameOff=54), FILE
	writeFileNode(tree, 4, nameOffsets[3], 0)

	return tree
}

func writeDirNode(tree []byte, nodeIndex int, nameOffset uint32, childCount uint32, firstChild uint32) {
	base := nodeIndex * TREE_ENTRY_SIZE
	binary.BigEndian.PutUint32(tree[base:], nameOffset)    // 0-3
	binary.BigEndian.PutUint16(tree[base+4:], 0x02)        // 4-5 DIRECTORY
	binary.BigEndian.PutUint32(tree[base+6:], childCount)  // 6-9
	binary.BigEndian.PutUint32(tree[base+10:], firstChild) // 10-13
	// lastMod (8 bytes at 14-21) = 0
}

func writeFileNode(tree []byte, nodeIndex int, nameOffset uint32, dataOffset uint32) {
	base := nodeIndex * TREE_ENTRY_SIZE
	binary.BigEndian.PutUint32(tree[base:], nameOffset)     // 0-3
	binary.BigEndian.PutUint16(tree[base+4:], 0x00)         // 4-5 FILE
	binary.BigEndian.PutUint16(tree[base+6:], 0)            // 6-7 territory
	binary.BigEndian.PutUint16(tree[base+8:], 1)            // 8-9 language (QLocale::AnyLanguage)
	binary.BigEndian.PutUint32(tree[base+10:], dataOffset)  // 10-13
	// lastMod (8 bytes at 14-21): Unix timestamp in milliseconds
	now := time.Now().UnixMilli()
	binary.BigEndian.PutUint64(tree[base+14:], uint64(now)) // 14-21
}
