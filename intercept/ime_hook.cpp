// ime_hook.cpp - LD_PRELOAD 拦截 Qt 输入法 commit，把字母改道到拼音候选栏
//
// 协议（QML/ime-server/hook 三方契约，经 /tmp 下三个 flag 文件交换）：
//   /tmp/rmkit_chinese_mode   存在 → direct mode 下拦截 ASCII 字母
//                               hook 不调原函数，改写 /tmp/rmkit_char_queue
//   /tmp/rmkit_pinyin_active  存在 → 拦截退格（replaceFrom<0 的空 commit）
//                               Qt 把退格发到这里是个不可见的 U+200B 占位符
//   /tmp/rmkit_char_queue     字符队列，每字符后跟 \n；QML 经 ime-server 的
//                               /pop-all-chars 端点原子读取并清空
//
// 非 direct mode（/tmp/rmkit_chinese_mode 不存在，如系统搜索栏）字母正常流入。
//
// 反推自 dist/ime_hook.so：
//   - 只导出 _ZN17QInputMethodEvent15setCommitStringERK7QStringii
//   - 依赖 libc/libgcc_s/libm/libstdc++（不链接 Qt，所以手工读 QString 布局）
//   - .comment = "GCC: (GNU) 13.3.0" 对上 Ferrari SDK 5.0.58-dirty
//
// 构建见 intercept/Makefile。

#ifndef _GNU_SOURCE
#define _GNU_SOURCE
#endif
#include <dlfcn.h>
#include <sys/stat.h>
#include <fcntl.h>
#include <unistd.h>
#include <cerrno>
#include <cstdio>
#include <cstring>
#include <cstdlib>
#include <cstdint>

// ─── QString 内存布局（Qt 6.x ABI） ─────────────────────────
// Qt 6 的 QString 是 inline 三元组，不像 Qt 5 靠 QArrayData 头：
//   struct QString {
//       QTypedArrayData<char16_t>* d;   // 存储块指针（literal 时可为 null）
//       char16_t*                  ptr; // 数据起点
//       qsizetype                  size;// 字符数（qsizetype = ptrdiff_t）
//   };
// 64-bit：sizeof(QString) = 24；32-bit：= 12
// 对我们只要 ptr 和 size，d 字段完全不用管——能正确处理 literal/detached 两种情形。

struct QStringView6 {
    void* d;
    const uint16_t* ptr;
#if __SIZEOF_POINTER__ == 8
    long long size;   // ssize_t on LP64
#else
    int size;         // ssize_t on ILP32
#endif
};

static inline long long qstring_size(const void* qs) {
    if (!qs) return 0;
    return reinterpret_cast<const QStringView6*>(qs)->size;
}

static inline const uint16_t* qstring_utf16(const void* qs) {
    if (!qs) return nullptr;
    return reinterpret_cast<const QStringView6*>(qs)->ptr;
}

// ─── flag 文件探测 ────────────────────────────────────────
static inline bool file_exists(const char* path) {
    struct stat st;
    return ::stat(path, &st) == 0;
}

// ─── 字符队列写入 ──────────────────────────────────────────
// 只会用于 ASCII 字母/空格，但留 UTF-8 fallback 保险
static void enqueue_char(uint16_t ch) {
    int fd = ::open("/tmp/rmkit_char_queue",
                    O_WRONLY | O_CREAT | O_APPEND, 0644);
    if (fd < 0) return;

    char buf[5];
    int n = 0;
    if (ch < 0x80) {
        buf[n++] = (char)ch;
    } else if (ch < 0x800) {
        buf[n++] = (char)(0xC0 | (ch >> 6));
        buf[n++] = (char)(0x80 | (ch & 0x3F));
    } else {
        buf[n++] = (char)(0xE0 | (ch >> 12));
        buf[n++] = (char)(0x80 | ((ch >> 6) & 0x3F));
        buf[n++] = (char)(0x80 | (ch & 0x3F));
    }
    buf[n++] = '\n';
    ::write(fd, buf, n);
    ::close(fd);
}

