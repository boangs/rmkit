// qml_inject_impl.cpp — 胖注入库 (链接 Qt, 由瘦 hook dlopen 加载)
//
// 方案 A 的第二半: 真正的运行时 QML 注入。
// 由 thin_hook 的 worker 线程 dlopen + 调 pw_inject(engine)。
// 此时我们在 worker 线程, 必须 QMetaObject::invokeMethod marshal 到 GUI 主线程
// 才能安全操作 QML 对象树。

#include <cstdarg>
#include <cstdio>
#include <unistd.h>

#include <QtCore/QByteArray>
#include <QtCore/QCoreApplication>
#include <QtCore/QList>
#include <QtCore/QMetaMethod>
#include <QtCore/QPointer>
#include <QtCore/QMetaProperty>
#include <QtCore/QThread>
#include <QtCore/QTimer>
#include <QtCore/QUrl>
#include <QtCore/QMimeData>
#include <QtCore/QStringList>
#include <QtGui/QClipboard>
#include <QtGui/QGuiApplication>
#include <QtQml/QQmlComponent>
#include <QtQml/QQmlContext>
#include <QtQml/QQmlExpression>
#include <QtQml/QQmlEngine>
#include <QtQuick/QQuickItem>
#include <QtQuick/QQuickWindow>

// 直接写文件的日志: journal 会限流丢日志, stderr 重定向后有缓冲, 排查时都不可靠
static void flog(const char *fmt, ...) {
    FILE *f = fopen("/tmp/rmkit-inject.log", "a");
    if (!f)
        return;
    va_list ap;
    va_start(ap, fmt);
    vfprintf(f, fmt, ap);
    va_end(ap);
    fclose(f);
}

// dump 一个节点的完整子树到 out (默认 stderr; 诊断时写文件避免 journal 速率限制)
static void dumpSubtree(QQuickItem *item, int depth, int &count, FILE *out = stderr,
                        int maxN = 400) {
    if (!item || count > maxN)
        return;
    count++;
    const char *cls = item->metaObject()->className();
    QByteArray on = item->objectName().toUtf8();
    fprintf(out, "%*sd%d %s%s%s sz=(%.0fx%.0f) pos=(%.0f,%.0f) vis=%d nch=%d\n",
            depth, "", depth, cls,
            on.isEmpty() ? "" : " obj=", on.isEmpty() ? "" : on.constData(),
            item->width(), item->height(), item->x(), item->y(),
            item->isVisible() ? 1 : 0, (int)item->childItems().size());
    for (QQuickItem *c : item->childItems())
        dumpSubtree(c, depth + 1, count, out, maxN);
}

// 按需诊断: 存在 /tmp/rmkit-dump 时 dump 所有顶层窗口整树到 /tmp/rmkit-dump.txt, 删标志文件
static void maybeDumpAll() {
    if (access("/tmp/rmkit-dump", F_OK) != 0)
        return;
    unlink("/tmp/rmkit-dump");
    FILE *out = fopen("/tmp/rmkit-dump.txt", "w");
    if (!out) {
        fprintf(stderr, "[dump] 打不开 /tmp/rmkit-dump.txt\n");
        return;
    }
    for (QWindow *w : QGuiApplication::topLevelWindows()) {
        auto *qw = qobject_cast<QQuickWindow *>(w);
        if (!qw || !qw->contentItem())
            continue;
        int n = 0;
        fprintf(out, "===== window %s vis=%d =====\n", w->metaObject()->className(),
                w->isVisible() ? 1 : 0);
        dumpSubtree(qw->contentItem(), 0, n, out, 100000);
        fprintf(out, "===== end (%d nodes) =====\n", n);
    }
    fclose(out);
    fprintf(stderr, "[dump] 完成, 写入 /tmp/rmkit-dump.txt\n");
}

// 递归找第一个类名含关键字的节点
static QQuickItem *findByClass(QQuickItem *item, const char *key) {
    if (!item)
        return nullptr;
    if (QByteArray(item->metaObject()->className()).contains(key))
        return item;
    for (QQuickItem *c : item->childItems()) {
        QQuickItem *f = findByClass(c, key);
        if (f)
            return f;
    }
    return nullptr;
}

// 找一个"能看到 xochitl 运行时单例 (Clipboard 等) 的" QQmlContext。
// 直接对某个节点取 context 可能拿到匿名子上下文, 其中看不到单例 → QML 里 typeof Clipboard
// === "undefined"。沿 parent 链上溯, 取第一个能解析出 Clipboard 的上下文。
// Clipboard 是 QML **单例**(靠类型系统 import 解析), 不是 context property ——
// 所以不能用 contextProperty("Clipboard") 判断, 必须在候选上下文里求值表达式。
static QObject *g_clipSingleton = nullptr;

