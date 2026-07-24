// qml_inject.cpp — 运行时 QML 注入原型 (验证 shim 注入路线)
//
// 原理 (跟 intercept/ime_hook.cpp 同源, 只是从 IME 扩到 QML 注入):
//   LD_PRELOAD 插桩 Qt 符号 QQmlEngine::rootContext(), 抢在真 Qt 之前被调用,
//   借此拿到活的 QQmlEngine 指针; 干完自己的事再 dlsym(RTLD_NEXT) 转发真 Qt。
//   跟 qmldiff 的根本区别: 不碰编译产物 / 不要 hashtab / 操作运行时对象树。
//
// 分阶段 (本文件是 STAGE 1: 只证明机制能通):
//   STAGE 1: 抓到 engine → 延迟 3s (等 UI 起来) → 往第一个 QQuickWindow 的
//            contentItem 注入一个醒目红块 "HOOK OK 高级"。看到红块 = 整条路通:
//            (a) 插桩生效 (b) 能进活的 QML 引擎 (c) 能运行时创建+挂 QML 节点。
//   STAGE 2 (验证通过后再做): 用 findChildren 定位 Sidebar 真实目标节点,
//            注入真正的 "高级" 按钮, 迁移 advanced_panel 脱离 qmldiff。
//
// 注意 STAGE 2 的已知难点: reMarkable 的 Sidebar 内部锚点是 QML id (如 filterColumn),
//   而 id 不是 objectName, findChild(name) 找不到。得靠类型/结构启发式定位, 或
//   在注入前先给目标设 objectName。STAGE 1 先绕开这个, 只注入 contentItem (必存在)。
//
// 构建见同目录 Makefile (需真链接 Qt6Qml/Quick/Gui/Core, 用 Ferrari SDK sysroot)。

#ifndef _GNU_SOURCE
#define _GNU_SOURCE
#endif
#include <dlfcn.h>
#include <cstdio>

#include <QtCore/QCoreApplication>
#include <QtCore/QThread>
#include <QtCore/QTimer>
#include <QtCore/QUrl>
#include <QtGui/QGuiApplication>
#include <QtQml/QQmlComponent>
#include <QtQml/QQmlContext>
#include <QtQml/QQmlEngine>
#include <QtQuick/QQuickItem>
#include <QtQuick/QQuickWindow>

// QQmlEngine::rootContext() const  → mangled 符号
typedef QQmlContext *(*rootContext_fn)(const QQmlEngine *);
static rootContext_fn real_rootContext = nullptr;
static bool g_injected = false;

// .so 加载即执行: 把 stderr 设为无缓冲, 否则日志块缓冲, segfault 时全丢 → 看不到崩在哪
__attribute__((constructor)) static void qmlinject_init() {
    setvbuf(stderr, nullptr, _IONBF, 0);
    fprintf(stderr, "[qml-inject] loaded (stderr unbuffered)\n");
}

static void doInject(QQmlEngine *engine) {
    fprintf(stderr, "[qml-inject] doInject: enter\n");
    // 线程守卫: QML 对象只能在 GUI 主线程创建/挂载, 否则崩
    if (QThread::currentThread() != QCoreApplication::instance()->thread()) {
        fprintf(stderr, "[qml-inject] doInject: NOT gui thread, abort\n");
        return;
    }
    const auto windows = QGuiApplication::topLevelWindows();
    fprintf(stderr, "[qml-inject] doInject: %d top-level windows\n", (int)windows.size());
    for (QWindow *w : windows) {
        auto *qw = qobject_cast<QQuickWindow *>(w);
        fprintf(stderr, "[qml-inject]   window '%s' isQuick=%d\n",
                w->metaObject()->className(), qw ? 1 : 0);
        if (!qw)
            continue;
        QQuickItem *root = qw->contentItem();
        fprintf(stderr, "[qml-inject]   contentItem=%p\n", (void *)root);
        if (!root)
            continue;

        fprintf(stderr, "[qml-inject]   creating component...\n");
        QQmlComponent comp(engine);
        comp.setData(
            "import QtQuick\n"
            "Rectangle { width:260; height:90; z:99999; x:40; y:300;\n"
            "  color:\"#d00000\"; border.color:\"black\"; border.width:2;\n"
            "  Text { anchors.centerIn:parent; color:\"white\"; font.pixelSize:28;\n"
            "         text:\"HOOK OK \\u9ad8\\u7ea7\" } }\n",
            QUrl());
        fprintf(stderr, "[qml-inject]   comp status=%d isError=%d\n",
                (int)comp.status(), comp.isError() ? 1 : 0);
        if (comp.isError()) {
            fprintf(stderr, "[qml-inject]   ERR: %s\n",
                    comp.errorString().toUtf8().constData());
            continue;
        }
        QObject *obj = comp.create();
        fprintf(stderr, "[qml-inject]   created obj=%p\n", (void *)obj);
        auto *item = qobject_cast<QQuickItem *>(obj);
        if (!item) {
            fprintf(stderr, "[qml-inject]   not a QQuickItem, skip\n");
            continue;
        }
        fprintf(stderr, "[qml-inject]   setParentItem...\n");
        item->setParentItem(root);
        fprintf(stderr, "[qml-inject] STAGE1 OK: injected into '%s'\n",
                w->metaObject()->className());
        break; // 第一个成功就够
    }
    fprintf(stderr, "[qml-inject] doInject: done\n");
}

// 插桩: 抢占 QQmlEngine::rootContext()
// visibility("default") 必须显式加: -fvisibility=hidden 会压过 version script 的 global:,
// 导致符号不进动态表 → LD_PRELOAD 抢不到。加这个强制导出这一个符号。
extern "C" __attribute__((visibility("default"))) QQmlContext *
_ZNK10QQmlEngine11rootContextEv(const QQmlEngine *self) {
    if (!real_rootContext)
        real_rootContext =
            (rootContext_fn)dlsym(RTLD_NEXT, "_ZNK10QQmlEngine11rootContextEv");

    QQmlContext *ctx = real_rootContext ? real_rootContext(self) : nullptr;

    if (!g_injected && self) {
        g_injected = true;
        auto *engine = const_cast<QQmlEngine *>(self);
        fprintf(stderr, "[qml-inject] captured QQmlEngine=%p (DIAG: no timer, no inject)\n",
                (void *)engine);
        (void)engine;
        // 诊断版: 完全不调 QTimer/doInject, 只转发。存活=崩在timer; 崩=崩在hook转发
        // QTimer::singleShot(3000, engine, [engine]() { doInject(engine); });
    }
    return ctx;
}
