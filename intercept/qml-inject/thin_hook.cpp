// thin_hook.cpp — 瘦 hook (LD_PRELOAD, 绝不链接 Qt)
//
// 方案 A 的第一半: 只做两件安全的事——
//   1. 插桩 QQmlEngine::rootContext(), 抓到活的 engine 指针 (纯 dlsym 转发, 不碰 Qt API)
//   2. spawn 一个 pthread, 延迟后 dlopen 胖库 qml_inject_impl.so 做真正注入
// 关键: 本文件不链接任何 Qt 库 → LD_PRELOAD 不会提前加载 Qt → 不破坏 Qt 初始化顺序
//       (实测: 链接 Qt 的 LD_PRELOAD .so 会让 xochitl 启动即崩; 不链接的存活)
// 胖库在 Qt 完全起来之后才 dlopen, 那时链接 Qt 安全 (同 Qt 插件的加载时机)。

#ifndef _GNU_SOURCE
#define _GNU_SOURCE
#endif
#include <dlfcn.h>
#include <pthread.h>
#include <unistd.h>
#include <cstdio>

static const char *IMPL_SO = "/home/root/rmkit-cn/bin/qml_inject_impl.so";

typedef void *(*rootContext_fn)(const void *);
static rootContext_fn real_rootContext = nullptr;
static bool g_done = false;
static void *g_engine = nullptr;

__attribute__((constructor)) static void thin_init() {
    setvbuf(stderr, nullptr, _IONBF, 0);
    fprintf(stderr, "[thin] loaded (no Qt link)\n");
}

// worker 线程: 等 UI 起来, 再 dlopen 胖库注入
static void *worker(void *) {
    sleep(15); // 等 xochitl UI 构建完成 (rootContext 在启动早期就被调)
    fprintf(stderr, "[thin] worker: dlopen %s\n", IMPL_SO);
    void *h = dlopen(IMPL_SO, RTLD_NOW | RTLD_GLOBAL);
    if (!h) {
        fprintf(stderr, "[thin] dlopen FAILED: %s\n", dlerror());
        return nullptr;
    }
    typedef void (*inject_fn)(void *);
    inject_fn inj = (inject_fn)dlsym(h, "pw_inject");
    if (!inj) {
        fprintf(stderr, "[thin] no pw_inject symbol: %s\n", dlerror());
        return nullptr;
    }
    fprintf(stderr, "[thin] calling pw_inject(engine=%p)\n", g_engine);
    inj(g_engine);
    return nullptr;
}

extern "C" __attribute__((visibility("default"))) void *
_ZNK10QQmlEngine11rootContextEv(const void *self) {
    if (!real_rootContext)
        real_rootContext =
            (rootContext_fn)dlsym(RTLD_NEXT, "_ZNK10QQmlEngine11rootContextEv");
    void *ctx = real_rootContext ? real_rootContext(self) : nullptr;

    if (!g_done && self) {
        g_done = true;
        g_engine = (void *)self;
        fprintf(stderr, "[thin] captured engine=%p, spawning worker\n", self);
        pthread_t t;
        if (pthread_create(&t, nullptr, worker, nullptr) == 0)
            pthread_detach(t);
    }
    return ctx;
}