// ─── 原函数指针 ────────────────────────────────────────────
typedef void (*setCommitString_fn)(void* self, const void* qs,
                                    int replaceFrom, int replaceLength);
// QGuiApplicationPrivate::processKeyEvent 是静态成员函数，只有一个参数
typedef void (*processKeyEvent_fn)(void* keyEvent);
static setCommitString_fn real_setCommitString = nullptr;
static processKeyEvent_fn real_processKeyEvent = nullptr;
static int g_debug = 0;

static void load_orig() {
    if (!real_setCommitString) {
        real_setCommitString = (setCommitString_fn)dlsym(
            RTLD_NEXT,
            "_ZN17QInputMethodEvent15setCommitStringERK7QStringii");
    }
    if (!real_processKeyEvent) {
        real_processKeyEvent = (processKeyEvent_fn)dlsym(
            RTLD_NEXT,
            "_ZN22QGuiApplicationPrivate15processKeyEventEPN29QWindowSystemInterfacePrivate8KeyEventE");
    }
}

// ─── QWindowSystemInterfacePrivate::KeyEvent 偏移（Qt 6.8.2） ───
// 继承链：WindowSystemEvent(有虚析构 → vtable) → UserEvent → InputEvent → KeyEvent
// QPointer<T> = QWeakPointer<T> = 2 个指针
//
// 64-bit (aarch64)：
//   0  vtable*
//   8  EventType type
//  12  int flags
//  16  bool eventAccepted  (pad 到 24)
//  24  QPointer window     (16B)
//  40  unsigned long timestamp
//  48  QFlags modifiers    (pad 到 56)
//  56  QInputDevice *device
//  64  QInputDevice *source
//  72  int key             (pad 到 80)
//  80  QString unicode     (24B)
// 104  bool repeat
// 106  ushort repeatCount
// 108  QEvent::Type keyType
//
// 32-bit (armv7)：
//   0  vtable*
//   4  EventType type
//   8  int flags
//  12  bool eventAccepted  (pad 到 16)
//  16  QPointer window     (8B)
//  24  unsigned long timestamp
//  28  QFlags modifiers
//  32  QInputDevice *device
//  36  QInputDevice *source
//  40  int key
//  44  QString unicode     (12B)
//  56  bool repeat
//  58  ushort repeatCount
//  60  QEvent::Type keyType
#if __SIZEOF_POINTER__ == 8
static const size_t KE_KEY_OFFSET     = 72;
static const size_t KE_UNICODE_OFFSET = 80;
static const size_t KE_KEYTYPE_OFFSET = 108;
#else
static const size_t KE_KEY_OFFSET     = 40;
static const size_t KE_UNICODE_OFFSET = 44;
static const size_t KE_KEYTYPE_OFFSET = 60;
#endif

// QEvent::Type
static const int QEVENT_KEYPRESS   = 6;
static const int QEVENT_KEYRELEASE = 7;
// Qt::Key
static const int QT_KEY_RETURN = 0x01000004;
static const int QT_KEY_ENTER  = 0x01000005;

__attribute__((constructor))
static void init_hook() {
    g_debug = ::getenv("RMKIT_HOOK_DEBUG") ? 1 : 0;
    if (g_debug) {
        fprintf(stderr, "[rmkit-hook] loaded, ptr=%zu\n", sizeof(void*));
    }
}