static QQmlContext *findUsableContext(QQuickItem *node, QQmlEngine *engine) {
    for (QQuickItem *p = node; p; p = p->parentItem()) {
        QQmlContext *c = QQmlEngine::contextForObject(p);
        if (!c)
            continue;
        QQmlExpression expr(c, nullptr, QStringLiteral("Clipboard"));
        QVariant v = expr.evaluate();
        if (!expr.hasError()) {
            QObject *o = v.value<QObject *>();
            if (o) {
                if (!g_clipSingleton) {
                    g_clipSingleton = o;
                    flog("[clip] 求值拿到 Clipboard 单例: class=%s\n", o->metaObject()->className());
                }
                return c;
            }
        }
    }
    QQmlContext *own = QQmlEngine::contextForObject(node);
    flog("[clip] 所有上下文都求不出 Clipboard, 退回 own=%p\n", (void *)own);
    return own ? own : engine->rootContext();
}

static QQmlContext *g_clipCtx = nullptr; // 挂 rmkitClipText 的子上下文
static QString g_lastCopied; // textCopied 信号捕获到的选中文字

static QString readSelectedText() {
    QClipboard *cb = QGuiApplication::clipboard();
    // 路径 1: 系统剪贴板 text()
    if (cb) {
        QString t = cb->text();
        if (!t.isEmpty())
            return t;
        // 路径 2: 自定义 MIME —— dump 所有格式, 取第一个像文本的
        const QMimeData *md = cb->mimeData();
        if (md) {
            const QStringList fmts = md->formats();
            static int dumped = 0;
            if (dumped < 6) {
                dumped++;
                flog("[clip] formats(%d): %s\n", (int)fmts.size(),
                        fmts.join(QStringLiteral(" | ")).toUtf8().constData());
            }
            for (const QString &f : fmts) {
                QByteArray d = md->data(f);
                if (d.isEmpty())
                    continue;
                if (dumped <= 6)
                    flog("[clip]   %s -> %d bytes head=%s\n",
                            f.toUtf8().constData(), (int)d.size(),
                            QByteArray(d.left(60)).replace('\n', ' ').constData());
                // scene 剪贴板的文本通常是 UTF-8 (可能带二进制头), 取可打印部分
                QString cand = QString::fromUtf8(d);
                if (!cand.trimmed().isEmpty() && f.contains("text", Qt::CaseInsensitive))
                    return cand;
            }
        }
    }
    // 路径 3: 找 xochitl 的 Clipboard QObject 单例, invoke textString()
    static QObject *clipObj = nullptr;
    if (!clipObj) {
        const QList<QObject *> all =
            QCoreApplication::instance()->findChildren<QObject *>(QString(), Qt::FindChildrenRecursively);
        for (QObject *o : all) {
            QByteArray cn(o->metaObject()->className());
            if (cn.contains("Clipboard")) {
                flog("[clip] 找到 QObject class=%s\n", cn.constData());
                clipObj = o;
                break;
            }
        }
    }
    if (clipObj) {
        QString s;
        if (QMetaObject::invokeMethod(clipObj, "textString", Q_RETURN_ARG(QString, s)) && !s.isEmpty()) {
            flog("[clip] textString() -> len=%d\n", (int)s.length());
            return s;
        }
    }
    return QString();
}

static QQmlEngine *g_engineForClip = nullptr;
static QList<QPointer<QQuickItem>> g_textBtns; // 已注入的 text AI 按钮
static int g_clipSeq = 0;  // textCopied 每到达一次 +1; QML 面板靠它区分"本次复制"和残留旧文本
static int g_clipTick = 0; // 每秒 +1 心跳; 注入组件里 Timer 不触发, 面板用它做等待超时

// textCopied 到达时立即推给按钮。只靠 1s 定时器刷新的话, 面板点击瞬间读到的是
// 上一次复制的旧文本 (实测: 第一次失败, 第二次答的是第一次选中的内容)。
static void pushClipToButtons(const QString &t) {
    g_clipSeq++;
    for (const QPointer<QQuickItem> &b : g_textBtns)
        if (b) {
            b->setProperty("clipText", t);
            b->setProperty("clipSeq", g_clipSeq);
        }
    flog("[clip] push seq=%d len=%d btns=%d\n", g_clipSeq, (int)t.length(), (int)g_textBtns.size());
}

static void refreshClipBridge() {
    if (!g_clipCtx && !g_engineForClip)
        return;
    QString t;
    // 路径 1 (主): xochitl 的 Clipboard 单例 textString() —— qmd 版同款 API
    if (g_clipSingleton) {
        QString s1;
        bool ok = QMetaObject::invokeMethod(g_clipSingleton, "textString", Q_RETURN_ARG(QString, s1));
        t = s1;
        static int lastLen = -1;
        if ((int)s1.length() != lastLen) { // 只在长度变化时记录, 避免刷屏
            lastLen = s1.length();
            flog("[clip] textString() ok=%d len=%d head=%s\n", ok, (int)s1.length(),
                 s1.left(30).toUtf8().constData());
        }
    }
    if (t.isEmpty())
        t = g_lastCopied;         // 路径 2: textCopied 信号捕获
    if (t.isEmpty())
        t = readSelectedText();   // 路径 3: 系统剪贴板 (实测为空, 兜底)
    if (g_clipCtx)
        g_clipCtx->setContextProperty("rmkitClipText", t);
    // 同时写引擎根上下文: 注入组件可能创建在别的上下文里, 根上下文对所有组件可见
    if (g_engineForClip)
        g_engineForClip->rootContext()->setContextProperty("rmkitClipText", t);
    // 最可靠: 直接写进已注入按钮的属性 (面板从按钮取, 不依赖任何 context 可见性)。
    // 这里不碰 clipSeq —— t 可能是残留旧文本, seq 只由 pushClipToButtons 推进。
    g_clipTick++;
    for (const QPointer<QQuickItem> &b : g_textBtns)
        if (b) {
            b->setProperty("clipText", t);
            b->setProperty("clipTick", g_clipTick);
        }
}


