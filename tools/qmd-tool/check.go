package main

import (
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strconv"
)

// hashRE: 提取 dist/*.qmd 里的 hash 引用.
// 三种形式 (跟 compileQMD 输出一致):
//   - [[1234567890123456789]]   AFFECT/TRAVERSE/LOCATE 行
//   - ~&1234567890123456789&~   INSERT 块内部 identifier
//   - ~&"1234567890123456789&~  INSERT 块内部字符串字面量整体命中
//
// 19 位左右 u64, 这里宽松 15-21 位 (跟 Python 版一致).
var hashRE = regexp.MustCompile(`(?:\[\[|~&"?)(\d{15,21})(?:\]\]|&~)`)

// checkQMD: 扫 qmdDir 下所有 *.qmd, 校验 hash 都在 hashtabDir 下任一 hashtab-* 的并集中.
// 返回 (孤儿文件数, error). 孤儿存在时退出码应为 1.
func checkQMD(hashtabDir, qmdDir string) (int, error) {
	st, err := os.Stat(hashtabDir)
	if err != nil || !st.IsDir() {
		return 0, fmt.Errorf("FATAL: %s 不存在", hashtabDir)
	}

	fmt.Printf("=== 加载 hashtabs (来自 %s) ===\n", hashtabDir)
	matches, err := filepath.Glob(filepath.Join(hashtabDir, "hashtab-*"))
	if err != nil {
		return 0, err
	}
	sort.Strings(matches)
	if len(matches) == 0 {
		return 0, fmt.Errorf("FATAL: %s 下没有 hashtab-* 文件", hashtabDir)
	}
	union := make(map[uint64]struct{}, 1024)
	for _, f := range matches {
		hashes, err := loadHashSet(f)
		if err != nil {
			return 0, err
		}
		for h := range hashes {
			union[h] = struct{}{}
		}
		fmt.Printf("  %-50s %6d hashes\n", filepath.Base(f), len(hashes))
	}
	fmt.Printf("  合并: %d unique hashes\n", len(union))

	if st, err := os.Stat(qmdDir); err != nil || !st.IsDir() {
		fmt.Printf("WARN: %s 不存在, 跳过 qmd 校验\n", qmdDir)
		return 0, nil
	}
	qmdFiles, err := filepath.Glob(filepath.Join(qmdDir, "*.qmd"))
	if err != nil {
		return 0, err
	}
	sort.Strings(qmdFiles)
	if len(qmdFiles) == 0 {
		fmt.Printf("WARN: %s/*.qmd 为空, 跳过校验\n", qmdDir)
		return 0, nil
	}

	fmt.Printf("\n=== 校验 qmd hash 命中 (%d files) ===\n", len(qmdFiles))
	bad := 0
	for _, qmd := range qmdFiles {
		data, err := os.ReadFile(qmd)
		if err != nil {
			return 0, err
		}
		seen := make(map[uint64]struct{}, 64)
		var orphans []uint64
		matches := hashRE.FindAllSubmatch(data, -1)
		for _, m := range matches {
			h, err := strconv.ParseUint(string(m[1]), 10, 64)
			if err != nil {
				continue
			}
			if _, dup := seen[h]; dup {
				continue
			}
			seen[h] = struct{}{}
			if _, ok := union[h]; !ok {
				orphans = append(orphans, h)
			}
		}
		rel, _ := filepath.Rel(filepath.Dir(qmdDir), qmd)
		if len(orphans) > 0 {
			bad++
			fmt.Printf("  ✗ %s  (孤儿 %d/%d)\n", rel, len(orphans), len(seen))
			for _, h := range orphans {
				fmt.Printf("      ORPHAN %d\n", h)
			}
		} else {
			fmt.Printf("  ✓ %s  (%d hash 命中)\n", rel, len(seen))
		}
	}

	if bad > 0 {
		fmt.Printf("\n*** %d 个 qmd 文件含孤儿 hash ***\n", bad)
		fmt.Println("修复: 移到 qmd/_obsolete/, 或 rebuild_hashtable on device 后重新生成快照")
	} else {
		fmt.Println("\nALL OK — 所有 qmd hash 校验通过")
	}
	return bad, nil
}
