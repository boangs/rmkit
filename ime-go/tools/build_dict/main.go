//go:build ignore

// 从 gaboolic/rime-frost 的 cn_dicts/ 目录生成 chardict.json / phrases.json /
// abbrev.json 三份嵌入资源。
//
// 用法：
//
//	go run tools/build_dict/main.go /path/to/rime-frost/cn_dicts
//
// 输入文件（均为 RIME 标准 dict.yaml 格式）：
//
//	8105.dict.yaml    — 通用规范汉字表字频（单字）
//	41448.dict.yaml   — 大字表字频（生僻字兜底）
//	base.dict.yaml    — 核心词库（带频率）
//	ext.dict.yaml     — 扩展词库（带频率）
//	others.dict.yaml  — 容错词/口语读音
//
// RIME dict.yaml 数据区格式（`...` 分隔符之后）：
//
//	词\t拼音（空格分隔音节）\t频率
//	关联\tguan lian\t123
//
// ü 注音用 `v`；和 pinyin 引擎 buffer 一致。
package main

import (
	"bufio"
	"bytes"
	"encoding/binary"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"

	"github.com/blevesearch/vellum"
)

const (
	maxCharsPerPinyin   = 20
	maxPhrasesPerPinyin = 8
	maxAbbrevPerKey     = 8
	maxWordRunes        = 4  // 词最大长度，过滤罕见长词
	minCharReadingFreq  = 0  // chardict 最小字频阈值
	minPhraseFreq       = 0  // phrases 最小词频阈值（>=0 才收录）
)

type entry struct {
	word   string
	pinyin string // 空格分隔音节
	freq   int64
}