// ─── 选中文字获取: 连 SceneController::textCopied(SceneClipboardText) 信号 ───
// copySelectedText() 不写系统剪贴板 (实测 QClipboard 全程为空), 而是发这个信号。
// SceneClipboardText 是自定义类型, 用 QMetaType 反射找它内部的 QString 成员。
static QString extractTextFromVariant(const QVariant &v) {
    if (v.canConvert<QString>()) {
        QString s = v.toString();
        if (!s.isEmpty())
            return s;
    }
    // 自定义类型: 用 QMetaType 的 metaObject 遍历属性找字符串
    const QMetaType mt = v.metaType();
    const QMetaObject *mo = mt.metaObject();
    if (mo) {
        const void *data = v.constData();
        for (int i = 0; i < mo->propertyCount(); i++) {
            QMetaProperty pr = mo->property(i);
            if (QByteArray(pr.typeName()) == "QString") {
                QVariant pv = pr.readOnGadget(data);
                QString s = pv.toString();
                if (!s.isEmpty()) {
                    flog("[copied] 从 %s.%s 取到 len=%d\n", mo->className(), pr.name(), (int)s.length());
                    return s;
                }
            }
        }
        flog("[copied] gadget %s 无非空 QString 属性 (props=%d)\n", mo->className(), mo->propertyCount());
    } else {
        // 无 metaObject: SceneClipboardText 是普通结构体。扫描其内存, 找形如 QString 的成员。
        // QString 内部是 QArrayDataPointer{d, ptr, size}, 用 QString 解释各偏移并校验合理性。
        const char *base = static_cast<const char *>(v.constData());
        int sz = mt.sizeOf();
        flog("[copied] 类型 %s 无 metaObject, sizeOf=%d, 扫描中\n", mt.name(), sz);
        for (int off = 0; off + (int)sizeof(QString) <= sz; off += sizeof(void *)) {
            const QString *cand = reinterpret_cast<const QString *>(base + off);
            // 谨慎校验: 长度合理 + 能取到首字符
            qsizetype len = 0;
            bool okLen = false;
            // 直接读 size 可能崩, 用 try 语义无法在 C++ 做; 依赖 QString 内部布局的合理性判断
            len = cand->size();
            okLen = (len > 0 && len < 200000);
            if (!okLen)
                continue;
            QString probe = *cand;
            if (probe.isEmpty())
                continue;
            flog("[copied]   偏移 %d 找到 QString len=%d head=%s\n", off, (int)probe.length(),
                 probe.left(40).toUtf8().constData());
            return probe;
        }
        flog("[copied] 扫描未找到 QString\n");
    }
    return QString();
}

// 给 controller 挂 textCopied 监听。不用 moc, 用 qt_metacall 拦截:
// 自定义 QObject 子类重写 qt_metacall, 把 connect 到的信号调用接住并解包参数。
class CopyCatcher : public QObject {
public:
    explicit CopyCatcher(QObject *parent = nullptr) : QObject(parent) {}
    // slotId 是我们分配给"接收槽"的方法索引 (在基类方法数之后)
    int slotOffset = 0;
    int argTypeId = 0;

    int qt_metacall(QMetaObject::Call call, int id, void **args) override {
        if (call == QMetaObject::InvokeMetaMethod && id == slotOffset) {
            // args[1] 是 textCopied 的第一个参数 (SceneClipboardText)
            if (args && args[1] && argTypeId) {
                QVariant v(QMetaType(argTypeId), args[1]);
                QString t = extractTextFromVariant(v);
                if (!t.isEmpty()) {
                    g_lastCopied = t;
                    flog("[copied] 捕获选中文字 len=%d\n", (int)t.length());
                    // 立即推给按钮并 seq+1。信号可能在非 GUI 线程发出,
                    // marshal 到主线程再碰 QML 属性。
                    const QString tc = t;
                    QMetaObject::invokeMethod(
                        QCoreApplication::instance(),
                        [tc]() { pushClipToButtons(tc); }, Qt::QueuedConnection);
                } else {
                    flog("[copied] 信号到达但解不出文字\n");
                }
            }
            return -1;
        }
        return QObject::qt_metacall(call, id, args);
    }
};

