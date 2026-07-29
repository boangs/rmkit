// Package rime 是 librime C API (rime_api.h) 的 cgo 封装。
//
// 设计要点:
//   - cgo preamble 直接 #include <rime_api.h>, 结构体字段由真头文件保证,
//     不在 Go 侧手抄 (抄错编译期即报错, 不留 silent bug)。
//   - 所有跨 C 结构体的字段提取用 C 辅助函数完成, Go 侧只碰标量和 char*,
//     避免 cgo 直接索引 C 数组 (RimeCandidate*) 的指针运算坑。
//   - librime 是进程内库: Init 一次, 每个输入焦点一个 Session, 按键流喂进去,
//     GetContext 取 preedit+候选, Commit 取已上屏文本。整句输入 + userdb
//     自学习都由 librime 内部完成, 我们只搬运 IO。
//
// 交叉编译: 依赖 librime + Boost/yaml-cpp/LevelDB/marisa/OpenCC 的静态库,
// 由 remarkable SDK 工具链编出 (见 tools/build-librime/)。本文件在没有这些
// 静态库的机器上无法 go build —— 用 build tag `librime` 隔离, 默认构建走
// pinyin 包的纯 Go 引擎, 交叉编译 IME 时才带 -tags librime。
//go:build librime

package rime

/*
#cgo CFLAGS: -I${SRCDIR}/../../third_party/librime/include
// cgo 指令只展开 ${SRCDIR}, 不认 ${GOARCH} —— 按架构分别用 arm64/arm 的 cgo 行,
// 由 GOARCH 自动选中对应那条 (文件级 build tag 无法区分, 用 cgo 的架构后缀指令)。
#cgo arm64 LDFLAGS: -L${SRCDIR}/../../third_party/librime/lib-arm64
#cgo arm   LDFLAGS: -L${SRCDIR}/../../third_party/librime/lib-arm
#cgo LDFLAGS: -lrime -lyaml-cpp -lleveldb -lmarisa -lopencc -lboost_regex -lglog -lstdc++ -lm -lpthread
#include <rime_api.h>
#include <stdlib.h>
#include <string.h>

// rime_get_api() 返回的 API 分发表, 首次调用缓存。
static RimeApi *g_api = NULL;
static RimeApi *api(void) {
    if (!g_api) g_api = rime_get_api();
    return g_api;
}

// ── 初始化 ────────────────────────────────────────────────────────
// distribution_name 等元信息对功能无影响, 仅用于日志/userdb 标识。
static void rime_bridge_setup(const char *shared, const char *user) {
    RIME_STRUCT(RimeTraits, traits);
    traits.shared_data_dir = shared;
    traits.user_data_dir = user;
    traits.distribution_name = "rmkit-cn";
    traits.distribution_code_name = "rmkit-cn";
    traits.distribution_version = "1.0";
    traits.app_name = "rime.rmkit-cn";
    traits.min_log_level = 3; // 只记 FATAL, 设备上别刷日志
    api()->setup(&traits);
    api()->initialize(&traits);
}

// 阻塞式部署: 首次或 schema 变化时编译词库 (marisa + 语言模型)。
// 我们预编译好随包下发, 正常启动这里是快速的一致性校验。
static int rime_bridge_start_maintenance(int full_check) {
    return api()->start_maintenance((Bool)full_check);
}
static void rime_bridge_join_maintenance(void) {
    if (api()->join_maintenance_thread) api()->join_maintenance_thread();
}

static RimeSessionId rime_bridge_create_session(void) { return api()->create_session(); }
static void rime_bridge_destroy_session(RimeSessionId s) { api()->destroy_session(s); }
static int rime_bridge_process_key(RimeSessionId s, int code, int mask) {
    return (int)api()->process_key(s, code, mask);
}
static int rime_bridge_select_candidate(RimeSessionId s, size_t idx) {
    if (!api()->select_candidate_on_current_page) return 0;
    return (int)api()->select_candidate_on_current_page(s, idx);
}
static int rime_bridge_change_page(RimeSessionId s, int backward) {
    if (!api()->change_page) return 0;
    return (int)api()->change_page(s, (Bool)backward);
}
static void rime_bridge_clear(RimeSessionId s) {
    if (api()->clear_composition) api()->clear_composition(s);
}

// ── 取 commit (已上屏文本), 返回的 char* 需 caller free ──────────────
static char *rime_bridge_get_commit(RimeSessionId s) {
    RIME_STRUCT(RimeCommit, commit);
    if (!api()->get_commit(s, &commit)) return NULL;
    char *out = commit.text ? strdup(commit.text) : NULL;
    api()->free_commit(&commit);
    return out;
}

// ── 取 context: 用一次调用把标量填进 out 参数, 候选数组单独用下面的取字符 ──
// 避免 Go 侧反复过 cgo 边界读 C 结构体。context 用完必须 free_context。
typedef struct {
    RimeContext ctx;
    int ok;
} bridge_ctx;

static bridge_ctx *rime_bridge_get_context(RimeSessionId s) {
    bridge_ctx *bc = (bridge_ctx *)calloc(1, sizeof(bridge_ctx));
    RIME_STRUCT_INIT(RimeContext, bc->ctx);
    bc->ok = (int)api()->get_context(s, &bc->ctx);
    return bc;
}
static void rime_bridge_free_context(bridge_ctx *bc) {
    if (!bc) return;
    api()->free_context(&bc->ctx);
    free(bc);
}
static const char *bctx_preedit(bridge_ctx *bc) { return bc->ctx.composition.preedit; }
static int   bctx_num(bridge_ctx *bc)          { return bc->ctx.menu.num_candidates; }
static int   bctx_highlighted(bridge_ctx *bc)  { return bc->ctx.menu.highlighted_candidate_index; }
static int   bctx_page_no(bridge_ctx *bc)      { return bc->ctx.menu.page_no; }
static int   bctx_is_last(bridge_ctx *bc)      { return (int)bc->ctx.menu.is_last_page; }
static const char *bctx_cand_text(bridge_ctx *bc, int i)    { return bc->ctx.menu.candidates[i].text; }
static const char *bctx_cand_comment(bridge_ctx *bc, int i) { return bc->ctx.menu.candidates[i].comment; }

static void rime_bridge_finalize(void) { if (g_api) api()->finalize(); }
*/
import "C"