func main() {
	if len(os.Args) < 2 {
		fmt.Fprintln(os.Stderr, "usage: build_dict <rime-frost/cn_dicts>")
		os.Exit(1)
	}
	dir := os.Args[1]

	// 单字字表：8105（主）+ 41448（兜底）
	charEntries := loadRimeDict(filepath.Join(dir, "8105.dict.yaml"))
	charEntries = append(charEntries, loadRimeDict(filepath.Join(dir, "41448.dict.yaml"))...)

	// 多字词表：base + ext + others
	phraseEntries := loadRimeDict(filepath.Join(dir, "base.dict.yaml"))
	phraseEntries = append(phraseEntries, loadRimeDict(filepath.Join(dir, "ext.dict.yaml"))...)
	phraseEntries = append(phraseEntries, loadRimeDict(filepath.Join(dir, "others.dict.yaml"))...)

	// ── chardict：每个 pinyin 下按字频降序 ───────────────────────────
	chardictRaw := make(map[string]map[string]int64) // pinyin → char → freq
	for _, e := range charEntries {
		if len([]rune(e.word)) != 1 {
			continue
		}
		if strings.Contains(e.pinyin, " ") {
			continue // 8105 里理论不出现，防御一下
		}
		if e.freq < minCharReadingFreq {
			continue
		}
		if chardictRaw[e.pinyin] == nil {
			chardictRaw[e.pinyin] = make(map[string]int64)
		}
		// 同音同字在 8105/41448 都出现时取较大频率
		if f := chardictRaw[e.pinyin][e.word]; e.freq > f {
			chardictRaw[e.pinyin][e.word] = e.freq
		}
	}
	chardictOut := make(map[string][]string, len(chardictRaw))
	for py, m := range chardictRaw {
		type scored struct {
			ch string
			f  int64
		}
		list := make([]scored, 0, len(m))
		for ch, f := range m {
			list = append(list, scored{ch, f})
		}
		sort.Slice(list, func(i, j int) bool { return list[i].f > list[j].f })
		if len(list) > maxCharsPerPinyin {
			list = list[:maxCharsPerPinyin]
		}
		out := make([]string, len(list))
		for i, s := range list {
			out[i] = s.ch
		}
		chardictOut[py] = out
	}

	// ── phrases：每个 pinyin key 下按词频降序，同 key 同词取最高频 ─
	type wf struct {
		word string
		freq int64
	}
	phrasesRaw := make(map[string]map[string]int64) // pyKey → word → freq
	for _, e := range phraseEntries {
		runes := []rune(e.word)
		if len(runes) < 2 || len(runes) > maxWordRunes {
			continue
		}
		if e.freq < minPhraseFreq {
			continue
		}
		if !allCJK(e.word) {
			continue
		}
		if phrasesRaw[e.pinyin] == nil {
			phrasesRaw[e.pinyin] = make(map[string]int64)
		}
		if f := phrasesRaw[e.pinyin][e.word]; e.freq > f {
			phrasesRaw[e.pinyin][e.word] = e.freq
		}
	}
	phrasesOut := make(map[string][]string, len(phrasesRaw))
	for py, m := range phrasesRaw {
		list := make([]wf, 0, len(m))
		for w, f := range m {
			list = append(list, wf{w, f})
		}
		sort.Slice(list, func(i, j int) bool { return list[i].freq > list[j].freq })
		if len(list) > maxPhrasesPerPinyin {
			list = list[:maxPhrasesPerPinyin]
		}
		out := make([]string, len(list))
		for i, s := range list {
			out[i] = s.word
		}
		phrasesOut[py] = out
	}

	// ── abbrev：按音节首字母聚合，每组取首选词，按词频排序 ────────
	type absc struct {
		word string
		freq int64
	}
	abbrevRaw := make(map[string][]absc)
	for py, words := range phrasesOut {
		if len(words) == 0 {
			continue
		}
		segs := strings.Fields(py)
		b := make([]byte, len(segs))
		for i, s := range segs {
			b[i] = s[0]
		}
		ab := string(b)
		top := words[0]
		topFreq := phrasesRaw[py][top]
		abbrevRaw[ab] = append(abbrevRaw[ab], absc{top, topFreq})
	}
	abbrevOut := make(map[string][]string, len(abbrevRaw))
	for ab, list := range abbrevRaw {
		// 去重（同词可能来自不同 pyKey）
		seen := make(map[string]int64)
		for _, s := range list {
			if s.freq > seen[s.word] {
				seen[s.word] = s.freq
			}
		}
		uniq := make([]absc, 0, len(seen))
		for w, f := range seen {
			uniq = append(uniq, absc{w, f})
		}
		sort.Slice(uniq, func(i, j int) bool { return uniq[i].freq > uniq[j].freq })
		if len(uniq) > maxAbbrevPerKey {
			uniq = uniq[:maxAbbrevPerKey]
		}
		out := make([]string, len(uniq))
		for i, s := range uniq {
			out[i] = s.word
		}
		abbrevOut[ab] = out
	}

	// ── 写出 ─────────────────────────────────────────────────────
	// chardict 体积小 (~44KB),保留 JSON,反序列化几乎零开销
	// phrases/abbrev 大 (~18MB 合计),走 FST + side table:
	//   .fst 文件 key → offset (uint64)
	//   .dat 文件 offset 处是 [varint count][varint len + utf8 bytes]...
	writeJSON("pinyin/dict/chardict.json", chardictOut)
	phrasesFSTSize, phrasesDatSize := writeFST(
		"pinyin/dict/phrases.fst", "pinyin/dict/phrases.dat", phrasesOut)
	abbrevFSTSize, abbrevDatSize := writeFST(
		"pinyin/dict/abbrev.fst", "pinyin/dict/abbrev.dat", abbrevOut)
	fmt.Printf("chardict.json: %d pinyin entries\n", len(chardictOut))
	fmt.Printf("phrases.fst:  %d entries, fst=%d bytes, dat=%d bytes\n",
		len(phrasesOut), phrasesFSTSize, phrasesDatSize)
	fmt.Printf("abbrev.fst:   %d entries, fst=%d bytes, dat=%d bytes\n",
		len(abbrevOut), abbrevFSTSize, abbrevDatSize)

	// sanity check
	for _, p := range []string{"ni", "shi", "zhong", "guo", "hao", "guan", "lian", "ai"} {
		out := chardictOut[p]
		if len(out) > 5 {
			out = out[:5]
		}
		fmt.Printf("  %s → %v\n", p, out)
	}
	for _, p := range []string{"ni hao", "zhong guo", "bei jing", "shang hai", "guan lian", "guan ai", "guan yu", "ni shi shui"} {
		fmt.Printf("  %q → %v\n", p, phrasesOut[p])
	}
	for _, p := range []string{"zg", "bj", "nh", "zgr", "bjdx"} {
		fmt.Printf("  abbrev %q → %v\n", p, abbrevOut[p])
	}
}