static void hookTextCopied(QObject *ctrl) {
    if (!ctrl)
        return;
    static QList<QObject *> hooked;
    if (hooked.contains(ctrl))
        return;
    hooked.append(ctrl);
    const QMetaObject *mo = ctrl->metaObject();
    int sigIdx = -1;
    for (int i = 0; i < mo->methodCount(); i++) {
        if (mo->method(i).methodSignature().startsWith("textCopied(")) {
            sigIdx = i;
            break;
        }
    }
    if (sigIdx < 0) {
        flog("[copied] 未找到 textCopied 信号\n");
        return;
    }
    QMetaMethod sig = mo->method(sigIdx);
    auto *catcher = new CopyCatcher(QCoreApplication::instance());
    catcher->slotOffset = CopyCatcher::staticMetaObject.methodCount();
    catcher->argTypeId = sig.parameterCount() > 0 ? sig.parameterMetaType(0).id() : 0;
    // 直接用底层 connect: 把信号连到 catcher 的 slotOffset 号"方法"
    bool ok = QMetaObject::connect(ctrl, sigIdx, catcher, catcher->slotOffset,
                                   Qt::DirectConnection);
    flog("[copied] 挂 textCopied: ok=%d argType=%s(%d) slotOffset=%d\n", ok,
         sig.parameterCount() > 0 ? sig.parameterMetaType(0).name() : "?", catcher->argTypeId,
         catcher->slotOffset);
}

// ─── language_zh_cn: 语言对话框注入中文选项 (原 language_zh_cn.qmd 的运行时版) ───
// 对话框 (SelectionComponent) 只在用户打开"系统语言"时实例化, 靠 2s 扫描捕获。
// patch 逻辑在 JS helper 里做: model 追加 zh_CN + display 包装。
// stock 的 onSelected 本来就是 languageSettings.languageCode = selection, 无需替换。
static QObject *g_langHelper = nullptr;

static void ensureLangHelper(QQmlEngine *engine) {
    if (g_langHelper)
        return;
    QQmlComponent comp(engine);
    comp.setData(
        "import QtQuick\n"
        "QtObject {\n"
        "  function patchLanguageDialog(dlg) {\n"
        "    try {\n"
        "      if (String(dlg.objectName) !== \"SystemLanguageDialog\") return false\n" // 稳定判据: dump 已证实
        "      var m = dlg.model\n"
        "      var mlen = (m && m.length !== undefined) ? m.length : -1\n"
        "      var j = \"\"; try { j = JSON.stringify(m) } catch (e2) { j = \"<stringify fail>\" }\n"
        "      console.warn(\"[lang] model typeof=\" + (typeof m) + \" len=\" + mlen + \" sel=\" + dlg.selectedIndex + \" json=\" + j)\n"
        "      if (mlen < 0) return false\n"
        "      var arr = []\n"
        "      for (var i = 0; i < mlen; i++) arr.push(m[i])\n"
        "      if (arr.indexOf(\"zh_CN\") !== -1) return false\n" // 已注入过
        "      var old = dlg.display\n"                          // 先包 display 再改 model
        "      dlg.display = function(md) {\n"
        "        return md === \"zh_CN\" ? \"\\u4e2d\\u6587\\uff08\\u7b80\\u4f53\\uff09\" : old(md)\n"
        "      }\n"
        "      var selIdx = dlg.selectedIndex\n"
        "      arr.push(\"zh_CN\")\n"
        "      dlg.model = arr\n"
        "      dlg.selectedIndex = selIdx >= 0 ? selIdx : arr.length - 1\n"
        "      return true\n"
        "    } catch (e) { console.warn(\"[lang] patch err: \" + e); return false }\n"
        "  }\n"
        "}\n",
        QUrl());
    g_langHelper = comp.create();
    if (!g_langHelper)
        fprintf(stderr, "[impl] langHelper 创建失败: %s\n", comp.errorString().toUtf8().constData());
}

static void doInjectLanguage(QQmlEngine *engine) {
    ensureLangHelper(engine);
    if (!g_langHelper)
        return;
    for (QWindow *w : QGuiApplication::topLevelWindows()) {
        auto *qw = qobject_cast<QQuickWindow *>(w);
        if (!qw || !qw->contentItem())
            continue;
        QQuickItem *dlg = findByClass(qw->contentItem(), "SelectionComponent");
        if (!dlg)
            continue;
        // 诊断: 一次性打印 SelectionComponent 全部属性名, 定位装语言列表的属性
        static bool propsDumped = false;
        if (!propsDumped) {
            propsDumped = true;
            const QMetaObject *mo = dlg->metaObject();
            fprintf(stderr, "[lang] SelectionComponent obj=%s propCount=%d\n",
                    dlg->objectName().toUtf8().constData(), mo->propertyCount());
            for (int i = 0; i < mo->propertyCount(); i++) {
                QMetaProperty p = mo->property(i);
                QVariant v = p.read(dlg);
                fprintf(stderr, "[lang]   %s : %s = %s\n", p.name(), p.typeName(),
                        v.toString().left(80).toUtf8().constData());
            }
        }
        QVariant ret;
        QMetaObject::invokeMethod(g_langHelper, "patchLanguageDialog", Q_RETURN_ARG(QVariant, ret),
                                  Q_ARG(QVariant, QVariant::fromValue((QObject *)dlg)));
        if (ret.toBool())
            fprintf(stderr, "[impl] 语言对话框已补 zh_CN\n");
    }
}

