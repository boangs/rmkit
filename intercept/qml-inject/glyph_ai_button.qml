// glyph_ai_button.qml — 选区工具栏 AI 按钮 (glyph_selection_ai.qmd 的运行时注入版)
// 由 qml_inject_impl.so 在发现 SceneSelectionHandler 的 SelectionContextualMenu 时创建。
// 创建时必须赋值:
//   tools         — SelectionContextualMenu 实例 (选区工具栏)
//   selectionRoot — Item#selectionRoot (SceneSelectionHandler 根, 用于爬 parent 链)
// qmd 版的词法引用 tools/selectionRoot 全部改走这两个 property。
import QtQuick

Item {
    id: aiGlyphButton
    objectName: "rmkitGlyphAiButton"

    property var tools: null
    property var selectionRoot: null

    // 尺寸对齐原生选区工具栏按钮 (~80x80 图标按钮)
    width: 80
    height: 80

    // 白底实底: 选区菜单浮在文档页面上, 无背景会透出页面墨迹显得像黑块 (原生按钮也是白底)
    Rectangle {
        anchors.fill: parent
        // 分隔竖线画在格子交界处、位于本按钮之下, 白底右侧留 2px 露出它
        // (3px 会显得比原生分隔线粗)
        anchors.rightMargin: 2
        color: btnMa.pressed ? "#dddddd" : "white"
        // 原生格子是直角, 整体 radius 会让按钮像独立浮块; 本按钮在最左端,
        // 只给左侧两角圆角以贴合容器外框弧度 (Qt 6.7+ 支持逐角 radius, 设备 6.10)
        radius: 0
        topLeftRadius: 8
        bottomLeftRadius: 8
    }
    // 图标: 旧 qmd 版同款 notebook_sparkles (已确认存在于 3.28 固件 QRC,
    // adv_panel 里同集合的 cog/cloud_upload 等运行时注入下能正常显示)
    Image {
        id: aiIcon
        anchors.centerIn: parent
        source: "qrc:/ark/icons/notebook_sparkles"
        width: 44; height: 44
        sourceSize.width: 44; sourceSize.height: 44
        fillMode: Image.PreserveAspectFit
        asynchronous: false
    }
    // 兜底: 图标没加载出来时显示 "AI" 文字, 避免空白按钮
    Text {
        visible: aiIcon.status !== Image.Ready
        anchors.centerIn: parent
        text: "AI"
        font.pixelSize: 30
        font.weight: Font.DemiBold
        color: "black"
    }
    MouseArea {
        id: btnMa
        anchors.fill: parent
        onClicked: {
            if (!aiGlyphButton.tools || !aiGlyphButton.selectionRoot) return
            var host = aiGlyphButton.Window.window.contentItem
            var btnPos = aiGlyphButton.mapToItem(host, 0, 0)
            aiGlyphButton.tools.visible = false
            glyphMenuComp.createObject(host, {
                selX: btnPos.x,
                selY: btnPos.y + aiGlyphButton.height / 2,
                tools: aiGlyphButton.tools,
                selectionRoot: aiGlyphButton.selectionRoot
            })
        }
    }

    Component {
        id: glyphMenuComp
        Rectangle {
            id: glyphMenu
            property real selX: 0
            property real selY: 0
            property var tools: null
            property var selectionRoot: null
            z: 99999
            color: "#ffffff"
            radius: 8
            border.color: "#888888"
            border.width: 2
            width: 480
            height: 72
            x: selX
            y: selY - 36
            MouseArea { anchors.fill: parent; onClicked: {} }
            Row {
                anchors.fill: parent
                Repeater {
                    model: ["润色", "翻译", "总结", "回答"]
                    delegate: Item {
                        width: 120; height: 72
                        Rectangle {
                            visible: index > 0
                            x: 0; y: 12; width: 1; height: 48
                            color: "#444444"
                        }
                        Text {
                            anchors.centerIn: parent
                            text: modelData
                            font.pixelSize: 28
                            color: "#333333"
                        }
                        MouseArea {
                            anchors.fill: parent
                            onClicked: (mouse) => {
                                var label = modelData
                                var ps = [
                                    "请润色以下手写文字，保持原意让表达更自然。直接输出。",
                                    "中文翻译为英文，其他语言翻译为中文。直接输出译文。",
                                    "简洁总结以下手写内容核心要点。直接输出。",
                                    "回答以下手写问题，不用Markdown。"
                                ]
                                var selectionRoot = glyphMenu.selectionRoot
                                var sr = glyphMenu.tools.selectionRect
                                var host = glyphMenu.Window.window.contentItem
                                // 把选区上下边映射到 host 坐标，让 panel 紧贴选区
                                var srTopHost = selectionRoot.mapToItem(host, sr.x, sr.y)
                                var srBotHost = selectionRoot.mapToItem(host, sr.x, sr.y + sr.height)
                                // 找 glyphSelection.selectionBoundingRect: 选区真实 scene bounds
                                var sceneBL = Qt.point(0, 0)
                                var foundBR = false
                                var pp2 = selectionRoot
                                for (var bi = 0; bi < 25; bi++) {
                                    if (!pp2) break
                                    try {
                                        if (pp2.glyphSelection && pp2.glyphSelection.selectionBoundingRect) {
                                            var sb = pp2.glyphSelection.selectionBoundingRect
                                            if (sb.width > 0 || sb.height > 0) {
                                                sceneBL = Qt.point(sb.x, sb.y + sb.height)
                                                foundBR = true
                                                break
                                            }
                                        }
                                        if (!foundBR && pp2.selectionBoundingRect) {
                                            var sb2 = pp2.selectionBoundingRect
                                            if (sb2.width > 0 || sb2.height > 0) {
                                                sceneBL = Qt.point(sb2.x, sb2.y + sb2.height)
                                                foundBR = true
                                                break
                                            }
                                        }
                                    } catch(e) {}
                                    pp2 = pp2.parent
                                }
                                if (!foundBR) console.warn("SELECTBBOX not found in parent chain")
                                var panel = glyphPanelComp.createObject(host, {
                                    cursorTopY: srTopHost.y,
                                    cursorBottomY: srBotHost.y,
                                    isStreaming: true,
                                    actionLabel: label,
                                    bodyText: "",
                                    xhrPromptPrefix: ps[index],
                                    xhrSelX: sr.x, xhrSelY: sr.y,
                                    xhrSelW: sr.width, xhrSelH: sr.height,
                                    selectionRoot: selectionRoot,
                                    insertSceneX: sceneBL.x,
                                    insertSceneY: sceneBL.y
                                })
                                function _destroyPanel() {
                                    if (panel) {
                                        if (panel._xhrRef) {
                                            try { panel._xhrRef.abort() } catch(e) {}
                                            panel._xhrRef = null
                                        }
                                        try { panel.destroy() } catch(e) {}
                                        panel = null
                                    }
                                }
                                if (panel) {
                                    panel.cancelClicked.connect(_destroyPanel)
                                    panel.closeClicked.connect(_destroyPanel)
                                }
                                glyphMenu.destroy()
                            }
                        }
                    }
                }
            }
        }
    }

    Component {
        id: glyphPanelComp
        Rectangle {
            id: gp
            property string bodyText: ""
            property string actionLabel: ""
            property bool isStreaming: true
            property real cursorTopY: 0
            property real cursorBottomY: 0
            property string xhrPromptPrefix: ""
            property real xhrSelX: 0
            property real xhrSelY: 0
            property real xhrSelW: 0
            property real xhrSelH: 0
            property var selectionRoot: null
            // 选区底部位置（scene 坐标），用于插入文字时定位光标
            property real insertSceneX: 0
            property real insertSceneY: 0
            // 持有 XHR 引用防止 V8 GC 在 streaming 中途回收 → onreadystatechange 失效
            property var _xhrRef: null
            signal closeClicked()
            signal cancelClicked()

            // 段落格式化: 折叠连续空行 + 段首两个全角空格缩进
            function _formatParagraphs(s) {
                if (!s) return ""
                var trimmed = s.replace(/^[\s\n]+/, "")
                var collapsed = trimmed.replace(/\n+/g, "\n")
                var lines = collapsed.split("\n")
                var out = []
                for (var i = 0; i < lines.length; i++) {
                    var line = lines[i]
                    if (line.length > 0) out.push("　　" + line)
                    else out.push(line)
                }
                return out.join("\n")
            }

            property int pageIdx: 0
            property bool _focusGuardReady: false
            Timer { interval: 400; running: true; repeat: false; onTriggered: gp._focusGuardReady = true }
            Connections {
                target: gp.Window.window; ignoreUnknownSignals: true
                function onActiveFocusItemChanged() {
                    if (!gp._focusGuardReady) return
                    var win = gp.Window.window
                    if (!win || !win.visible) return
                    var item = win.activeFocusItem
                    if (item && (item.controller || item.text !== undefined)) return
                    gp.closeClicked()
                }
            }

            z: 9999; radius: 16; color: "#ffffff"; border.width: 0
            width: parent ? Math.round(parent.width * 0.82) : 800
            height: parent ? Math.round(parent.height * 0.26) : 560
            readonly property real bodyAvailableH: Math.max(50, height - 77 - 72)
            x: {
                var win = gp.Window.window
                if (!win || !parent) return 0
                return Math.round(win.width / 2 - parent.mapToItem(null, 0, 0).x - width / 2)
            }
            y: {
                var pH = parent ? parent.height : 1872
                var below = cursorBottomY + 24
                if (below + height <= pH - 24) return below
                var above = cursorTopY - 24 - height
                if (above >= 24) return above
                return 24
            }
            MouseArea { anchors.fill: parent; onClicked: {} }

            Canvas {
                id: dashedBorder
                anchors.fill: parent
                onWidthChanged: requestPaint()
                onHeightChanged: requestPaint()
                Timer { interval: 30; running: true; repeat: false; onTriggered: dashedBorder.requestPaint() }
                onPaint: {
                    var ctx = getContext("2d")
                    ctx.clearRect(0, 0, width, height)
                    ctx.strokeStyle = "#444444"
                    ctx.lineWidth = 1
                    ctx.setLineDash([8, 5])
                    var r = gp.radius, w = width, h = height
                    ctx.beginPath()
                    ctx.moveTo(r, 0.5); ctx.lineTo(w-r, 0.5)
                    ctx.quadraticCurveTo(w-0.5, 0.5, w-0.5, r)
                    ctx.lineTo(w-0.5, h-r)
                    ctx.quadraticCurveTo(w-0.5, h-0.5, w-r, h-0.5)
                    ctx.lineTo(r, h-0.5)
                    ctx.quadraticCurveTo(0.5, h-0.5, 0.5, h-r)
                    ctx.lineTo(0.5, r); ctx.quadraticCurveTo(0.5, 0.5, r, 0.5)
                    ctx.closePath(); ctx.stroke()
                }
            }

            // XHR 用 Timer 延迟启动，确保 panel 完全初始化后再发请求
            Timer {
                id: xhrTimer
                interval: 50
                running: true
                repeat: false
                onTriggered: {
                    if (xhrPromptPrefix.length === 0) return
                    var fmt = _formatParagraphs
                    // xhr 必须挂到 gp._xhrRef, 否则局部变量被 V8 GC 回收 → 回调失效
                    var xhr = new XMLHttpRequest()
                    gp._xhrRef = xhr
                    xhr.open("POST", "http://127.0.0.1:8080/ai-glyph-chat")
                    xhr.setRequestHeader("Content-Type", "application/json")
                    var lastLen = 0; var tail = ""; var full = ""
                    xhr.onreadystatechange = function() {
                        var rs = xhr.readyState
                        if (rs !== XMLHttpRequest.LOADING && rs !== XMLHttpRequest.DONE) return
                        var chunk = xhr.responseText.substring(lastLen)
                        lastLen = xhr.responseText.length
                        var lines = (tail + chunk).split("\n")
                        if (rs === XMLHttpRequest.DONE) { tail = "" } else { tail = lines.pop() }
                        for (var i = 0; i < lines.length; i++) {
                            var line = lines[i].replace(/\r$/, "")
                            if (!line) continue
                            var d; try { d = JSON.parse(line) } catch(e) { continue }
                            if (d.meta) continue
                            if (typeof d.text === "string") {
                                full += d.text
                                gp.bodyText = fmt(full)
                            } else if (d.error) {
                                gp.bodyText = "[错误] " + d.error
                            }
                        }
                        if (rs === XMLHttpRequest.DONE) {
                            gp.isStreaming = false
                            if (gp.bodyText.length === 0) {
                                gp.bodyText = "[服务无返回] 状态码 " + xhr.status + ". 请稍后重试或点击取消关闭。"
                            }
                        }
                    }
                    // 不设 xhr.timeout: AI 返回有时 1-2 分钟, 取消按钮可随时关
                    xhr.onerror = function() {
                        gp.isStreaming = false
                        if (gp.bodyText.length === 0) gp.bodyText = "[网络错误] 请检查 upload-server 是否运行, 或点击取消关闭。"
                    }
                    xhr.send(JSON.stringify({
                        prompt_prefix: xhrPromptPrefix,
                        sel_x: xhrSelX, sel_y: xhrSelY,
                        sel_w: xhrSelW, sel_h: xhrSelH
                    }))
                }
            }

            Item {
                id: gpStatus
                anchors.top: parent.top; anchors.left: parent.left; anchors.right: parent.right
                anchors.leftMargin: 36; anchors.rightMargin: 36; anchors.topMargin: 14; height: 40
                Text {
                    anchors.left: parent.left; anchors.verticalCenter: parent.verticalCenter
                    color: "#333333"; font.pixelSize: 25
                    text: gp.actionLabel + " · " + (gp.isStreaming ? "正在生成…" : "已生成 " + gp.bodyText.length + " 字")
                }
                Row {
                    anchors.right: parent.right; anchors.verticalCenter: parent.verticalCenter
                    spacing: 18; visible: gpBody.totalPages > 1
                    Item {
                        width: 72; height: 40
                        Image { anchors.centerIn: parent; source: "qrc:/ark/icons/arrow_right"; width: 36; height: 36; sourceSize.width: 36; sourceSize.height: 36; fillMode: Image.PreserveAspectFit; opacity: gp.pageIdx > 0 ? 1.0 : 0.3; transform: Scale { origin.x: 18; origin.y: 18; xScale: -1 } }
                        MouseArea { anchors.fill: parent; enabled: gp.pageIdx > 0; onClicked: gp.pageIdx = Math.max(0, gp.pageIdx - 1) }
                    }
                    Text { anchors.verticalCenter: parent.verticalCenter; color: "#333333"; font.pixelSize: 25; text: (gp.pageIdx + 1) + "/" + gpBody.totalPages }
                    Item {
                        width: 72; height: 40
                        Image { anchors.centerIn: parent; source: "qrc:/ark/icons/arrow_right"; width: 36; height: 36; sourceSize.width: 36; sourceSize.height: 36; fillMode: Image.PreserveAspectFit; opacity: gp.pageIdx < gpBody.totalPages - 1 ? 1.0 : 0.3 }
                        MouseArea { anchors.fill: parent; enabled: gp.pageIdx < gpBody.totalPages - 1; onClicked: gp.pageIdx = Math.min(gpBody.totalPages - 1, gp.pageIdx + 1) }
                    }
                }
            }
            Rectangle {
                id: gpSep
                anchors.top: gpStatus.bottom; anchors.left: parent.left; anchors.right: parent.right
                anchors.leftMargin: 36; anchors.rightMargin: 36; anchors.topMargin: 8
                height: 1; color: "#666666"
            }
            Item {
                id: gpBody
                anchors.left: parent.left; anchors.right: parent.right
                anchors.top: gpSep.bottom; anchors.leftMargin: 36; anchors.rightMargin: 36; anchors.topMargin: 14
                height: pageH; clip: true
                readonly property real lineH: (gpTxt.lineCount > 0 && gpTxt.implicitHeight > 0) ? (gpTxt.implicitHeight / gpTxt.lineCount) : 42
                readonly property int linesPerPage: Math.max(1, Math.floor(gp.bodyAvailableH / lineH))
                readonly property real pageH: linesPerPage * lineH
                readonly property int totalPages: gpTxt.lineCount > 0 ? Math.max(1, Math.ceil(gpTxt.lineCount / linesPerPage)) : 1
                Text {
                    id: gpTxt; y: -gp.pageIdx * gpBody.pageH; width: gpBody.width
                    wrapMode: Text.Wrap; font.pixelSize: 30; color: "#000000"; lineHeight: 1.4; lineHeightMode: Text.ProportionalHeight
                    text: gp.bodyText.length > 0 ? gp.bodyText : "AI 思考中..."
                    onLineCountChanged: { var t = gpBody.totalPages; gp.pageIdx = Math.max(0, Math.min(gp.pageIdx, t - 1)) }
                }
            }
            // 手写模式开关：开启后插入文字时模拟笔写而不是直接键入
            property bool handwritingMode: false

            Rectangle {
                id: gpHandwriteToggle
                anchors.bottom: parent.bottom
                anchors.left: parent.left
                anchors.bottomMargin: 24
                anchors.leftMargin: 36
                width: 180; height: 40
                color: "#ffffff"
                Text {
                    anchors.centerIn: parent
                    font.pixelSize: 26
                    color: "#000000"
                    text: gp.handwritingMode ? "✍ 手写：开" : "✍ 手写：关"
                }
                MouseArea { anchors.fill: parent; onClicked: gp.handwritingMode = !gp.handwritingMode }
            }

            Rectangle {
                id: gpBtns
                anchors.bottom: parent.bottom; anchors.horizontalCenter: parent.horizontalCenter
                anchors.bottomMargin: 16; width: 320; height: 56; radius: 28; color: "#ffffff"; border.width: 0
                Item {
                    anchors.left: parent.left; anchors.right: gpDiv.left; anchors.top: parent.top; anchors.bottom: parent.bottom
                    Text {
                        anchors.centerIn: parent
                        color: gp.isStreaming ? "#999999" : "#000000"
                        font.pixelSize: 28
                        text: "插入"
                    }
                    MouseArea {
                        anchors.fill: parent
                        enabled: !gp.isStreaming
                        onClicked: {
                            var bodyToInsert = gp.bodyText
                            if (bodyToInsert.length === 0) { gp.closeClicked(); return }

                            var ctrlRef = null
                            var tbRef = null
                            var p = gp.selectionRoot
                            for (var i = 0; i < 25; i++) {
                                if (!p) break
                                if (!ctrlRef && p.controller) ctrlRef = p.controller
                                if (!tbRef && p.toolbar) tbRef = p.toolbar
                                p = p.parent
                            }

                            if (gp.handwritingMode) {
                                // 手写模式：清选区 + 切笔工具 + POST 后端模拟笔写
                                if (ctrlRef) { try { ctrlRef.clearSelectedItems() } catch(e) {} }
                                if (tbRef) {
                                    try { tbRef.selectPen("primary") } catch(e) { console.warn("selectPen err: " + e) }
                                }
                                var hwXhr = new XMLHttpRequest()
                                hwXhr.open("POST", "http://127.0.0.1:8080/ai-glyph-handwrite")
                                hwXhr.setRequestHeader("Content-Type", "application/json")
                                hwXhr.send(JSON.stringify({
                                    text: bodyToInsert,
                                    sel_x: gp.xhrSelX,
                                    sel_y: gp.xhrSelY + gp.xhrSelH,
                                    sel_w: gp.xhrSelW
                                }))
                            } else {
                                // 直接插入文字: typingModeSelected 必需, 键盘用 inputMethod.hide 关
                                if (ctrlRef) { try { ctrlRef.clearSelectedItems() } catch(e) {} }
                                if (tbRef) { try { tbRef.typingModeSelected() } catch(e) {} }
                                if (Qt.inputMethod.visible) {
                                    try { Qt.inputMethod.hide() } catch(ek) {}
                                }
                                if (ctrlRef) {
                                    try {
                                        ctrlRef.beginInputMethodTransaction()
                                        ctrlRef.replaceComposeText(bodyToInsert, true)
                                        ctrlRef.commitInputMethod()
                                        ctrlRef.clearComposeRange()
                                        ctrlRef.endInputMethodTransaction()
                                    } catch(e) { console.warn("INSERT: " + e) }
                                }
                            }
                            gp.closeClicked()
                        }
                    }
                }
                Rectangle { id: gpDiv; anchors.horizontalCenter: parent.horizontalCenter; anchors.verticalCenter: parent.verticalCenter; width: 1; height: 40; color: "#444444" }
                Item {
                    anchors.left: gpDiv.right; anchors.right: parent.right; anchors.top: parent.top; anchors.bottom: parent.bottom
                    Text { anchors.centerIn: parent; color: "#000000"; font.pixelSize: 28; text: "取消" }
                    MouseArea { anchors.fill: parent; onClicked: gp.cancelClicked() }
                }
            }
        }
    }
}
