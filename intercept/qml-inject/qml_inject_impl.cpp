// qml_inject_impl.cpp — 胖注入库 (链接 Qt, 由瘦 hook dlopen 加载)
//
// 方案 A 的第二半: 真正的运行时 QML 注入。
// 由 thin_hook 的 worker 线程 dlopen + 调 pw_inject(engine)。
// 此时我们在 worker 线程, 必须 QMetaObject::invokeMethod marshal 到 GUI 主线程
// 才能安全操作 QML 对象树。

#include <cstdio>
#include <unistd.h>

#include <QtCore/QByteArray>
#include <QtCore/QCoreApplication>
#include <QtCore/QList>
#include <QtCore/QMetaProperty>
#include <QtCore/QThread>
#include <QtCore/QTimer>
#include <QtCore/QUrl>
#include <QtGui/QGuiApplication>
#include <QtQml/QQmlComponent>
#include <QtQml/QQmlEngine>
#include <QtQuick/QQuickItem>
#include <QtQuick/QQuickWindow>

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
            QObject *obj = g_glyphComp->create();
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
            QObject *obj = g_textAiComp->create();
            auto *btn = qobject_cast<QQuickItem *>(obj);
            if (!btn)
                continue;
            btn->setProperty("tools", QVariant::fromValue((QObject *)tools));
            btn->setProperty("menuRoot", QVariant::fromValue((QObject *)menuRoot));
            // 尺寸交给 qml 固定值 (注入瞬间 firstBtn 可能还没布局, width()=0 会塌成 0x0)
            btn->setParentItem(row);
            if (firstBtn)
                btn->stackBefore(firstBtn);
            fprintf(stderr, "[impl] text AI 按钮注入完成\n");
        }
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
                maybeDumpAll();
                doInject(engine);
                doInjectLanguage(engine);
                doInjectGlyphAI(engine);
                doInjectTextAI(engine);
            });
            t->start();
            doInject(engine); // 立即试一次
        },
        Qt::QueuedConnection);
}