// ─── glyph_selection_ai: 选区工具栏 AI 按钮 (原 glyph_selection_ai.qmd 的运行时版) ───
// 选区工具栏 (SelectionContextualMenu) 在用户手写圈选时动态创建, 靠 2s 扫描捕获。
// 找到后从 glyph_ai_button.qml 创建按钮, 显式传 tools + selectionRoot。
static QQmlComponent *g_glyphComp = nullptr;

// 向上爬 parent 链找类名含 key 的祖先
static QQuickItem *findAncestorByClass(QQuickItem *item, const char *key) {
    for (QQuickItem *p = item ? item->parentItem() : nullptr; p; p = p->parentItem())
        if (QByteArray(p->metaObject()->className()).contains(key))
            return p;
    return nullptr;
}

// 递归收集所有类名含 key 的节点
static void findAllByClass(QQuickItem *item, const char *key, QList<QQuickItem *> &out) {
    if (!item)
        return;
    if (QByteArray(item->metaObject()->className()).contains(key))
        out.append(item);
    for (QQuickItem *c : item->childItems())
        findAllByClass(c, key, out);
}

static void doInjectGlyphAI(QQmlEngine *engine) {
    for (QWindow *w : QGuiApplication::topLevelWindows()) {
        auto *qw = qobject_cast<QQuickWindow *>(w);
        if (!qw || !qw->contentItem())
            continue;
        QList<QQuickItem *> menus;
        findAllByClass(qw->contentItem(), "SelectionContextualMenu", menus);
        for (QQuickItem *tools : menus) {
            // 只处理手写选区版 (祖先是 SceneSelectionHandler; 文本选择版祖先是 TextSelectionMenu)
            QQuickItem *selRoot = findAncestorByClass(tools, "SceneSelectionHandler");
            if (!selRoot)
                continue;
            // 找按钮容器: 有 ≥2 个 Button 子节点的那层 (菜单可能包 contentItem/Row)
            QQuickItem *row = nullptr;
            QQuickItem *firstBtn = nullptr;
            QList<QQuickItem *> stack{tools};
            while (!stack.isEmpty() && !row) {
                QQuickItem *cur = stack.takeFirst();
                int nBtn = 0;
                QQuickItem *fb = nullptr;
                for (QQuickItem *c : cur->childItems()) {
                    if (QByteArray(c->metaObject()->className()).contains("Button")) {
                        if (!fb)
                            fb = c;
                        nBtn++;
                    }
                }
                if (nBtn >= 2) {
                    row = cur;
                    firstBtn = fb;
                    break;
                }
                for (QQuickItem *c : cur->childItems())
                    stack.append(c);
            }
            if (!row) { // 结构对不上, dump 一次供诊断
                static bool dumped = false;
                if (!dumped) {
                    dumped = true;
                    int n = 0;
                    fprintf(stderr, "[impl] glyph: 未找到按钮容器, dump tools 子树:\n");
                    dumpSubtree(tools, 0, n);
                }
                continue;
            }
            // 幂等
            bool has = false;
            for (QQuickItem *c : row->childItems())
                if (c->objectName().toUtf8() == "rmkitGlyphAiButton") {
                    has = true;
                    break;
                }
            if (has)
                continue;
            if (!g_glyphComp) {
                g_glyphComp = new QQmlComponent(engine, QUrl("file:///home/root/rmkit-cn/bin/glyph_ai_button.qml"));
                if (g_glyphComp->isError())
                    fprintf(stderr, "[impl] glyphComp ERR: %s\n", g_glyphComp->errorString().toUtf8().constData());
            }
            if (g_glyphComp->isError())
                continue;
            // 用原生菜单的 QQmlContext 创建 (同 text: 让组件能看到 xochitl 注册的上下文对象)
            QQmlContext *gctx = findUsableContext(tools, engine);
            QObject *obj = g_glyphComp->create(gctx);
            auto *btn = qobject_cast<QQuickItem *>(obj);
            if (!btn)
                continue;
            btn->setProperty("tools", QVariant::fromValue((QObject *)tools));
            btn->setProperty("selectionRoot", QVariant::fromValue((QObject *)selRoot));
            // 尺寸交给 qml 固定值 (注入瞬间 firstBtn 可能还没布局, width()=0 会塌成 0x0)
            btn->setParentItem(row);
            if (firstBtn)
                btn->stackBefore(firstBtn); // 排最前 (qmd 版在 selectionCut 前)
            fprintf(stderr, "[impl] glyph AI 按钮注入完成 (row=%s, 兄弟=%d)\n",
                    row->metaObject()->className(), (int)row->childItems().size());
        }
    }
}

// ─── ai_text_button: 打字文本选择菜单 AI 按钮 (原 ai_text_button.qmd 的运行时版) ───
// 文本选择菜单 (TextSelectionMenu 下的 SelectionContextualMenu) 动态创建, 靠 2s 扫描捕获。
static QQmlComponent *g_textAiComp = nullptr;

