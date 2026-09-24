package space

import (
	"encoding/json"
	"net/http"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"
)

// 最近阅读: 给「空间」首页的「正在进行」卡片用。
//
// 数据就在 xochitl 自己的文档目录里, 不需要动 xochitl:
//   <uuid>.metadata  {"visibleName": 书名, "lastOpened": 毫秒时间戳, "lastOpenedPage": 页码, "type": "DocumentType"}
//   <uuid>.content   {"pageCount": 总页数, "fileType": "pdf"/"epub"/"notebook"}
//
// 注意: 设备上文档常有三四百份, .content 动辄几百 KB (逐页记录), 所以
//   1. 只读 .metadata 挑出最近打开的那几份, 再去读它们的 .content;
//   2. 结果缓存一小段时间, 首页每次重挂小组件不会把磁盘刷一遍。

const (
	xochitlDir     = "/home/root/.local/share/remarkable/xochitl"
	recentCacheTTL = 60 * time.Second
	recentScanTop  = 3 // 只为最近的这几份读 .content
)

type RecentDoc struct {
	Name     string `json:"name"`
	Page     int    `json:"page"`     // 上次看到第几页 (从 1 算)
	Pages    int    `json:"pages"`    // 总页数, 0 = 未知
	Percent  int    `json:"percent"`  // 进度百分比, Pages 为 0 时也是 0
	OpenedAt int64  `json:"openedAt"` // 毫秒时间戳
	Kind     string `json:"kind"`     // pdf / epub / notebook
}

type recentCache struct {
	mu   sync.Mutex
	at   time.Time
	doc  *RecentDoc
	docs []RecentDoc
}

var recents recentCache

// DocsDir 允许测试或别的机型改目录; 空则用默认值。
var DocsDir = ""

func docsDir() string {
	if DocsDir != "" {
		return DocsDir
	}
	return xochitlDir
}

type rawMeta struct {
	VisibleName    string `json:"visibleName"`
	LastModified   string `json:"lastModified"`
	LastOpened     string `json:"lastOpened"`
	LastOpenedPage int    `json:"lastOpenedPage"`
	Type           string `json:"type"`
	Deleted        bool   `json:"deleted"`
	Parent         string `json:"parent"`
}

type rawContent struct {
	PageCount int    `json:"pageCount"`
	FileType  string `json:"fileType"`
}

// scanRecent 返回按上次打开时间倒序的文档 (最多 n 份, 且只有前 recentScanTop 份带总页数)。
func scanRecent(n int) []RecentDoc {
	dir := docsDir()
	ents, err := os.ReadDir(dir)
	if err != nil {
		return nil
	}
	type item struct {
		id string
		m  rawMeta
		at int64
	}
	var items []item
	for _, e := range ents {
		name := e.Name()
		if !strings.HasSuffix(name, ".metadata") {
			continue
		}
		b, err := os.ReadFile(filepath.Join(dir, name))
		if err != nil {
			continue
		}
		var m rawMeta
		if json.Unmarshal(b, &m) != nil {
			continue
		}
		// 回收站里的、文件夹、没打开过的都跳过
		if m.Deleted || m.Type != "DocumentType" || m.LastOpened == "" || m.Parent == "trash" {
			continue
		}
		// 排序用 lastModified, 与设备文档列表默认的「修改时间」一致:
		// 光打开不做批注只会更新 lastOpened, 于是会出现"列表第一本"与
		// "最近打开"不是同一本的情况, 以用户看到的那个顺序为准。
		at := parseMs(m.LastModified)
		if at == 0 {
			at = parseMs(m.LastOpened)
		}
		if at <= 0 || parseMs(m.LastOpened) <= 0 {
			continue // 从没打开过的不算"在读"
		}
		items = append(items, item{id: strings.TrimSuffix(name, ".metadata"), m: m, at: at})
	}
	sort.Slice(items, func(i, j int) bool { return items[i].at > items[j].at })
	if len(items) > n {
		items = items[:n]
	}

	out := make([]RecentDoc, 0, len(items))
	for i, it := range items {
		d := RecentDoc{
			Name:     strings.TrimSuffix(it.m.VisibleName, ".pdf"),
			Page:     it.m.LastOpenedPage + 1, // 元数据里是从 0 算的
			OpenedAt: it.at,
		}
		if i < recentScanTop {
			if c, ok := readContent(filepath.Join(dir, it.id+".content")); ok {
				d.Pages = c.PageCount
				d.Kind = c.FileType
			}
		}
		if d.Pages > 0 {
			if d.Page > d.Pages {
				d.Page = d.Pages
			}
			d.Percent = d.Page * 100 / d.Pages
		}
		out = append(out, d)
	}
	return out
}

// readContent 只取需要的两个字段。.content 可能有几百 KB (逐页记录),
// 但都在文件靠后, 直接解析整份最省事也够快 (实测三百多份文档只读前三份)。
func parseMs(v string) int64 {
	n, err := strconv.ParseInt(v, 10, 64)
	if err != nil {
		return 0
	}
	return n
}

func readContent(p string) (rawContent, bool) {
	b, err := os.ReadFile(p)
	if err != nil {
		return rawContent{}, false
	}
	var c rawContent
	if json.Unmarshal(b, &c) != nil {
		return rawContent{}, false
	}
	return c, true
}

// recent 返回最近在读的文档。?n=5 可要多份 (默认只给最近一份)。
func (h *Handler) recent(w http.ResponseWriter, r *http.Request) {
	n := 1
	if v := r.URL.Query().Get("n"); v != "" {
		if k, err := strconv.Atoi(v); err == nil && k > 0 && k <= 20 {
			n = k
		}
	}

	recents.mu.Lock()
	fresh := time.Since(recents.at) < recentCacheTTL && len(recents.docs) >= n
	if !fresh {
		recents.docs = scanRecent(maxInt(n, recentScanTop))
		recents.at = time.Now()
	}
	docs := recents.docs
	recents.mu.Unlock()

	if len(docs) > n {
		docs = docs[:n]
	}
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	if n == 1 {
		if len(docs) == 0 {
			_ = json.NewEncoder(w).Encode(map[string]any{"doc": nil})
			return
		}
		_ = json.NewEncoder(w).Encode(map[string]any{"doc": docs[0]})
		return
	}
	_ = json.NewEncoder(w).Encode(map[string]any{"docs": docs})
}

func maxInt(a, b int) int {
	if a > b {
		return a
	}
	return b
}