// loadRimeDict 读取 RIME 标准 .dict.yaml 数据区
func loadRimeDict(path string) []entry {
	f, err := os.Open(path)
	if err != nil {
		panic(err)
	}
	defer f.Close()

	var out []entry
	s := bufio.NewScanner(f)
	s.Buffer(make([]byte, 1024*1024), 1024*1024)
	inData := false
	for s.Scan() {
		line := s.Text()
		if !inData {
			if strings.TrimSpace(line) == "..." {
				inData = true
			}
			continue
		}
		if strings.HasPrefix(line, "#") || line == "" {
			continue
		}
		parts := strings.Split(line, "\t")
		if len(parts) < 2 {
			continue
		}
		word := parts[0]
		pinyin := strings.TrimSpace(parts[1])
		if pinyin == "" {
			continue
		}
		var freq int64
		if len(parts) >= 3 {
			if v, err := strconv.ParseInt(strings.TrimSpace(parts[2]), 10, 64); err == nil {
				freq = v
			}
		}
		out = append(out, entry{word, pinyin, freq})
	}
	return out
}

func writeJSON(path string, v any) {
	b, err := json.Marshal(v)
	if err != nil {
		panic(err)
	}
	if err := os.WriteFile(path, b, 0644); err != nil {
		panic(err)
	}
}

// writeFST 把 map[string][]string 写成 FST + 紧凑 side table。
// 返回 fst 和 dat 的字节数。
//
// FST: key → uint64 offset（vellum 要求 key 严格递增,所以先排序）
// dat: 在 offset 处按顺序存放
//
//	varint count          -- 该 key 对应的字符串个数
//	for each str:
//	  varint len + bytes
//
// 查询路径：fst.Get(key) → offset → 读 dat[offset:] 解码出 []string
func writeFST(fstPath, datPath string, m map[string][]string) (int64, int64) {
	keys := make([]string, 0, len(m))
	for k := range m {
		keys = append(keys, k)
	}
	sort.Strings(keys)

	var dat bytes.Buffer
	var fstBuf bytes.Buffer
	builder, err := vellum.New(&fstBuf, nil)
	if err != nil {
		panic(err)
	}

	varintBuf := make([]byte, binary.MaxVarintLen64)
	for _, k := range keys {
		offset := uint64(dat.Len())
		words := m[k]

		n := binary.PutUvarint(varintBuf, uint64(len(words)))
		dat.Write(varintBuf[:n])
		for _, w := range words {
			wb := []byte(w)
			n = binary.PutUvarint(varintBuf, uint64(len(wb)))
			dat.Write(varintBuf[:n])
			dat.Write(wb)
		}

		if err := builder.Insert([]byte(k), offset); err != nil {
			panic(fmt.Errorf("insert %q: %w", k, err))
		}
	}
	if err := builder.Close(); err != nil {
		panic(err)
	}

	if err := os.WriteFile(fstPath, fstBuf.Bytes(), 0644); err != nil {
		panic(err)
	}
	if err := os.WriteFile(datPath, dat.Bytes(), 0644); err != nil {
		panic(err)
	}
	return int64(fstBuf.Len()), int64(dat.Len())
}

func allCJK(s string) bool {
	for _, r := range s {
		if r < 0x4E00 || r > 0x9FFF {
			return false
		}
	}
	return true
}