static void doInjectTextAI(QQmlEngine *engine) {
    for (QWindow *w : QGuiApplication::topLevelWindows()) {
        auto *qw = qobject_cast<QQuickWindow *>(w);
        if (!qw || !qw->contentItem())
            continue;
        QList<QQuickItem *> menus;
        findAllByClass(qw->contentItem(), "SelectionContextualMenu", menus);
        for (QQuickItem *tools : menus) {
            // 只处理文本选择版 (祖先是 TextSelectionMenu; 手写选区版祖先是 SceneSelectionHandler)
            QQuickItem *menuRoot = findAncestorByClass(tools, "TextSelectionMenu");
            if (!menuRoot)
                continue;
            // 找按钮容器 (≥2 个 Button 子节点那层)
            QQuickItem *row = nullptr, *firstBtn = nullptr;
            QList<QQuickItem *> stack{tools};
            while (!stack.isEmpty() && !row) {
                QQuickItem *cur = stack.takeFirst();
                int nBtn = 0;
                QQuickItem *fb = nullptr;
                for (QQuickItem *c : cur->childItems())
                    if (QByteArray(c->metaObject()->className()).contains("Button")) {
                        if (!fb)
                            fb = c;
                        nBtn++;
                    }
                if (nBtn >= 2) {
                    row = cur;
                    firstBtn = fb;
                    break;
                }
                for (QQuickItem *c : cur->childItems())
                    stack.append(c);
            }
            if (!row)
                continue;
            // 幂等
            bool has = false;
            for (QQuickItem *c : row->childItems())
                if (c->objectName().toUtf8() == "rmkitTextAiButton") {
                    has = true;
                    break;
                }
            if (has)
                continue;
            if (!g_textAiComp) {
                g_textAiComp = new QQmlComponent(engine, QUrl("file:///home/root/rmkit-cn/bin/text_ai_button.qml"));
                if (g_textAiComp->isError())
                    fprintf(stderr, "[impl] textAiComp ERR: %s\n", g_textAiComp->errorString().toUtf8().constData());
            }
            if (g_textAiComp->isError())
                continue;
            // 用原生菜单所在的 QQmlContext 创建, 这样组件能看到 xochitl 注册在该上下文里的
            // 对象 (Clipboard 等); 用 engine->rootContext() 创建则 Clipboard 是 undefined。
            QQmlContext *base = findUsableContext(tools, engine);
            // 建一个子上下文挂 rmkitClipText (C++ 读系统剪贴板喂给 QML —— QML 侧的
            // Clipboard 单例在运行时注入组件里不可见, 实测 typeof undefined)
            if (!g_clipCtx)
                g_clipCtx = new QQmlContext(base, QCoreApplication::instance());
            refreshClipBridge();
            flog("[textAI] 注入按钮 ctx=%p clipLen=%d\n", (void *)g_clipCtx,
                 (int)QGuiApplication::clipboard()->text().length());
            { // 一次性 dump controller 的方法/属性, 找直接取选中文字的 API
                static bool dumped = false;
                if (!dumped) {
                    dumped = true;
                    QVariant cv = menuRoot->property("controller");
                    QObject *ctrl = cv.value<QObject *>();
                    for (QQuickItem *pp = menuRoot; pp && !ctrl; pp = pp->parentItem())
                        ctrl = pp->property("controller").value<QObject *>();
                    if (ctrl) {
                        const QMetaObject *mo = ctrl->metaObject();
                        flog("[ctrl] class=%s methods=%d props=%d\n", mo->className(),
                             mo->methodCount(), mo->propertyCount());
                        for (int i = 0; i < mo->methodCount(); i++) {
                            QMetaMethod m = mo->method(i);
                            QByteArray sig = m.methodSignature();
                            if (sig.contains("ext") || sig.contains("elect") || sig.contains("opy"))
                                flog("[ctrl]   M %s -> %s\n", sig.constData(), m.typeName());
                        }
                        for (int i = 0; i < mo->propertyCount(); i++) {
                            QMetaProperty pr = mo->property(i);
                            QByteArray n(pr.name());
                            if (n.contains("ext") || n.contains("elect"))
                                flog("[ctrl]   P %s : %s\n", n.constData(), pr.typeName());
                        }
                    } else {
                        flog("[ctrl] 未找到 controller\n");
                    }
                    if (ctrl)
                        hookTextCopied(ctrl);
                }
            }
            { // 每次都确保 controller 的 textCopied 已挂钩 (hookTextCopied 内部去重)
                QObject *c2 = nullptr;
                for (QQuickItem *pp = menuRoot; pp && !c2; pp = pp->parentItem())
                    c2 = pp->property("controller").value<QObject *>();
                hookTextCopied(c2);
            }
            QObject *obj = g_textAiComp->create(g_clipCtx);
            auto *btn = qobject_cast<QQuickItem *>(obj);
            if (!btn)
                continue;
            btn->setProperty("tools", QVariant::fromValue((QObject *)tools));
            btn->setProperty("menuRoot", QVariant::fromValue((QObject *)menuRoot));
            // 尺寸交给 qml 固定值 (注入瞬间 firstBtn 可能还没布局, width()=0 会塌成 0x0)
            btn->setParentItem(row);
            if (firstBtn)
                btn->stackBefore(firstBtn);
            g_textBtns.append(QPointer<QQuickItem>(btn));
            fprintf(stderr, "[impl] text AI 按钮注入完成\n");
        }
    }
}

