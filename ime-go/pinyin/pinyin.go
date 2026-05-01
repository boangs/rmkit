package pinyin

import (
	_ "embed"
	"encoding/binary"
	"encoding/json"
	"sort"
	"strings"
	"unicode"

	"github.com/blevesearch/vellum"
)

//go:embed dict/chardict.json
var chardictJSON []byte

//go:embed dict/phrases.fst
var phrasesFSTBytes []byte

//go:embed dict/phrases.dat
var phrasesDatBytes []byte

//go:embed dict/abbrev.fst
var abbrevFSTBytes []byte

//go:embed dict/abbrev.dat
var abbrevDatBytes []byte

const MaxCandidates = 40

// Engine 拼音输入引擎
//
// chardict 体积小 (~44KB) 仍用 JSON,启动即反序列化,查询 O(1) map
// phrases / abbrev 走 FST + side table:
//   - FST (vellum) 负责 key → offset 查询,只读结构,零反序列化
//   - dat 字节切片存 varint 编码的字符串列表,按 offset 读取
//
// 三张表都是只读、可并发访问。
type Engine struct {
	buffer      string
	charDict    map[string][]string // pinyin → 单字列表(按频率降序)
	phrasesFST  *vellum.FST
	phrasesDat  []byte
	abbrevFST   *vellum.FST
	abbrevDat   []byte
	syllableSet map[string]bool
}

// NewEngine 创建拼音引擎
func NewEngine() *Engine {
	e := &Engine{
		charDict:    make(map[string][]string),
		syllableSet: make(map[string]bool),
	}
	_ = json.Unmarshal(chardictJSON, &e.charDict)
	for syl := range e.charDict {
		e.syllableSet[syl] = true
	}

	var err error
	e.phrasesFST, err = vellum.Load(phrasesFSTBytes)
	if err != nil {
		panic("load phrases.fst: " + err.Error())
	}
	e.phrasesDat = phrasesDatBytes

	e.abbrevFST, err = vellum.Load(abbrevFSTBytes)
	if err != nil {
		panic("load abbrev.fst: " + err.Error())
	}
	e.abbrevDat = abbrevDatBytes

	return e
}

func (e *Engine) Buffer() string { return e.buffer }

func (e *Engine) Append(ch rune) {
	if unicode.IsLetter(ch) {
		e.buffer += string(unicode.ToLower(ch))
	}
}

func (e *Engine) Backspace() {
	if len(e.buffer) > 0 {
		e.buffer = e.buffer[:len(e.buffer)-1]
	}
}

func (e *Engine) Clear() { e.buffer = "" }

// Candidates 返回当前缓冲区的候选词
func (e *Engine) Candidates() []string {
	return e.CandidatesFor(e.buffer)
}

// CandidatesFor 根据给定输入返回候选词。无状态、并发安全:
// 所有查询数据结构(map / FST / byte slice)都是只读的。
func (e *Engine) CandidatesFor(input string) []string {
	if input == "" {
		return nil
	}

	var cands []string
	seen := make(map[string]bool)
	add := func(ss ...string) {
		for _, s := range ss {
			if s != "" && !seen[s] {
				seen[s] = true
				cands = append(cands, s)
			}
		}
	}

	// 1. 单音节直接查
	if chars, ok := e.charDict[input]; ok {
		add(chars...)
	}

	// 2. 音节切分 → 词组 + 组合
	// 遍历所有合法切分(如 guanai → [guan ai] 和 [gua nai]),
	// 按音节数升序(更少音节通常更准)优先匹配词组,失败再回退组合字
	segsList := e.allSegments(input)
	// 音节数少 → 靠前; 同音节数时首音节更长的切分靠前(guan ai 优先于 gua nai)
	sort.SliceStable(segsList, func(i, j int) bool {
		a, b := segsList[i], segsList[j]
		if len(a) != len(b) {
			return len(a) < len(b)
		}
		if len(a) > 0 && len(a[0]) != len(b[0]) {
			return len(a[0]) > len(b[0])
		}
		return false
	})
	for _, segs := range segsList {
		if len(segs) < 2 {
			continue
		}
		key := strings.Join(segs, " ")
		add(lookupList(e.phrasesFST, e.phrasesDat, key)...)
		add(e.combineChars(segs)...)
	}

	// 3. 缩写匹配(如 zg → 中国)仅在输入长度 >=2 且没匹配到任何候选时启用
	if len(cands) == 0 && len(input) >= 2 && isAllInitials(input) {
		add(lookupList(e.abbrevFST, e.abbrevDat, input)...)
	}

	return limit(cands)
}

// lookupList 按 key 在 FST 中定位 offset,从 side table dat 解码字符串列表。
// miss 或解码失败返回 nil。
func lookupList(fst *vellum.FST, dat []byte, key string) []string {
	offset, ok, err := fst.Get([]byte(key))
	if err != nil || !ok {
		return nil
	}
	return decodeList(dat, offset)
}

// decodeList 从 dat[offset:] 读 [varint count][varint len + utf8]...
func decodeList(dat []byte, offset uint64) []string {
	if offset > uint64(len(dat)) {
		return nil
	}
	b := dat[offset:]
	count, n := binary.Uvarint(b)
	if n <= 0 {
		return nil
	}
	b = b[n:]
	out := make([]string, 0, count)
	for i := uint64(0); i < count; i++ {
		ln, m := binary.Uvarint(b)
		if m <= 0 {
			return out
		}
		b = b[m:]
		if uint64(len(b)) < ln {
			return out
		}
		out = append(out, string(b[:ln]))
		b = b[ln:]
	}
	return out
}

// allSegments 用 DP 返回所有合法的音节切分序列
// 比如 guanai 会返回 [[guan ai], [gua nai]]
// 每个 dp[i] 节点保留最多 maxPathsPerNode 条路径,防止长输入时组合爆炸
func (e *Engine) allSegments(input string) [][]string {
	const maxPathsPerNode = 8
	n := len(input)
	dp := make([][][]string, n+1)
	dp[0] = [][]string{{}}

	for i := 0; i <= n; i++ {
		if dp[i] == nil {
			continue
		}
		for l := i + 1; l <= min(i+6, n); l++ {
			syl := input[i:l]
			if !e.syllableSet[syl] {
				continue
			}
			for _, path := range dp[i] {
				if len(dp[l]) >= maxPathsPerNode {
					break
				}
				newPath := make([]string, len(path)+1)
				copy(newPath, path)
				newPath[len(path)] = syl
				dp[l] = append(dp[l], newPath)
			}
		}
	}
	return dp[n]
}

// combineChars 把每个音节的首选字拼起来
func (e *Engine) combineChars(segs []string) []string {
	top := make([]string, len(segs))
	for i, syl := range segs {
		chars, ok := e.charDict[syl]
		if !ok || len(chars) == 0 {
			return nil
		}
		top[i] = chars[0]
	}
	return []string{strings.Join(top, "")}
}

// isAllInitials 检查是否全是声母字符（单字母，非韵母）
// 当输入能被成功音节切分时，不走缩写路径
func isAllInitials(s string) bool {
	for _, c := range s {
		if c < 'a' || c > 'z' {
			return false
		}
	}
	return true
}

func limit(cands []string) []string {
	if len(cands) > MaxCandidates {
		return cands[:MaxCandidates]
	}
	return cands
}

func min(a, b int) int {
	if a < b {
		return a
	}
	return b
}
