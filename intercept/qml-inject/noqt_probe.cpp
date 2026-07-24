// 决定性诊断: hook rootContext 但完全不链接 Qt (纯 dlsym 转发, 同 ime_hook 手法)
#include <dlfcn.h>
#include <cstdio>
typedef void *(*fn)(const void *);
static fn real_fn = nullptr;
static bool done = false;
__attribute__((constructor)) static void init() {
    setvbuf(stderr, nullptr, _IONBF, 0);
    fprintf(stderr, "[noqt-probe] loaded (no Qt link)\n");
}
extern "C" __attribute__((visibility("default")))
void *_ZNK10QQmlEngine11rootContextEv(const void *self) {
    if (!real_fn) real_fn = (fn)dlsym(RTLD_NEXT, "_ZNK10QQmlEngine11rootContextEv");
    void *ctx = real_fn ? real_fn(self) : nullptr;
    if (!done && self) { done = true; fprintf(stderr, "[noqt-probe] captured %p (forward only, no Qt)\n", self); }
    return ctx;
}