// ─── pinyin IME: 拼音候选框 (原 pinyin_interceptor.qmd 的运行时版) ───
// 原 qmd 注入点是 MainView.qml 的 FocusScope#rootItem (全屏根节点), 运行时版
// 等价挂到主窗口 contentItem。组件只用 Qt.inputMethod + XHR, 不依赖 xochitl
// 单例, 用宿主 context (拿不到就 rootContext) 创建即可。
// 组件内 Timer 不触发 → C++ 每 250ms 写 imeTick 属性驱动 (poll 链兜底 + 候选防抖)。
static QQmlComponent *g_pinyinComp = nullptr;
static QPointer<QQuickItem> g_pinyinItem;

static void doInjectPinyin(QQmlEngine *engine) {
    if (g_pinyinItem)
        return; // 已注入且仍存活 (QPointer 在宿主销毁时自动清空 → 下轮重注入)
    if (access("/home/root/rmkit-cn/bin/pinyin_ime.qml", F_OK) != 0)
        return; // 未部署 (如 armv7 早期阶段), 静默跳过
    for (QWindow *w : QGuiApplication::topLevelWindows()) {
        auto *qw = qobject_cast<QQuickWindow *>(w);
        if (!qw || !qw->contentItem() || qw->contentItem()->width() <= 0)
            continue;
        QQuickItem *host = qw->contentItem();
        if (!g_pinyinComp) {
            g_pinyinComp = new QQmlComponent(engine, QUrl("file:///home/root/rmkit-cn/bin/pinyin_ime.qml"));
            if (g_pinyinComp->isError())
                fprintf(stderr, "[impl] pinyinComp ERR: %s\n",
                        g_pinyinComp->errorString().toUtf8().constData());
        }
        if (g_pinyinComp->isError())
            return;
        QQmlContext *ctx = QQmlEngine::contextForObject(host);
        QObject *obj = g_pinyinComp->create(ctx ? ctx : engine->rootContext());
        auto *item = qobject_cast<QQuickItem *>(obj);
        if (!item) {
            fprintf(stderr, "[impl] pinyin create 失败\n");
            return;
        }
        item->setParentItem(host);
        g_pinyinItem = item;
        flog("[pinyin] 候选框注入完成 win=%s host=%.0fx%.0f\n", qw->metaObject()->className(),
             host->width(), host->height());
        fprintf(stderr, "[impl] pinyin IME 注入完成\n");
        return;
    }
}

// 幂等 + 静默: Sidebar 未实例化时静默返回(等下一轮), 已注入过就跳过。
// 由 pw_inject 的 2s 重复定时器反复调用, 处理"开机时侧栏没建 / 导航后侧栏重建"。
static void doInject(QQmlEngine *engine) {
    for (QWindow *w : QGuiApplication::topLevelWindows()) {
        auto *qw = qobject_cast<QQuickWindow *>(w);
        if (!qw || !qw->contentItem())
            continue;
        QQuickItem *sb = findByClass(qw->contentItem(), "Sidebar");
        if (!sb)
            continue; // 侧栏还没实例化, 静默等下一轮
        QQuickItem *col = nullptr;
        for (QQuickItem *c : sb->childItems()) {
            if (QByteArray(c->metaObject()->className()).contains("ColumnLayout")) {
                col = c;
                break;
            }
        }
        if (!col)
            continue;
        // 幂等: 已有 advancedItem 就不重复注入
        for (QQuickItem *c : col->childItems())
            if (c->objectName().toUtf8() == "advancedItem")
                return;
        fprintf(stderr, "[impl] 侧栏就绪, 注入高级...\n");
        QQmlComponent comp(engine);
        comp.setData(
            "import QtQuick\n"
            "import QtQuick.Layouts\n"
            "Rectangle {\n"
            "  id: advItem\n"
            "  objectName: \"advancedItem\"\n"
            "  Layout.preferredWidth: 414\n"
            "  Layout.preferredHeight: 112\n"
            // 注入时就异步预编译面板 (Component.Asynchronous), 点击时直接用缓存, 首开不卡
            "  property var panelComp: Qt.createComponent(\n"
            "      \"file:///home/root/rmkit-cn/bin/adv_panel.qml\", Component.Asynchronous)\n"
            "  color: mouse.pressed ? \"#dddddd\" : \"transparent\"\n"
            "  Row { x:32; y:32; spacing:16\n"
            "    Image { width:48; height:48; fillMode: Image.PreserveAspectFit\n"
            "            source:\"qrc:/ark/icons/sliders_horizontal\" }\n"
            "    Text { text:\"\\u9ad8\\u7ea7\"; font.pixelSize:30; color:\"black\"\n"
            "           anchors.verticalCenter: parent.verticalCenter }\n"
            "  }\n"
            "  MouseArea { id: mouse; anchors.fill: parent\n"
            "    onClicked: {\n"
            "      var r = advItem; while (r.parent) r = r.parent;\n"
            "      var c = advItem.panelComp;\n"
            "      var mk = function() {\n"
            "        if (c.status === Component.Ready) c.createObject(r);\n"
            "        else if (c.status === Component.Error) console.log(\"[advpanel] ERR: \" + c.errorString());\n"
            "      };\n"
            "      if (c.status === Component.Loading) c.statusChanged.connect(mk); else mk();\n"
            "    }\n"
            "  }\n"
            "}\n",
            QUrl());
        if (comp.isError()) {
            fprintf(stderr, "[impl] comp ERR: %s\n", comp.errorString().toUtf8().constData());
            continue;
        }
        QObject *obj = comp.create();
        auto *item = qobject_cast<QQuickItem *>(obj);
        if (!item) {
            fprintf(stderr, "[impl] create 失败\n");
            continue;
        }
        item->setParentItem(col); // 加进 ColumnLayout, 先落到末尾
        // 重排: 移到"指南"上面 —— 指南 = settingsButton 前最近的一个 SidebarItem
        const auto kids = col->childItems();
        QQuickItem *guide = nullptr;
        for (int i = 0; i < kids.size(); i++) {
            if (kids[i]->objectName().toUtf8() == "settingsButton") {
                for (int j = i - 1; j >= 0; j--) {
                    if (QByteArray(kids[j]->metaObject()->className()).contains("SidebarItem")) {
                        guide = kids[j];
                        break;
                    }
                }
                break;
            }
        }
        if (guide)
            item->stackBefore(guide);
        fprintf(stderr, "[impl] 高级 注入完成 (%s)\n", guide ? "已排到指南上面" : "留末尾");
        return; // 本轮成功
    }
}

