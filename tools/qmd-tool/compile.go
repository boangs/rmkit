package main

import (
	"fmt"
	"regexp"
	"strconv"
	"strings"
)

// 与 tools/hash-qmd.py 行为完全一致:
// - AFFECT/TRAVERSE/LOCATE 等"外层"行: identifier 用 [[hash]] 形式
// - INSERT { ... } / REPLACE Component WITH { ... } 块内部: identifier 用 ~&hash&~,
//   字符串字面量整体命中 hashtab 时用 ~&"hash&~ (前导双引号)
// - 注释行 (`;` 开头) 原样输出
// - 关键字 (KEYWORDS) 永不替换, 即使它在 hashtab 里也不动 (避免破坏 typeof xxx === "string" 这类比较)

var (
	stringRE    = regexp.MustCompile(`"(?:\\.|[^"\\])*"|'(?:\\.|[^'\\])*'`)
	identRE     = regexp.MustCompile(`[A-Za-z_][A-Za-z0-9_]*`)
	dottedRE    = regexp.MustCompile(`[A-Za-z_][A-Za-z0-9_]*(?:\.[A-Za-z_][A-Za-z0-9_]*)+`)
	pathRE      = regexp.MustCompile(`/[^\s\[\]]+\.qml`)
	stashRE     = regexp.MustCompile(`\x00STR(\d+)\x00`)
)

// keywords: QMLDIFF 指令 + JS/QML 控制流 + QML 基本类型 + JS 字面值. 永不替换.
var keywords = map[string]bool{
	// QMLDIFF
	"AFFECT": true, "TRAVERSE": true, "LOCATE": true, "INSERT": true, "END": true,
	"BEFORE": true, "AFTER": true, "ALL": true,
	// JS/QML 控制流 + 声明
	"signal": true, "property": true, "function": true, "var": true, "let": true, "const": true,
	"if": true, "else": true, "for": true, "while": true, "do": true,
	"return": true, "break": true, "continue": true,
	"try": true, "catch": true, "throw": true, "finally": true,
	"new": true, "this": true, "void": true, "typeof": true, "instanceof": true, "in": true, "of": true,
	"switch": true, "case": true, "default": true,
	// QML 基本类型 (作为 property type 也作为 typeof 比较右值)
	"string": true, "int": true, "bool": true, "real": true, "double": true, "url": true, "color": true,
	"date": true, "point": true, "rect": true, "size": true, "font": true,
	"vector2d": true, "vector3d": true, "vector4d": true, "matrix4x4": true, "quaternion": true, "alias": true,
	// JS 字面值
	"true": true, "false": true, "null": true, "undefined": true, "NaN": true, "Infinity": true,
}

// replaceIdents: 用 wrapFmt (例如 "[[%d]]" 或 "~&%d&~") 替换 text 中命中 hashtab 的 identifier.
func replaceIdents(text string, table map[string]uint64, wrapFmt string) string {
	return identRE.ReplaceAllStringFunc(text, func(s string) string {
		if keywords[s] {
			return s
		}
		if h, ok := table[s]; ok {
			return fmt.Sprintf(wrapFmt, h)
		}
		return s
	})
}

// hashHeaderLine: 处理 AFFECT / TRAVERSE / LOCATE / REPLACE 这种外层行.
// 路径 (/foo/bar.qml) 优先按整体查 hashtab; 然后点分隔类型名 (A.B.C) 生成 [[hA.hB.hC]];
// 最后剩余 identifier 走 [[hash]] 形式.
func hashHeaderLine(text string, table map[string]uint64) string {
	text = pathRE.ReplaceAllStringFunc(text, func(s string) string {
		if h, ok := table[s]; ok {
			return fmt.Sprintf("[[%d]]", h)
		}
		return s
	})
	// 点分隔类型名 (如 ArkControls.ContextualMenu.Button) → [[hA.hB.hC]]
	// 必须在单个 identifier 替换之前处理，否则各段会被独立替换成 [[A]].[[B]].[[C]]
	text = dottedRE.ReplaceAllStringFunc(text, func(s string) string {
		parts := strings.Split(s, ".")
		hashes := make([]string, 0, len(parts))
		for _, p := range parts {
			if keywords[p] {
				return s // 含关键字，不替换整体
			}
			h, ok := table[p]
			if !ok {
				return s // 任意一段找不到，不替换整体
			}
			hashes = append(hashes, strconv.FormatUint(h, 10))
		}
		return "[[" + strings.Join(hashes, ".") + "]]"
	})
	return replaceIdents(text, table, "[[%d]]")
}

// hashInsertBody: 处理 INSERT/REPLACE 块内部一行.
// 步骤: 字符串字面量先抽出来用占位符替换 (避免 IDENT_RE 误命中字符串内容),
// 字面量内容若整体命中 hashtab 就替成 ~&"hash&~, 否则原样;
// 然后对剩余文本走 identifier 替换 (~&hash&~ 形式);
// 最后把占位符还原.
func hashInsertBody(text string, table map[string]uint64) string {
	var placeholders []string
	text = stringRE.ReplaceAllStringFunc(text, func(s string) string {
		// s 含两端引号
		inner := s[1 : len(s)-1]
		var replaced string
		if h, ok := table[inner]; ok && !keywords[inner] {
			replaced = fmt.Sprintf("~&\"%d&~", h)
		} else {
			replaced = s
		}
		placeholders = append(placeholders, replaced)
		return fmt.Sprintf("\x00STR%d\x00", len(placeholders)-1)
	})
	text = replaceIdents(text, table, "~&%d&~")
	text = stashRE.ReplaceAllStringFunc(text, func(s string) string {
		// s 形如 "\x00STR<N>\x00"
		n, err := strconv.Atoi(s[len("\x00STR") : len(s)-1])
		if err != nil || n < 0 || n >= len(placeholders) {
			return s
		}
		return placeholders[n]
	})
	return text
}

// compileQMD: 主入口. 行级扫描, 跟踪 INSERT/REPLACE 块的 brace depth.
func compileQMD(src string, table map[string]uint64) string {
	// 对齐 Python splitlines() 的行为: 末尾 trailing newline 不产生空字符串.
	src = strings.TrimRight(src, "\n")
	lines := strings.Split(src, "\n")

	out := make([]string, 0, len(lines))
	insertDepth := 0
	for _, line := range lines {
		stripped := strings.TrimLeft(line, " \t")
		if strings.HasPrefix(stripped, ";") {
			out = append(out, line)
			continue
		}

		if insertDepth == 0 {
			if strings.HasPrefix(stripped, "INSERT") {
				// INSERT { 这行外层不 hash, 内部 brace 数大于零则进入 block.
				opens := strings.Count(line, "{") - strings.Count(line, "}")
				out = append(out, line)
				if opens > 0 {
					insertDepth = opens
				}
			} else if strings.HasPrefix(stripped, "REPLACE") {
				// REPLACE Component WITH { ... }
				// 行本身的 Component 走 header 形式 hash, { 之后进入 body 模式.
				opens := strings.Count(line, "{") - strings.Count(line, "}")
				out = append(out, hashHeaderLine(line, table))
				if opens > 0 {
					insertDepth = opens
				}
			} else {
				out = append(out, hashHeaderLine(line, table))
			}
			continue
		}

		// 在 INSERT/REPLACE 块内.
		opens := strings.Count(line, "{") - strings.Count(line, "}")
		out = append(out, hashInsertBody(line, table))
		insertDepth += opens
		if insertDepth < 0 {
			insertDepth = 0
		}
	}

	return strings.Join(out, "\n") + "\n"
}
