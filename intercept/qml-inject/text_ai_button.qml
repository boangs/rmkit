// text_ai_button.qml — 打字文本选择菜单 AI 按钮 (ai_text_button.qmd 的运行时注入版)
// 由 qml_inject_impl.so 在发现 TextSelectionMenu 的 SelectionContextualMenu 时创建。
// 创建时必须赋值:
//   tools    — SelectionContextualMenu 实例 (文本选择工具栏)
//   menuRoot — 用于爬 parent 链找 controller / tileManager 的起点
// qmd 版把 aiMenuComponent 塞进 root.sourceComponent; 运行时版改成在顶层 host
// 叠加二级菜单 + 预览面板 (复用 glyph 的 host-overlay 模式), 不动 sourceComponent。
import QtQuick

Item {
    id: aiTextButton
    objectName: "rmkitTextAiButton"

    property var tools: null
    property var menuRoot: null

    // 只在"选区态"显示 (选中文字), 光标态隐藏 —— 对齐 qmd 版 visible: controller.hasTextSelection。
    // menuRoot 由 C++ 在 create() 后 setProperty, 故爬链在 onMenuRootChanged 里做 (onCompleted 时还是 null)。
    property var _ctrl: null
    onMenuRootChanged: {
        if (!menuRoot) return
        var p = menuRoot
        for (var i = 0; i < 25; i++) {
            if (!p) break
            if (p.controller) { _ctrl = p.controller; break }
            p = p.parent
        }
    }
    visible: !!(_ctrl && (_ctrl.hasTextSelection || _ctrl.isTextSelected))

    // 尺寸对齐原生图标按钮 (~80x80 正方形; 工具栏高 80, 原生按钮可见宽度也 ~80,
    // 不是组件声明的 114 —— 那是隐藏态默认值, 用它会显得是个突兀的长方块)
    width: 80
    height: 80

    // 白底实底: 选区菜单浮在文档页面上, 无背景会透出页面墨迹显得像黑块 (原生按钮也是白底)。
    // 不要黑边框 (用户反馈边框太重), 白底 + 圆角即可, 按下给浅灰反馈。
    Rectangle {
        anchors.fill: parent
        color: btnMa.pressed ? "#dddddd" : "white"
        radius: 8
    }
    // "AI" 文字图标: 图标资源在此 e-ink Qt 上无法加载, 用粗体文字模拟原生图标按钮
    Text {
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
            if (!aiTextButton.tools || !aiTextButton.menuRoot) return
            var host = aiTextButton.Window.window.contentItem
            var btnPos = aiTextButton.mapToItem(host, 0, 0)
            aiTextButton.tools.visible = false
            aiMenuComp.createObject(host, {
                selX: btnPos.x,
                selY: btnPos.y + aiTextButton.height / 2,
                tools: aiTextButton.tools,
                menuRoot: aiTextButton.menuRoot
            })
        }
    }

    // ─── 二级菜单: 润色 / 翻译 / 总结 / 回答 ───
    Component {
        id: aiMenuComp
        Rectangle {
            id: aiMenu
            property real selX: 0
            property real selY: 0
            property var tools: null
            property var menuRoot: null
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
                            // 箭头写法 (Qt6 弃用隐式 mouse 注入) + 裸调 _aiRun (不加 aiMenu. 前缀,
                            // 运行时 createObject 的组件里 id 限定调用可能解析失败)
                            onClicked: (mouse) => {
                                // 直接写文件确认点击触发 (不依赖任何函数解析)
                                try {
                                    var dx = new XMLHttpRequest()
                                    dx.open("PUT", "file:///tmp/textai.log", false)
                                    dx.send("delegate clicked index=" + index + " modelData=" + modelData + "\n")
                                } catch (e) {}
                                var ps = [
                                    "请润色以下文字，保持原意让表达更自然流畅。直接输出润色后的文字，不要任何解释、前缀、后缀、引号、Markdown。",
                                    "以下文字如果是中文请翻译为英文，如果是其他语言请翻译为中文。直接输出译文，不要任何解释、前缀、后缀、引号、Markdown。",
                                    "请用简洁的中文总结以下文字的核心内容。直接输出总结，不要任何解释、前缀、后缀、引号、Markdown。",
                                    "请用中文回答以下问题。不要使用 Markdown 标记（不要使用 **加粗**、## 标题、- 项目符号）"
                                ]
                                _aiRun(ps[index], modelData)
                            }
                        }
                    }
                }
            }

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

            // 文件诊断: 绕过 journal 限流 (librarian 每 200ms 刷屏会丢弃 console.warn)
            function _writeLog(s) {
                try {
                    var x = new XMLHttpRequest()
                    x.open("PUT", "file:///tmp/textai.log", false)
                    x.send(s)
                } catch (e) {}
            }

            function _aiRun(promptPrefix, actionLabel) {
                // 爬 menuRoot parent 链找 controller / tileManager
                var ctrlRef = null, tmRef = null
                var p = menuRoot
                for (var i = 0; i < 25; i++) {
                    if (!p) break
                    if (!ctrlRef && p.controller) ctrlRef = p.controller
                    if (!tmRef && p.tileManager) tmRef = p.tileManager
                    p = p.parent
                }
                if (!ctrlRef) { aiMenu.destroy(); return }
                if (!ctrlRef.hasTextSelection) { aiMenu.destroy(); return }

                var host = aiMenu.Window.window.contentItem
                // 光标/选区 → host 坐标, 用于面板定位
                var topHost = Qt.point(0, 0), bottomHost = Qt.point(0, 40)
                try {
                    var sr = aiMenu.tools.selectionRect
                    if (sr && aiMenu.menuRoot) {
                        topHost = aiMenu.menuRoot.mapToItem(host, sr.x, sr.y)
                        bottomHost = aiMenu.menuRoot.mapToItem(host, sr.x, sr.y + sr.height)
                    }
                } catch (ec) {}

                var fmt = _formatParagraphs
                // ── 对齐 glyph: 点击立即建面板 (不等异步剪贴板), 面板必现 ──
                var panel = aiPanelComp.createObject(host, {
                    cursorTopY: topHost.y,
                    cursorBottomY: bottomHost.y,
                    isStreaming: true,
                    actionLabel: actionLabel,
                    bodyText: "",
                    ctrl: ctrlRef,
                    tileManager: tmRef,
                    fmtFn: fmt
                })
                if (!panel) { aiMenu.destroy(); return }

                // 复制选中文字 (Clipboard 写入异步, 200ms 后再读)
                ctrlRef.copySelectedText()
                ctrlRef.clearSelectedText()
                if (Qt.inputMethod.visible) {
                    try { Qt.inputMethod.hide() } catch (ek) {}
                }

                var capturedPrefix = promptPrefix
                // 200ms 后读剪贴板 + 发 XHR。面板已显示; 读空则在面板上提示 (兼作诊断)。
                var clipTimer = Qt.createQmlObject(
                    'import QtQuick; Timer { interval: 200; running: true; repeat: false }', host)
                clipTimer.triggered.connect(function() {
                    clipTimer.destroy()
                    var selectedText = ""
                    var clipInfo = "typeof=" + (typeof Clipboard)
                    try {
                        if (typeof Clipboard !== "undefined" && Clipboard.textString) {
                            selectedText = "" + (Clipboard.textString() || "")
                            clipInfo += " len=" + selectedText.length
                        } else {
                            clipInfo += " textString 不可用"
                        }
                    } catch (ets) { clipInfo += " err=" + ets }
                    if (selectedText.length === 0) {
                        panel.bodyText = "[剪贴板为空] " + clipInfo
                        panel.isStreaming = false
                        return
                    }
                    var fullText = ""
                    var xhr = new XMLHttpRequest()
                    panel._xhrRef = xhr
                    xhr.open("POST", "http://127.0.0.1:8080/ai-page-chat")
                    xhr.setRequestHeader("Content-Type", "application/json")
                    var lastLen = 0, tail = ""
                    xhr.onreadystatechange = function() {
                        var rs = xhr.readyState
                        if (rs !== XMLHttpRequest.LOADING && rs !== XMLHttpRequest.DONE) return
                        var newPart = xhr.responseText.substring(lastLen)
                        lastLen = xhr.responseText.length
                        var lines = (tail + newPart).split("\n")
                        if (rs === XMLHttpRequest.DONE) { tail = "" } else { tail = lines.pop() }
                        for (var i = 0; i < lines.length; i++) {
                            var line = lines[i].replace(/\r$/, "")
                            if (!line) continue
                            var d; try { d = JSON.parse(line) } catch(e) { continue }
                            if (d.meta) continue
                            if (typeof d.text === "string" && d.text.length > 0) {
                                fullText += d.text
                                panel.bodyText = fmt(fullText)
                                panel.rawText = fullText
                            } else if (d.error) {
                                panel.bodyText = "[错误] " + d.error
                            }
                        }
                        if (rs === XMLHttpRequest.DONE) {
                            if (xhr.status !== 200 && fullText.length === 0) {
                                panel.bodyText = "[HTTP " + xhr.status + "] " + xhr.responseText
                            }
                            panel.isStreaming = false
                        }
                    }
                    xhr.onerror = function() {
                        if (panel.bodyText.length === 0) panel.bodyText = "[网络错误] upload-server 未运行？请点取消"
                        panel.isStreaming = false
                    }
                    xhr.send(JSON.stringify({ prompt: capturedPrefix + "\n\n" + selectedText }))
                })
                aiMenu.destroy()
            }
        }
    }

    // ─── 预览面板 ───
    Component {
        id: aiPanelComp
        Rectangle {
            id: gp
            property string bodyText: ""
            property string rawText: ""       // 未格式化原文, 插入时用格式化版
            property string actionLabel: ""
            property bool isStreaming: true
            property real cursorTopY: 0
            property real cursorBottomY: 0
            property var ctrl: null
            property var tileManager: null
            property var fmtFn: null
            property var _xhrRef: null
            signal closeClicked()
            signal cancelClicked()

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

            Rectangle {
                id: gpBtns
                anchors.bottom: parent.bottom; anchors.horizontalCenter: parent.horizontalCenter
                anchors.bottomMargin: 16; width: 460; height: 56; radius: 28; color: "#ffffff"; border.width: 0
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
                            var raw = gp.rawText
                            if (!raw || raw.length === 0) { gp.closeClicked(); return }
                            var formatted = gp.fmtFn ? gp.fmtFn(raw) : raw
                            if (gp.ctrl) {
                                try {
                                    gp.ctrl.beginInputMethodTransaction()
                                    gp.ctrl.replaceComposeText("\n\n" + formatted, true)
                                    gp.ctrl.commitInputMethod()
                                    gp.ctrl.clearComposeRange()
                                    gp.ctrl.endInputMethodTransaction()
                                    if (gp.tileManager && gp.tileManager.scrollToMakeScenePositionVisible) {
                                        gp.tileManager.scrollToMakeScenePositionVisible(gp.ctrl.textCursorPosition)
                                    }
                                } catch (e) { console.warn("[textai] insert err " + e) }
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