extern "C" __attribute__((visibility("default"))) void pw_inject(void *enginePtr) {
    auto *engine = reinterpret_cast<QQmlEngine *>(enginePtr);
    if (!engine || !QCoreApplication::instance())
        return;
    // marshal 到主线程, 起一个每 2s 的重复定时器: 反复幂等注入
    // (处理: 开机时侧栏未建 / 用户导航后侧栏重建 → 我们的高级会被重新补上)
    QMetaObject::invokeMethod(
        QCoreApplication::instance(),
        [engine]() {
            fprintf(stderr, "[impl] 启动重复注入检查 (每 2s)\n");
            QTimer *t = new QTimer(QCoreApplication::instance());
            t->setInterval(1000); // 1s: 平衡响应 (语言列表注入延迟) 与全树扫描 CPU
            QObject::connect(t, &QTimer::timeout, [engine]() {
                g_engineForClip = engine;
                maybeDumpAll();
                { // 主动求值 Clipboard 单例: 不依赖"用户触发按钮注入"这条路径
                    static int tries = 0;
                    if (!g_clipSingleton && tries < 600) {
                        tries++;
                        for (QWindow *w : QGuiApplication::topLevelWindows()) {
                            auto *qw = qobject_cast<QQuickWindow *>(w);
                            if (!qw || !qw->contentItem())
                                continue;
                            // 从任意深层节点向上找能求值 Clipboard 的上下文
                            QQuickItem *probe = findByClass(qw->contentItem(), "SceneView");
                            if (!probe)
                                probe = qw->contentItem();
                            QQmlContext *c = findUsableContext(probe, engine);
                            if (g_clipSingleton) {
                                if (!g_clipCtx)
                                    g_clipCtx = new QQmlContext(c, QCoreApplication::instance());
                                flog("[clip] 主循环求值成功, tries=%d\n", tries);
                                break;
                            }
                        }
                        if (!g_clipSingleton && tries % 20 == 1)
                            flog("[clip] 主循环仍未求出 Clipboard, tries=%d\n", tries);
                    }
                }
                refreshClipBridge(); // 每秒刷新剪贴板桥, 面板重试时能读到最新值
                { // 剪贴板状态监视: 只在内容变化时打日志, 用于定位 copySelectedText 写到哪
                    static QString lastSeen("\x01");
                    QClipboard *cb = QGuiApplication::clipboard();
                    QString now = cb ? cb->text() : QString();
                    const QMimeData *md = cb ? cb->mimeData() : nullptr;
                    QString fmts = md ? md->formats().join(QStringLiteral(",")) : QStringLiteral("<null>");
                    QString sig = now + QStringLiteral("|") + fmts;
                    if (sig != lastSeen) {
                        lastSeen = sig;
                        flog("[clipwatch] text.len=%d formats=[%s]\n",
                             (int)now.length(), fmts.toUtf8().constData());
                    }
                }
                doInject(engine);
                doInjectLanguage(engine);
                doInjectGlyphAI(engine);
                doInjectTextAI(engine);
                doInjectPinyin(engine);
            });
            t->start();
            // pinyin IME 心跳: 250ms 写 imeTick, 驱动组件内的 poll 链兜底 + 候选防抖
            // (运行时注入组件里 Timer 不触发, 由 C++ 供拍)
            QTimer *tick = new QTimer(QCoreApplication::instance());
            tick->setInterval(250);
            QObject::connect(tick, &QTimer::timeout, []() {
                static int n = 0;
                if (g_pinyinItem)
                    g_pinyinItem->setProperty("imeTick", ++n);
            });
            tick->start();
            doInject(engine); // 立即试一次
        },
        Qt::QueuedConnection);
}