// ─── Hook 本体 ────────────────────────────────────────────
// QInputMethodEvent::setCommitString(QString const&, int, int)
// 显式 default：配合 -fvisibility=hidden 只导出这一个符号
extern "C"
__attribute__((visibility("default")))
void _ZN17QInputMethodEvent15setCommitStringERK7QStringii(
    void* self, const void* qs, int replaceFrom, int replaceLength)
{
    load_orig();

    // 退格：replaceFrom<0 的空 commit，仅当拼音正在累积时拦
    if (replaceFrom < 0 && qstring_size(qs) == 0) {
        if (file_exists("/tmp/rmkit_pinyin_active")) {
            if (g_debug) fprintf(stderr, "[rmkit-hook] swallow backspace\n");
            return;
        }
    }

    // direct mode（编辑器内）拦 ASCII 字母改道候选栏
    // 拼音累积时（pinyin_active）也拦空格（首候选上屏）和回车（buffer 原文上屏）
    if (file_exists("/tmp/rmkit_chinese_mode")) {
        long long n = qstring_size(qs);
        if (n == 1) {
            const uint16_t* u = qstring_utf16(qs);
            if (u) {
                uint16_t ch = u[0];
                bool is_letter = (ch >= 'a' && ch <= 'z') || (ch >= 'A' && ch <= 'Z');
                bool pinyin = file_exists("/tmp/rmkit_pinyin_active");
                bool is_space = (ch == ' ') && pinyin;
                bool is_enter = (ch == '\r' || ch == '\n') && pinyin;
                if (is_letter || is_space || is_enter) {
                    enqueue_char(ch);
                    if (g_debug) fprintf(stderr, "[rmkit-hook] queue 0x%02x\n", ch);
                    return;
                }
            }
        }
    }

    if (real_setCommitString) {
        real_setCommitString(self, qs, replaceFrom, replaceLength);
    }
}

// ─── processKeyEvent Hook ────────────────────────────────
// QGuiApplicationPrivate::processKeyEvent(QWindowSystemInterfacePrivate::KeyEvent*)
//
// 用途：RM2 这类没有 epaperkeyboardhandler 的设备，记事本 SceneView 直接收 QKeyEvent，
//       不走 QInputMethodEvent，所以 setCommitString hook 拦不到字母。
//       在 Qt 中央 KeyEvent 分发点拦一刀：chinese_mode 下 KeyPress 的单个 ASCII 字母
//       写入 char_queue 并吞事件，SceneView 就不会收到那次 key event。
//
// 副作用控制：
//   - 只处理 /tmp/rmkit_chinese_mode 存在时，其他场景零影响
//   - 只吞字母（a-z, A-Z），其他键正常派发
//   - press/release 都吞（保持配对），只在 press 时入队避免重复
extern "C"
__attribute__((visibility("default")))
void _ZN22QGuiApplicationPrivate15processKeyEventEPN29QWindowSystemInterfacePrivate8KeyEventE(
    void* keyEvent)
{
    load_orig();

    if (keyEvent && file_exists("/tmp/rmkit_chinese_mode")) {
        const uint8_t* base = reinterpret_cast<const uint8_t*>(keyEvent);
        int keyType = *reinterpret_cast<const int*>(base + KE_KEYTYPE_OFFSET);
        int key     = *reinterpret_cast<const int*>(base + KE_KEY_OFFSET);

        if (keyType == QEVENT_KEYPRESS || keyType == QEVENT_KEYRELEASE) {
            const void* qs = base + KE_UNICODE_OFFSET;
            long long n = qstring_size(qs);
            const uint16_t* u = (n >= 1) ? qstring_utf16(qs) : nullptr;
            uint16_t ch = (u && n == 1) ? u[0] : 0;
            bool pinyin = file_exists("/tmp/rmkit_pinyin_active");
            bool is_letter = (ch >= 'a' && ch <= 'z') || (ch >= 'A' && ch <= 'Z');
            bool is_space  = (ch == ' ') && pinyin;
            // 回车键的 unicode QString 在 Qt 6 KeyEvent 里可能是空的——按 Qt::Key 判断
            bool is_enter  = (key == QT_KEY_RETURN || key == QT_KEY_ENTER) && pinyin;
            if (g_debug) {
                fprintf(stderr, "[rmkit-hook] keyev type=%d key=0x%x n=%lld ch=0x%x\n",
                        keyType, key, n, ch);
            }
            if (is_letter || is_space || is_enter) {
                if (keyType == QEVENT_KEYPRESS) {
                    uint16_t out = is_enter ? '\r' : ch;
                    enqueue_char(out);
                    if (g_debug) fprintf(stderr, "[rmkit-hook] key queue 0x%02x\n", out);
                }
                return;  // 吞事件
            }
        }
    }

    if (real_processKeyEvent) {
        real_processKeyEvent(keyEvent);
    }
}
