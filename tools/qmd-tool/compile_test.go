package main

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// TestCompileQMD_GoldenAgainstPython:
// 用真实仓库的 hashtab + qmd-src/*.qmd + qmd/*.qmd 跑 compileQMD,
// 跟 dist/*.qmd (CI/install.sh 用 Python tools/hash-qmd.py 生成的产物) 做 byte-for-byte 对比.
//
// 这个测试是"防退化保险": 任何对 compile.go / hashtab.go 的改动如果让输出
// 跟 Python 老版本不一致, CI 就会立刻失败. 等 dist 全部由 Go 生成、Python
// 版本归档之后, 这个 golden 仍然能用 (因为 dist/ 是产物, 由 Go 重新生成的
// 输出会更新 dist/, 测试只是 self-consistency check).
func TestCompileQMD_GoldenAgainstPython(t *testing.T) {
	root := repoRoot(t)
	hashtab := filepath.Join(root, "tools", "hashtab")
	if _, err := os.Stat(hashtab); err != nil {
		t.Skipf("跳过: 找不到 %s (本地未同步设备 hashtab)", hashtab)
	}

	table, err := loadHashtab(hashtab)
	if err != nil {
		t.Fatalf("loadHashtab: %v", err)
	}
	if len(table) < 100 {
		t.Fatalf("hashtab 异常小 (%d 条), 可能是种子残留", len(table))
	}

	cases := []struct {
		src  string
		dist string
	}{
		{"qmd-src/advanced_panel.qmd", "dist/advanced_panel.qmd"},
		{"qmd-src/language_zh_cn.qmd", "dist/language_zh_cn.qmd"},
		{"qmd-src/ai_text_button.qmd", "dist/ai_text_button.qmd"},
	}
	for _, tc := range cases {
		tc := tc
		t.Run(filepath.Base(tc.src), func(t *testing.T) {
			srcAbs := filepath.Join(root, tc.src)
			distAbs := filepath.Join(root, tc.dist)
			if _, err := os.Stat(distAbs); err != nil {
				t.Skipf("跳过: 找不到 golden %s (CI/PC 还没跑过 install.sh 重编)", tc.dist)
			}
			src, err := os.ReadFile(srcAbs)
			if err != nil {
				t.Fatal(err)
			}
			want, err := os.ReadFile(distAbs)
			if err != nil {
				t.Fatal(err)
			}
			got := compileQMD(string(src), table)
			if got != string(want) {
				// 只报前 200 字节差异 (避免日志爆炸)
				gotPrefix, wantPrefix := got, string(want)
				if len(gotPrefix) > 200 {
					gotPrefix = gotPrefix[:200]
				}
				if len(wantPrefix) > 200 {
					wantPrefix = wantPrefix[:200]
				}
				t.Errorf("%s 输出与 dist/ golden 不一致\n  GOT  (前200): %q\n  WANT (前200): %q",
					tc.src, gotPrefix, wantPrefix)
			}
		})
	}
}

// TestLoadHashtab_BasicSanity: hashtab 至少有一些条目, 跳过 hash=0 占位项.
func TestLoadHashtab_BasicSanity(t *testing.T) {
	root := repoRoot(t)
	hashtab := filepath.Join(root, "tools", "hashtab")
	if _, err := os.Stat(hashtab); err != nil {
		t.Skipf("跳过: 找不到 %s", hashtab)
	}
	table, err := loadHashtab(hashtab)
	if err != nil {
		t.Fatal(err)
	}
	if len(table) < 100 {
		t.Errorf("hashtab 解析出来才 %d 条, 太少", len(table))
	}
	for ident, h := range table {
		if h == 0 {
			t.Errorf("identifier %q 的 hash 为 0 (本应跳过)", ident)
		}
		if ident == "" {
			t.Error("出现空 identifier")
		}
	}
}

// repoRoot: 沿父目录找到含 go.mod 之外的项目根 (找 .github 或 README.md 锚点).
func repoRoot(t *testing.T) string {
	t.Helper()
	cwd, err := os.Getwd()
	if err != nil {
		t.Fatal(err)
	}
	dir := cwd
	for i := 0; i < 6; i++ {
		// 项目根标识: 含 README.md + qmd-src 目录
		if _, err := os.Stat(filepath.Join(dir, "README.md")); err == nil {
			if _, err := os.Stat(filepath.Join(dir, "qmd-src")); err == nil {
				return dir
			}
		}
		parent := filepath.Dir(dir)
		if parent == dir {
			break
		}
		dir = parent
	}
	t.Skipf("找不到项目根 (从 %s 向上未发现 README.md + qmd-src)", cwd)
	return ""
}

// TestKeywords_NotReplaced: KEYWORDS 集合里的词即使在 hashtab 里有映射也不能被替换.
func TestKeywords_NotReplaced(t *testing.T) {
	table := map[string]uint64{
		"string":   1234567890123456789,
		"function": 9876543210987654321,
		"MyType":   5555555555555555555,
	}
	got := replaceIdents("property string text; function foo() { return MyType; }", table, "[[%d]]")
	for _, kw := range []string{"property", "string", "function"} {
		if !strings.Contains(got, kw) {
			t.Errorf("关键字 %q 被替换了, 输出: %q", kw, got)
		}
	}
	if !strings.Contains(got, "[[5555555555555555555]]") {
		t.Errorf("MyType 未替换, 输出: %q", got)
	}
}
