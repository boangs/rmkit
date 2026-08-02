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

    // ── 横屏适配 ───────────────────────────────────────────────────
    // xochitl 横屏不转窗口, 而是把各原生窗口容器各自旋转 90° 并位移 (根节点仍是
    // 竖屏 954x1696)。我们把菜单/面板挂在未旋转的根节点上, 所以横屏时它们仍是
    // 竖屏姿态 (实测: 界面横过来了、二级菜单还竖着)。
    // 对策: 检测到横屏就给挂上去的对象套同一套变换 —— 宽高互换 + 绕中心转 90°。
    // ── 浮层宿主 ───────────────────────────────────────────────────
    // 关键: 菜单/面板必须挂在**和原生工具栏同一个坐标系**的容器里。
    // 以前挂在窗口 contentItem (未旋转的物理根节点) 上, 而按钮处在 xochitl
    // 横屏时旋转过的容器内 —— 两个坐标系不同, 于是横屏下菜单跑到屏幕角落
    // (用户实测截图: 方向对了但位置在左上角, 选区在中间)。
    // 从工具栏往上找第一个"足够大"的祖先当宿主, 竖屏横屏都自动正确, 不需要
    // 任何旋转补偿。
    // 浮层宿主 = 工具栏自身的父容器。
    // 关键: 把菜单/面板放成 AI 按钮的**兄弟节点**, 它就自动继承完全相同的
    // 变换链 —— 横屏竖屏都天然贴着按钮, 不需要任何坐标换算或旋转补偿。
    // 前面几次尝试都栽在换算上: 挂 contentItem 方向对但位置错 (实测按钮
    // 映射坐标 801,392 与视觉位置对不上), 挂大祖先容器则整个转 90 度。
    // QML 默认不裁剪子项, 菜单超出父容器边界仍会完整显示。
    function _overlayHost() {
        return (tools && tools.parent) ? tools.parent : Window.window.contentItem
    }



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
            var host = aiGlyphButton._overlayHost()
            // 宿主是按钮的父容器, 局部坐标即可, 无需跨坐标系映射
            var btnPos = aiGlyphButton.mapToItem(host, 0, 0)
            aiGlyphButton.tools.visible = false
            var m = glyphMenuComp.createObject(host, {
                selX: btnPos.x,
                selY: btnPos.y + aiGlyphButton.height / 2,
                tools: aiGlyphButton.tools,
                selectionRoot: aiGlyphButton.selectionRoot,
                srcBtn: aiGlyphButton
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
            property var srcBtn: null      // 注入按钮引用, 供横屏变换调用
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
                                var host = glyphMenu.srcBtn ? glyphMenu.srcBtn._overlayHost() : glyphMenu.Window.window.contentItem
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
            // 面板挂在工具栏容器里 (方向因此天然正确), 但那容器只有 526x84,
            // 按 parent 尺寸算面板就成了一条看不见的缝。真正需要的是**屏幕可视
            // 区域在本坐标系下的矩形**: 把窗口四角映射进来取包围盒, 无论这层
            // 坐标系有没有旋转都成立 (横屏下自然得到 1696x954)。
            readonly property rect scrRect: {
                var win = gp.Window.window
                if (!win || !parent) return Qt.rect(0, 0, 1404, 1872)
                // ★ 建立对**祖先链几何**的绑定依赖。横竖屏切换时窗口自身尺寸恒为
                // 954x1696 (实测), 只有中间那层旋转容器的宽高/旋转角会变。这里逐层
                // 读一遍它们的几何属性, QML 就会把这些属性记为本绑定的依赖 ——
                // 旋转时自动重算尺寸和位置, 而不是像之前那样画死在创建时的朝向。
                var dep = 0, pa = gp.parent
                for (var di = 0; di < 25 && pa; di++) {
                    dep += pa.width + pa.height + pa.rotation + pa.x + pa.y
                    pa = pa.parent
                }
                var pts = [parent.mapFromItem(null, 0, 0),
                           parent.mapFromItem(null, win.width, 0),
                           parent.mapFromItem(null, 0, win.height),
                           parent.mapFromItem(null, win.width, win.height)]
                var x0 = pts[0].x, x1 = pts[0].x, y0 = pts[0].y, y1 = pts[0].y
                for (var i = 1; i < 4; i++) {
                    x0 = Math.min(x0, pts[i].x); x1 = Math.max(x1, pts[i].x)
                    y0 = Math.min(y0, pts[i].y); y1 = Math.max(y1, pts[i].y)
                }
                return Qt.rect(x0, y0, x1 - x0, y1 - y0)
            }
            // 比例要分朝向: 0.82/0.26 是按竖屏 (954x1696) 调的, 得到 782x441 偏方;
            // 横屏 (1696x954) 套同一比例会拉成 1391x248 的长条 —— 太宽且正文只剩
            // 一行。横屏改用 0.60/0.44, 让两种朝向下面板的实际形状接近。
            readonly property bool wideScreen: scrRect.width > scrRect.height
            width: Math.round(scrRect.width * (wideScreen ? 0.60 : 0.82))
            height: Math.round(scrRect.height * (wideScreen ? 0.44 : 0.26))
            readonly property real bodyAvailableH: Math.max(50, height - 77 - 72)
            // 一律相对 scrRect 定位: 水平居中, 垂直优先贴选区下方, 放不下翻到上方
            x: Math.round(scrRect.x + (scrRect.width - width) / 2)
            y: {
                var top = scrRect.y, bot = scrRect.y + scrRect.height
                var below = cursorBottomY + 24
                if (below + height <= bot - 24) return Math.round(below)
                var above = cursorTopY - 24 - height
                if (above >= top + 24) return Math.round(above)
                return Math.round(top + 24)
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