import (
	"sync"
	"unsafe"
)

var initOnce sync.Once

// Init 初始化 librime 全局环境。shared 是只读 schema/词库目录 (随包下发的
// 预编译产物), user 是可写目录 (userdb 自学习落这里)。整个进程调用一次。
func Init(sharedDir, userDir string) {
	initOnce.Do(func() {
		cs := C.CString(sharedDir)
		cu := C.CString(userDir)
		defer C.free(unsafe.Pointer(cs))
		defer C.free(unsafe.Pointer(cu))
		C.rime_bridge_setup(cs, cu)
		// full_check=false: 预编译产物已就位, 只做快速一致性校验
		C.rime_bridge_start_maintenance(0)
		C.rime_bridge_join_maintenance()
	})
}

// Finalize 释放 librime (进程退出时调, 一般不需要)。
func Finalize() { C.rime_bridge_finalize() }

// Candidate 是一个候选词。Comment 通常是拼音/注释, 拼音方案下常为空。
type Candidate struct {
	Text    string
	Comment string
}

// Context 是一次按键后 librime 的输入状态快照。
type Context struct {
	Preedit     string      // 编辑区文本 (整句输入时是"已选+待选"的完整串)
	Candidates  []Candidate // 当前页候选
	Highlighted int         // 高亮候选在本页的下标
	PageNo      int         // 当前页码 (0 起)
	IsLastPage  bool
}

// Session 是一个独立的输入会话。每个输入焦点 (记事本/搜索栏) 用一个,
// 按键流喂进去, librime 内部维护整句状态。并发安全需调用方保证 (每个
// session 串行使用)。
type Session struct {
	id C.RimeSessionId
}

// NewSession 创建会话。返回的 *Session 用完调 Close。
func NewSession() *Session {
	return &Session{id: C.rime_bridge_create_session()}
}

// ProcessKey 送一个按键。keycode 用 X11 keysym: ASCII 可打印字符 (含
// 字母数字空格) 的 keysym 即其 ASCII 码; 特殊键 Return=0xff0d /
// BackSpace=0xff08 / Escape=0xff1b。mask 一般 0。返回 librime 是否消费了它。
func (s *Session) ProcessKey(keycode, mask int) bool {
	return C.rime_bridge_process_key(s.id, C.int(keycode), C.int(mask)) != 0
}

// Context 取当前输入状态。无编辑内容时 Preedit 空、Candidates nil。
func (s *Session) Context() Context {
	bc := C.rime_bridge_get_context(s.id)
	defer C.rime_bridge_free_context(bc)
	if bc.ok == 0 {
		return Context{}
	}
	out := Context{
		Preedit:     C.GoString(C.bctx_preedit(bc)),
		Highlighted: int(C.bctx_highlighted(bc)),
		PageNo:      int(C.bctx_page_no(bc)),
		IsLastPage:  C.bctx_is_last(bc) != 0,
	}
	n := int(C.bctx_num(bc))
	if n > 0 {
		out.Candidates = make([]Candidate, n)
		for i := 0; i < n; i++ {
			out.Candidates[i] = Candidate{
				Text:    C.GoString(C.bctx_cand_text(bc, C.int(i))),
				Comment: C.GoString(C.bctx_cand_comment(bc, C.int(i))),
			}
		}
	}
	return out
}

// SelectCandidate 选中当前页第 idx 个候选 (0 起)。整句输入下这会把该候选
// 并入已选、继续等后续音节, 而非直接结束。
func (s *Session) SelectCandidate(idx int) bool {
	return C.rime_bridge_select_candidate(s.id, C.size_t(idx)) != 0
}

// ChangePage 翻页。backward=true 上一页。
func (s *Session) ChangePage(backward bool) bool {
	var b C.int
	if backward {
		b = 1
	}
	return C.rime_bridge_change_page(s.id, b) != 0
}

// Commit 取已上屏文本并清空 commit 缓冲。无则返回 ""。
// librime 在整句成型 (回车/句子完成) 时产生 commit。
func (s *Session) Commit() string {
	c := C.rime_bridge_get_commit(s.id)
	if c == nil {
		return ""
	}
	defer C.free(unsafe.Pointer(c))
	return C.GoString(c)
}

// Clear 清空当前编辑状态 (放弃未上屏的输入)。
func (s *Session) Clear() { C.rime_bridge_clear(s.id) }

// Close 销毁会话。
func (s *Session) Close() { C.rime_bridge_destroy_session(s.id) }
