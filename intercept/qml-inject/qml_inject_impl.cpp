// qml_inject_impl.cpp — 胖注入库 (链接 Qt, 由瘦 hook dlopen 加载)
//
// 方案 A 的第二半: 真正的运行时 QML 注入。
// 由 thin_hook 的 worker 线程 dlopen + 调 pw_inject(engine)。
// 此时我们在 worker 线程, 必须 QMetaObject::invokeMethod marshal 到 GUI 主线程
// 才能安全操作 QML 对象树。

#include <cstdio>

#include <QtCore/QByteArray>
#include <QtCore/QCoreApplication>
#include <QtCore/QThread>
#include <QtCore/QUrl>
#include <QtGui/QGuiApplication>
#include <QtQml/QQmlComponent>
#include <QtQml/QQmlEngine>
#include <QtQuick/QQuickItem>
#include <QtQuick/QQuickWindow>

// dump 一个节点的完整子树 (只用于已找到的 Sidebar, 子树很小)
static void dumpSubtree(QQuickItem *item, int depth, int &count) {
    if (!item || count > 400)
        return;
    count++;
    const char *cls = item->metaObject()->className();
    QByteArray on = item->objectName().toUtf8();
    fprintf(stderr, "[sb] %*sd%d %s%s%s sz=(%.0fx%.0f) pos=(%.0f,%.0f) vis=%d nch=%d\n",
            depth, "", depth, cls,
            on.isEmpty() ? "" : " obj=", on.isEmpty() ? "" : on.constData(),
            item->width(), item->height(), item->x(), item->y(),
            item->isVisible() ? 1 : 0, (int)item->childItems().size());
    for (QQuickItem *c : item->childItems())
        dumpSubtree(c, depth + 1, count);
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

static void doInject(QQmlEngine *engine) {
    fprintf(stderr, "[impl] doInject: enter\n");
    for (QWindow *w : QGuiApplication::topLevelWindows()) {
        auto *qw = qobject_cast<QQuickWindow *>(w);
        if (!qw || !qw->contentItem())
            continue;
        // 1. 找 Sidebar
        QQuickItem *sb = findByClass(qw->contentItem(), "Sidebar");
        if (!sb) {
            fprintf(stderr, "[impl] no Sidebar in tree, skip\n");
            continue;
        }
        fprintf(stderr, "[impl] Sidebar=%s\n", sb->metaObject()->className());
        // 2. 找 Sidebar 下的 ColumnLayout (装菜单项的列)
        QQuickItem *col = nullptr;
        for (QQuickItem *c : sb->childItems()) {
            if (QByteArray(c->metaObject()->className()).contains("ColumnLayout")) {
                col = c;
                break;
            }
        }
        if (!col) {
            fprintf(stderr, "[impl] Sidebar 下没找到 ColumnLayout\n");
            continue;
        }
        fprintf(stderr, "[impl] menu column=%s nch=%d\n", col->metaObject()->className(),
                (int)col->childItems().size());
        // 3. 创建"高级"项, 加进列容器 (ColumnLayout 需要 Layout 附加属性)
        fprintf(stderr, "[impl] creating 高级 item...\n");
        QQmlComponent comp(engine);
        comp.setData(
            "import QtQuick\n"
            "import QtQuick.Layouts\n"
            "Rectangle {\n"
            "  id: advItem\n"
            "  objectName: \"advancedItem\"\n"
            "  Layout.preferredWidth: 414\n"
            "  Layout.preferredHeight: 112\n"
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
            "      var c = Qt.createComponent(\"file:///home/root/rmkit-cn/bin/adv_panel.qml\");\n"
            "      console.log(\"[advpanel] createComponent status=\" + c.status);\n"
            "      var mk = function() {\n"
            "        if (c.status === Component.Ready) {\n"
            "          var o = c.createObject(r);\n"
            "          console.log(\"[advpanel] created obj=\" + o);\n"
            "        } else if (c.status === Component.Error) {\n"
            "          console.log(\"[advpanel] ERR: \" + c.errorString());\n"
            "        }\n"
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
        if (guide) {
            item->stackBefore(guide);
            fprintf(stderr, "[impl] STAGE2b OK: 高级 已插到指南(%s)上面\n",
                    guide->objectName().isEmpty() ? "guide" : guide->objectName().toUtf8().constData());
        } else {
            fprintf(stderr, "[impl] STAGE2b OK: 高级 注入(未找到指南锚点, 留在末尾)\n");
        }
    }
    fprintf(stderr, "[impl] doInject: done\n");
}

extern "C" __attribute__((visibility("default"))) void pw_inject(void *enginePtr) {
    auto *engine = reinterpret_cast<QQmlEngine *>(enginePtr);
    fprintf(stderr, "[impl] pw_inject(engine=%p), marshal to GUI thread\n", enginePtr);
    if (!engine || !QCoreApplication::instance()) {
        fprintf(stderr, "[impl] no engine/app, abort\n");
        return;
    }
    // 我们在 worker pthread; 把注入排到主线程事件循环执行
    QMetaObject::invokeMethod(
        QCoreApplication::instance(), [engine]() { doInject(engine); },
        Qt::QueuedConnection);
}
