// pinyin_ime.qml — 拼音候选框 (pinyin_interceptor.qmd 的运行时注入版, v61-runtime)
// 由 qml_inject_impl.so 在启动后创建, parent = 主窗口 contentItem (等价于原 qmd
// 注入点 MainView.qml 的 FocusScope#rootItem, 都是全屏根节点)。
//
// 与 qmd 版的差异:
// A) Timer 替换 (运行时注入组件里 Timer 不触发, 见 memory feedback_runtime_qml_no_timer):
//    1. charPoller (500ms, long-poll 链兜底) → C++ 每 250ms 写 imeTick 属性驱动
//    2. textWatcher (80ms 轮询 TextInput.text) → Connections onTextChanged 事件驱动
//    3. candidatesDebounce (200ms 防抖)      → imeTick 计数 (_debounceTicks)
// B) e-ink 快刷: 中文输入时整屏走 Animation 波形 (fastZone), 消除打字卡顿+闪屏,
//    汉字上屏更快更清晰 (见下方 _markFastRefresh / fastZone 注释)。
import QtQuick

Item {
    id: pinyinIME
    objectName: "rmkitPinyinIME"
    anchors.fill: parent
    z: 99999

    property string pinyinBuffer: ""
    property var candidates: []
    property int pageIdx: 0
    readonly property int pageSize: 5
    readonly property int pageCount: Math.max(1, Math.ceil(candidates.length / pageSize))
    property bool showBar: false
    property var focusTarget: null
    property bool intercepting: false
    property bool useDirectCommit: false
    property bool active: false
    property bool isChineseMode: false
    property int keyboardY: 0
    property int keyboardHeight: 0
    // 零宽空格占位符状态：anchorIdx 是占位符所在位置
    property bool hasAnchor: false
    property int anchorIdx: 0
    property bool _kbdDumped: false
    // long-poll 链状态: true 时表示 /pop-all-chars-blocking xhr 在挂,
    // 阻止 fallback 重复发起。响应到达后 chain 立即重发。
    property bool _charXhrActive: false
    // 英文标点 → 中文标点映射 (chinese_mode 启用时生效)。
    // ,. 在 buffer 非空时作翻页, buffer 空时按本表转换。其他标点直接转。
    readonly property var _punctMap: ({
        ",": "，",
        ".": "。",
        "?": "？",
        "!": "！",
        ":": "：",
        ";": "；",
        "(": "（",
        ")": "）",
        "<": "《",
        ">": "》",
        "\\": "、"
    })

    // ── Timer 替代机制 ──────────────────────────────────────────────
    // C++ (qml_inject_impl) 每 250ms 自增写入 imeTick。
    property int imeTick: 0
    // 候选防抖计数: >0 表示等待中, 每 tick 减 1, 到 0 触发查询 (原 200ms debounce)
    property int _debounceTicks: 0
    // text 模式上一次的文本快照 (原 textWatcher.lastText)
    property string _lastText: ""
    onImeTickChanged: {
        // 原 charPoller Timer (500ms) 职责: long-poll 链兜底重启
        // (_pollChars 内部有 _charXhrActive / intercepting / mode 守卫, 幂等)
        if (active && isChineseMode && useDirectCommit) _pollChars()
        // 原 candidatesDebounce Timer (200ms) 职责
        if (_debounceTicks > 0) {
            _debounceTicks--
            if (_debounceTicks === 0) _doFetchCandidates()
        }
    }

    function setMode(key, val) {
        var xhr = new XMLHttpRequest()
        xhr.open("GET", "http://127.0.0.1:19876/set-mode?" + key + "=" + (val ? "1" : "0"))
        xhr.send()
    }

    // ── e-ink 快速刷新 (打字流畅 + 上屏快的关键) ─────────────────────
    // xochitl 注册了 xofm.libs.epaper.ScreenModeItem (来自原厂 libqsgepaper.so),
    // 它给自己覆盖的矩形区域指定墨水屏刷新波形:
    //   Pen(笔迹最快) / Mono(纯黑白) / Animation(快, 本项目所用) / Content(灰阶全刷, 慢且闪) / Sleep
    // 不做标记时走默认 Content —— 每次更新灰阶重刷, 又慢又闪, 就是"打字卡"的根源。
    // Animation 波形快且不闪, 汉字上屏也不再卡在全刷上。(直接 dlopen libqsgepaper 拿
    // EPFramebuffer 也能做到同样效果; 我们跑在 xochitl 引擎内直接用 QML 类型更省事)
    //
    // 关键教训: 屏幕模式图 (EPScreenModeMap) 每变一次就整屏重新合成一次, 所以要紧的
    // 不是"标记的区域多小", 而是"几何变了多少次"。曾试过只标候选框那一小条, 反而更糟——
    // 候选框随每个词伸缩/显隐, 模式区进出模式图, 每次都触发一次整屏 content 全刷。
    // 最终方案: 整屏常驻 Animation (见 fastZone), 会话内几何零变化 → 零抖动。
    //
    // 动态创建 + try/catch: 固件若无此类型则静默降级, 不能让候选框本身加载失败。
    function _markFastRefresh(target) {
        if (!target) return null
        try {
            return Qt.createQmlObject(
                'import QtQuick; import xofm.libs.epaper; ' +
                'ScreenModeItem { anchors.fill: parent; mode: ScreenModeItem.Animation }',
                target, "rmkitFastRefresh")
        } catch (e) {
            console.warn("XOVI-PINYIN: ScreenModeItem 不可用, 沿用默认刷新: " + e)
            return null
        }
    }


    // 物理键盘回落：虚拟键盘不 visible 时，若当前焦点是 SceneView
    // （记事本编辑器：无 text 属性、有 controller），且 locale 为 zh，
    // 就保持 direct mode 让字母走 charPoller。返回是否成功进入。
    function enterDirectModeIfApplicable() {
        var win = pinyinIME.Window.window
        if (!win) return false
        var item = win.activeFocusItem
        if (!item) return false
        var locale = Qt.inputMethod.locale
        var lang = locale ? locale.name : ""
        var isChinese = lang.indexOf("zh") === 0
        if (!isChinese) return false
        if (item.text !== undefined) return false     // TextInput，走 text mode 由 onVisibleChanged 管
        if (!item.controller) return false            // 不是 SceneView
        pinyinIME.focusTarget = item
        pinyinIME.useDirectCommit = true
        pinyinIME.active = true
        pinyinIME.isChineseMode = true
        ctrlConn.target = item.controller
        pinyinIME.setMode("chinese", true)
        // 物理键盘没有虚拟键盘 overlay → 候选栏必须 detach 回 pinyinIME，
        // 否则之前 nudgeToolbar 把它 reparent 到 overlay (width=0) 会看不见。
        pinyinIME.detachCandidateBar()
        // Timer 版靠 charPoller running 条件自动开链; 运行时版显式拉起
        Qt.callLater(pinyinIME._pollChars)
        console.warn("XOVI-PINYIN: enter direct mode (physical kb)")
        return true
    }

    // 光标在 pinyinIME-local 坐标（供浮动候选栏使用）
    // controller.textCursorPosition 是文档绝对坐标（scene 坐标），随滚动持续增长；
    // viewport.tileManager.sceneToView(...) 是 Qt 内部的 scene→view 变换，自动
    // 应用当前滚动+缩放，输出的 view 坐标和 SceneView item 坐标完全一致。
    property real cursorLocalX: -1
    property real cursorLocalY: -1
    property real cursorLineHeight: 64

    function refreshCursorPosition() {
        if (!useDirectCommit) return
        var it = focusTarget
        var c = it ? it.controller : null
        if (!c) return
        var vp = it.viewport
        var tm = vp ? vp.tileManager : null
        var tcp = c.textCursorPosition
        var itemX, itemY
        if (tm && typeof tm.sceneToView === "function") {
            var pv = tm.sceneToView(Qt.point(tcp.x, tcp.y))
            itemX = pv.x
            itemY = pv.y
        } else {
            // fallback：tileManager 不可用时用 defaultCenter；不会跟随滚动
            var center = it.defaultCenter
            var scale = it.defaultScale || 1
            if (!center || it.width <= 0) return
            itemX = it.width / 2 + (tcp.x - center.x) * scale
            itemY = it.height / 2 + (tcp.y - center.y) * scale
        }
        var win = it.mapToItem(null, itemX, itemY)
        var loc = pinyinIME.mapFromItem(null, win.x, win.y)
        pinyinIME.cursorLocalX = loc.x
        pinyinIME.cursorLocalY = loc.y
        pinyinIME.cursorLineHeight = c.textLineHeight > 0 ? c.textLineHeight : 64
    }

    // 把候选栏从虚拟键盘 overlay 里拿回来，放在浮动位置（光标附近/底部 fallback）。
    // 只有之前 nudgeToolbar reparent 过才需要；幂等。
    function detachCandidateBar() {
        if (candidateBar.parent === pinyinIME) return
        console.warn("XOVI-PINYIN: detach candidateBar to pinyinIME (floating)")
        candidateBar.parent = pinyinIME
        candidateBar.x = Qt.binding(function() { return pinyinIME.floatingBarX })
        candidateBar.y = Qt.binding(function() { return pinyinIME.floatingBarY })
        candidateBar.width = Qt.binding(function() { return pinyinIME.floatingBarWidth })
    }

    // 浮动候选栏位置（物理键盘下用）：优先跟光标，取不到坐标时屏幕底部 fallback
    readonly property int floatingBarWidth: parent ? parent.width : 0
    readonly property int floatingBarX: {
        if (cursorLocalX < 0) return 0
        var parentW = parent ? parent.width : 1404
        // 让候选栏居中对齐光标，但不超出屏幕
        var x = cursorLocalX - floatingBarWidth / 2
        if (x < 0) x = 0
        if (x + floatingBarWidth > parentW) x = parentW - floatingBarWidth
        return x
    }
    readonly property int floatingBarY: {
        if (cursorLocalY < 0) {
            // fallback：屏幕底部偏上 40px
            return (parent ? parent.height - candidateBar.height - 40 : 0)
        }
        // RM2 记事本是 SceneView 旋转 90°；scene.textLineHeight 不对应 window.y，
        // 所以不能加行高。候选栏放在光标 y 下方 20px；若超出底部则改为上方。
        var parentH = parent ? parent.height : 1872
        var below = cursorLocalY + 20
        if (below + candidateBar.height <= parentH - 20) return below
        return Math.max(0, cursorLocalY - candidateBar.height - 10)
    }

    // ── 零宽空格占位符管理 ───────────────────────────────────────────
    // 插入 U+200B 作为退格吸收器，使退格不会误删正文
    function placeAnchor(ctrl) {
        if (hasAnchor) return
        intercepting = true
        anchorIdx = ctrl.textCursorIndex
        ctrl.beginInputMethodTransaction()
        ctrl.replaceComposeText("\u200B", true)
        ctrl.commitInputMethod()
        ctrl.clearComposeRange()
        ctrl.endInputMethodTransaction()
        Qt.callLater(function() {
            ctrl.setCursorIndex(anchorIdx + 1)
            hasAnchor = true
            pinyinIME.intercepting = false
        })
    }

    // 重新放置占位符（退格后 buffer 还有内容时调用）
    function replaceAnchor(ctrl) {
        hasAnchor = false
        placeAnchor(ctrl)
    }

    // 删除占位符（选词前调用）
    function removeAnchor(ctrl) {
        if (!hasAnchor) return
        intercepting = true
        ctrl.deleteText(1, 0)
        hasAnchor = false
        intercepting = false
    }

    // ── 字符队列 ────────────────────────────────────────────────────
    // PPM 虚拟键盘回车：既不走 setCommitString 也不走 processKeyEvent
    // （reMarkable 的记事本键盘 Enter 按钮直接调 SceneController 内部 API）。
    // 用全局 Shortcut 在 QML 层拦回车，仅当 direct mode + buffer 非空时吞；
    // enabled=false 时回车正常插换行。
    Shortcut {
        sequences: [StandardKey.InsertLineSeparator, "Return", "Enter"]
        context: Qt.ApplicationShortcut
        enabled: pinyinIME.useDirectCommit && pinyinIME.pinyinBuffer !== ""
        onActivated: {
            console.warn("XOVI-PINYIN: Shortcut Enter captured, buffer=" + pinyinIME.pinyinBuffer)
            var ctrl = pinyinIME.focusTarget ? pinyinIME.focusTarget.controller : null
            if (ctrl) pinyinIME.commitBufferRaw(ctrl)
        }
    }

    // long-poll 字符处理 — 调用 ime-server /pop-all-chars-blocking
    // 该 endpoint 通过 ime_hook 的 unix socket notify 实现 0-polling 唤醒,
    // 字符到达立刻返回 (~5ms)。响应处理完后 chain 递归立刻发下一次 xhr,
    // 形成持续 long-poll 链。imeTick (250ms) 仅作 fallback (网络
    // 错误 / 服务重启时把链拉回来)。
    function _pollChars() {
        if (pinyinIME._charXhrActive) return
        if (pinyinIME.intercepting) return
        if (!pinyinIME.active || !pinyinIME.useDirectCommit || !pinyinIME.isChineseMode) return
        var ctrl = pinyinIME.focusTarget ? pinyinIME.focusTarget.controller : null
        if (!ctrl) return

        pinyinIME._charXhrActive = true
        var xhr = new XMLHttpRequest()
        xhr.timeout = 6000  // 略大于 ime-server blocking 5s timeout
        xhr.onreadystatechange = function() {
            if (xhr.readyState !== 4) return
            pinyinIME._charXhrActive = false
            var chars = (xhr.status === 200) ? xhr.responseText : ""
            if (chars) {
                pinyinIME.refreshCursorPosition()
                pinyinIME.intercepting = true
                var changed = false
                for (var j = 0; j < chars.length; j++) {
                    var ch = chars[j]
                    if (ch === "\b") {
                        if (pinyinIME.pinyinBuffer.length > 0) {
                            pinyinIME.pinyinBuffer = pinyinIME.pinyinBuffer.slice(0, -1)
                            changed = true
                            if (pinyinIME.pinyinBuffer === "") {
                                pinyinIME.hasAnchor = false
                                pinyinIME.clearState()
                                changed = false
                            }
                        }
                    } else if (/[a-zA-Z]/.test(ch)) {
                        var wasEmpty = pinyinIME.pinyinBuffer === ""
                        pinyinIME.pinyinBuffer += ch
                        changed = true
                        if (wasEmpty) {
                            pinyinIME.setMode("pinyin_active", true)
                            pinyinIME.placeAnchor(ctrl)
                        }
                    } else if (ch === " " && pinyinIME.pinyinBuffer !== "") {
                        pinyinIME.commitFirst(ctrl)
                        changed = false
                    } else if ((ch === "\r" || ch === "\n") && pinyinIME.pinyinBuffer !== "") {
                        pinyinIME.commitBufferRaw(ctrl)
                        changed = false
                    } else if (/[1-9]/.test(ch) && pinyinIME.pinyinBuffer !== "") {
                        // 数字 1-9 直接选当前页第 N 个候选
                        var pageStart = pinyinIME.pageIdx * pinyinIME.pageSize
                        var selIdx = pageStart + (parseInt(ch) - 1)
                        if (selIdx < pinyinIME.candidates.length) {
                            pinyinIME.selectCandidate(selIdx)
                        }
                        changed = false
                    } else if (ch === "," && pinyinIME.pinyinBuffer !== "") {
                        // buffer 非空: , 上一页
                        if (pinyinIME.pageIdx > 0) pinyinIME.pageIdx -= 1
                        changed = false
                    } else if (ch === "." && pinyinIME.pinyinBuffer !== "") {
                        // buffer 非空: . 下一页
                        if (pinyinIME.pageIdx < pinyinIME.pageCount - 1) pinyinIME.pageIdx += 1
                        changed = false
                    } else if (pinyinIME._punctMap[ch] !== undefined) {
                        // 中文模式 + 标点: buffer 非空时 commit 第一候选+插中文标点,
                        // buffer 空时直接插中文标点。
                        var cnP = pinyinIME._punctMap[ch]
                        if (pinyinIME.pinyinBuffer !== "") {
                            var extra2 = cnP
                            pinyinIME.commitFirst(ctrl)
                            Qt.callLater(function() { pinyinIME.insertToDoc(ctrl, extra2) })
                            changed = false
                        } else {
                            pinyinIME.insertToDoc(ctrl, cnP)
                        }
                    } else if (pinyinIME.pinyinBuffer !== "") {
                        var extra = ch
                        pinyinIME.commitFirst(ctrl)
                        Qt.callLater(function() { pinyinIME.insertToDoc(ctrl, extra) })
                        changed = false
                    } else {
                        pinyinIME.insertToDoc(ctrl, ch)
                    }
                }
                pinyinIME.intercepting = false
                if (changed && pinyinIME.pinyinBuffer !== "") pinyinIME.fetchCandidates()
            }
            // chain — Qt.callLater 避免栈深递归 + 让 QML 事件循环处理一轮再发
            Qt.callLater(pinyinIME._pollChars)
        }
        xhr.open("GET", "http://127.0.0.1:19876/pop-all-chars-blocking")
        xhr.send()
    }

    // (原 charPoller Timer 位置 — 已由 onImeTickChanged 的 _pollChars 兜底取代)

    // ── SceneView controller：检测退格（U+200B 占位符被删） ──────────
    Connections {
        id: ctrlConn
        target: null

        function onTextCursorIndexChanged() {
            if (pinyinIME.intercepting || !pinyinIME.isChineseMode || !pinyinIME.useDirectCommit) return
            if (!pinyinIME.hasAnchor || pinyinIME.pinyinBuffer === "") return
            var ctrl = pinyinIME.focusTarget ? pinyinIME.focusTarget.controller : null
            if (!ctrl) return
            var newIdx = ctrl.textCursorIndex

            // 光标退到占位符位置或更前 → 占位符被退格键删掉了
            if (newIdx <= pinyinIME.anchorIdx) {
                pinyinIME.hasAnchor = false
                pinyinIME.pinyinBuffer = pinyinIME.pinyinBuffer.slice(0, -1)
                if (pinyinIME.pinyinBuffer === "") {
                    pinyinIME.clearState()
                } else {
                    // 重新放置占位符供下次退格使用
                    pinyinIME.anchorIdx = newIdx
                    pinyinIME.replaceAnchor(ctrl)
                    pinyinIME.fetchCandidates()
                }
            } else if (newIdx > pinyinIME.anchorIdx + 1) {
                // PPM 虚拟 Enter 键：既不走 setCommitString 也不走 processKeyEvent，
                // 直接让 SceneView 插入一个换行（cursor 从 anchorIdx+1 前移到 anchorIdx+2）。
                // 我们监控不到 Enter 事件本身，但能监控到它的副作用 —— cursor 前移。
                // 触发到这里说明 Enter 按下了，把 buffer 以英文上屏（保留换行作为副作用）。
                var diff = newIdx - pinyinIME.anchorIdx
                console.warn("XOVI-PINYIN: forward (Enter) detected, diff=" + diff + " buffer=" + pinyinIME.pinyinBuffer)
                pinyinIME.commitBufferAfterEnter(ctrl, newIdx)
            }
        }
    }

    Connections {
        target: Qt.inputMethod
        function onKeyboardRectangleChanged() {
            var kr = Qt.inputMethod.keyboardRectangle
            if (kr.height > 100) {
                pinyinIME.keyboardY = kr.y
                pinyinIME.keyboardHeight = kr.height
            }
        }
        function onLocaleChanged() {
            var locale = Qt.inputMethod.locale
            var lang = locale ? locale.name : ""
            var isChinese = lang.indexOf("zh") === 0
            console.warn("XOVI-PINYIN: localeChanged lang=" + lang + " chinese=" + isChinese)
            pinyinIME.isChineseMode = isChinese
            if (!isChinese) {
                pinyinIME.setMode("chinese", false)
                pinyinIME.clearState()
                if (pinyinIME.useDirectCommit) pinyinIME.active = false
                return
            }
            // 英文→中文：重新判断 mode + attach 候选栏。
            // 不做这一步,candidateBar 的 parent 还在屏幕底部,会被虚拟键盘遮挡,
            // 用户看到的现象就是"字母按下没反应",其实候选栏在但看不见。
            pinyinIME.activateForCurrentFocus()
        }
        function onVisibleChanged() {
            if (Qt.inputMethod.visible) {
                var kr = Qt.inputMethod.keyboardRectangle
                if (kr.height > 100) {
                    pinyinIME.keyboardY = kr.y
                    pinyinIME.keyboardHeight = kr.height
                }
                var locale = Qt.inputMethod.locale
                var lang = locale ? locale.name : ""
                var isChinese = lang.indexOf("zh") === 0
                pinyinIME.isChineseMode = isChinese
                console.warn("XOVI-PINYIN: kb visible locale=" + lang)
                if (!isChinese) {
                    pinyinIME.setMode("chinese", false)
                    pinyinIME.active = false
                    pinyinIME.focusTarget = null
                    pinyinIME.clearState()
                    return
                }
                pinyinIME.activateForCurrentFocus()
                Qt.callLater(pinyinIME.dumpKbdOnce)
            } else {
                // 虚拟键盘隐藏：先试着切到物理键盘的 direct mode（记事本场景）
                if (pinyinIME.enterDirectModeIfApplicable()) return
                ctrlConn.target = null
                pinyinIME.active = false
                pinyinIME.focusTarget = null
                pinyinIME.useDirectCommit = false
                pinyinIME.isChineseMode = false
                pinyinIME.setMode("chinese", false)
                pinyinIME.clearState()
            }
        }
    }

    // 冷启动场景：物理键盘已接入，虚拟键盘从未 visible 过 —— 靠 focus 变化触发
    // 离场场景：direct mode 下焦点离开 SceneView（比如返回首页）要关掉候选浮窗
    Connections {
        target: pinyinIME.Window.window
        ignoreUnknownSignals: true
        function onActiveFocusItemChanged() {
            var win = pinyinIME.Window.window
            var item = win ? win.activeFocusItem : null
            if (pinyinIME.useDirectCommit) {
                // 仍是一个可写 SceneView → 保持 direct mode
                var stillEditable = item && item.text === undefined && item.controller
                if (stillEditable) return
                // 焦点走了 → 关掉候选、复位 hook 标志
                ctrlConn.target = null
                pinyinIME.active = false
                pinyinIME.focusTarget = null
                pinyinIME.useDirectCommit = false
                pinyinIME.isChineseMode = false
                pinyinIME.setMode("chinese", false)
                pinyinIME.clearState()
                console.warn("XOVI-PINYIN: leave direct mode (focus left editor)")
                return
            }
            // RM2 上 Qt.inputMethod.visible 永远为 true，不能用它过滤。
            // enterDirectModeIfApplicable 内部用 item.text !== undefined 判断，不会误触发虚拟键盘 TextInput。
            pinyinIME.enterDirectModeIfApplicable()
        }
    }

    // text 模式监听 (原 textWatcher Timer 80ms 轮询 → onTextChanged 事件驱动)。
    // 我方程序化改 text 时 intercepting=true, 信号同步触发但被首行守卫挡掉;
    // 各 commit 函数在改动后会同步更新 _lastText, 语义与轮询版一致。
    Connections {
        id: textConn
        target: (pinyinIME.active && !pinyinIME.useDirectCommit
                 && pinyinIME.focusTarget && pinyinIME.focusTarget.text !== undefined)
                ? pinyinIME.focusTarget : null
        ignoreUnknownSignals: true
        function onTextChanged() {
            if (pinyinIME.intercepting) return
            if (!pinyinIME.active || pinyinIME.useDirectCommit) return
            var t = pinyinIME.focusTarget ? pinyinIME.focusTarget.text : ""
            if (t.length > pinyinIME._lastText.length) {
                var added = t.substring(pinyinIME._lastText.length)
                pinyinIME._lastText = t
                if (pinyinIME.isChineseMode && /^[a-zA-Z]+$/.test(added)) {
                    pinyinIME.pinyinBuffer += added  // 保留原始大小写
                    pinyinIME.fetchCandidates()
                } else if (pinyinIME.pinyinBuffer !== "") {
                    pinyinIME.commitTextMode(added.length)
                }
            } else if (t.length < pinyinIME._lastText.length) {
                pinyinIME._lastText = t
                if (pinyinIME.pinyinBuffer !== "") {
                    pinyinIME.pinyinBuffer = pinyinIME.pinyinBuffer.slice(0, -1)
                    if (pinyinIME.pinyinBuffer === "") pinyinIME.clearState()
                    else pinyinIME.fetchCandidates()
                }
            }
        }
    }

    // Two-stage 候选框：物理键盘按键间隔 100-200ms, ~250ms debounce 让连续按键
    // 全程不刷候选词列表, 只在停手后一次性显示。这是消除"e-ink 反复刷"
    // 体感的核心 — 打字过程中 candidates 保持空, floatingPopup 的候选区域不渲染,
    // 只有顶部 pinyinBox 跟着按键变。(原 candidatesDebounce Timer → _debounceTicks)

    function fetchCandidates() {
        if (pinyinBuffer === "") {
            candidates = []
            showBar = false
            _debounceTicks = 0
            return
        }
        showBar = true
        // 关键 1: 不立刻清空 candidates。debounce 期间继续显示上一次的候选,
        //         新查询返回后才替换。物理键盘连按 ni→nih→niha 时, 候选框
        //         内容直接平滑过渡, 不会"满→空→满"的边界抖动。
        // 关键 2: 候选为空时 (首次输入第 1 字母), 不走 debounce, 立刻查询,
        //         避免首次显示一个"空小框"再变大。
        if (candidates.length === 0) {
            _debounceTicks = 0
            _doFetchCandidates()
        } else {
            _debounceTicks = 1  // 下一个 imeTick (≤250ms) 触发, 连按会不断重置
        }
    }

    function _doFetchCandidates() {
        if (pinyinBuffer === "") return
        var xhr = new XMLHttpRequest()
        xhr.timeout = 500
        xhr.onreadystatechange = function() {
            if (xhr.readyState === 4 && xhr.status === 200) {
                try {
                    var r = JSON.parse(xhr.responseText)
                    pinyinIME.candidates = Array.isArray(r) ? r : []
                    pinyinIME.pageIdx = 0
                } catch(e) {}
            }
        }
        // 词库按小写索引；查询统一小写化，但 buffer 仍保留原大小写供回车原样上屏
        xhr.open("GET", "http://127.0.0.1:19876/candidates?pinyin=" + encodeURIComponent(pinyinBuffer.toLowerCase()))
        xhr.send()
    }

    function insertToDoc(ctrl, text) {
        if (!text || !ctrl) return
        try {
            var startIdx = ctrl.textCursorIndex
            ctrl.beginInputMethodTransaction()
            ctrl.replaceComposeText(text, true)
            ctrl.commitInputMethod()
            ctrl.clearComposeRange()
            ctrl.endInputMethodTransaction()
            Qt.callLater(function() { ctrl.setCursorIndex(startIdx + text.length) })
        } catch(e) {
            console.warn("XOVI-PINYIN: insertToDoc FAIL: " + e)
        }
    }

    function commitDirect(ctrl, chosen) {
        intercepting = true
        // 先删占位符，再插汉字
        removeAnchor(ctrl)
        var startIdx = ctrl.textCursorIndex
        ctrl.beginInputMethodTransaction()
        ctrl.replaceComposeText(chosen, true)
        ctrl.commitInputMethod()
        ctrl.clearComposeRange()
        ctrl.endInputMethodTransaction()
        Qt.callLater(function() {
            ctrl.setCursorIndex(startIdx + chosen.length)
            pinyinIME.intercepting = false
        })
        clearState()
        console.warn("XOVI-PINYIN: committed: " + chosen)
    }

    function commitFirst(ctrl) {
        if (candidates.length > 0) commitDirect(ctrl, candidates[0])
        else clearState()
    }

    // 回车：buffer 原文（保留大小写）以英文上屏，不查候选词
    function commitBufferRaw(ctrl) {
        var raw = pinyinBuffer
        if (!raw) { clearState(); return }
        commitDirect(ctrl, raw)
    }

    // PPM 虚拟 Enter 键走不到 setCommitString / processKeyEvent，只能靠
    // onTextCursorIndexChanged 事后侦测。触发时状态：
    //   [...content][U+200B @ anchorIdx][\n @ anchorIdx+1][cursor @ anchorIdx+2]
    // 目标：把 U+200B 和 \n 都删掉，再把 buffer 以英文上屏。
    // 结构性换行可能 deleteText 删不掉（历史踩坑），若删不掉就把 buffer 插
    // 在换行后面，至少字母不丢。
    function commitBufferAfterEnter(ctrl, newIdx) {
        var raw = pinyinIME.pinyinBuffer
        if (!raw) { pinyinIME.clearState(); return }
        pinyinIME.intercepting = true
        var anchor = pinyinIME.anchorIdx
        console.warn("XOVI-PINYIN: enter-cleanup begin newIdx=" + newIdx + " anchor=" + anchor + " pos=" + ctrl.textCursorIndex)
        // 结构性换行 deleteText(1,0) 删不掉（v57 实测 before==after）。
        // 改用 selectTextRange([anchor, newIdx)) 圈住 [U+200B, \n]，
        // 然后走 IM transaction 用 replaceComposeText 替换掉整段选区。
        try {
            ctrl.selectTextRange(anchor, newIdx)
            console.warn("XOVI-PINYIN: after selectTextRange pos=" + ctrl.textCursorIndex)
        } catch(e) {
            console.warn("XOVI-PINYIN: selectTextRange FAIL: " + e)
        }
        ctrl.beginInputMethodTransaction()
        ctrl.replaceComposeText(raw, true)
        ctrl.commitInputMethod()
        ctrl.clearComposeRange()
        ctrl.endInputMethodTransaction()
        Qt.callLater(function() {
            // selectTextRange 替换完成后光标会停在选区起点，显式移到 buffer 末尾
            ctrl.setCursorIndex(anchor + raw.length)
            console.warn("XOVI-PINYIN: enter-cleanup end pos=" + ctrl.textCursorIndex)
            pinyinIME.intercepting = false
        })
        pinyinIME.hasAnchor = false
        pinyinIME.clearState()
        console.warn("XOVI-PINYIN: commit after enter: " + raw)
    }

    function selectCandidate(idx) {
        if (idx >= candidates.length) return
        var chosen = candidates[idx]
        var ctrl = focusTarget ? focusTarget.controller : null
        console.warn("XOVI-PINYIN: selectCandidate " + idx + "=" + chosen)
        if (useDirectCommit && ctrl) {
            commitDirect(ctrl, chosen)
            return
        }
        intercepting = true
        var t = focusTarget.text
        var pos = focusTarget.cursorPosition
        var before = t.substring(0, pos - pinyinBuffer.length)
        var after = t.substring(pos)
        focusTarget.text = before + chosen + after
        focusTarget.cursorPosition = before.length + chosen.length
        pinyinIME._lastText = focusTarget.text
        intercepting = false
        clearState()
    }

    function commitTextMode(extraLen) {
        if (!focusTarget) return
        if (candidates.length > 0) {
            var chosen = candidates[0]
            intercepting = true
            var t = focusTarget.text
            var pos = focusTarget.cursorPosition
            var pinyinStart = pos - pinyinBuffer.length - extraLen
            var before = t.substring(0, pinyinStart)
            var trigger = t.substring(pinyinStart + pinyinBuffer.length, pos)
            var after = t.substring(pos)
            focusTarget.text = before + chosen + trigger + after
            focusTarget.cursorPosition = before.length + chosen.length + trigger.length
            pinyinIME._lastText = focusTarget.text
            intercepting = false
            clearState()
        } else {
            pinyinIME._lastText = focusTarget.text
            clearState()
        }
    }

    function clearState() {
        pinyinBuffer = ""
        candidates = []
        pageIdx = 0
        showBar = false
        hasAnchor = false
        setMode("pinyin_active", false)
    }

    function findFormatMenu(item, depth) {
        if (!item || depth > 8) return null
        var s = item.toString()
        if (s.indexOf("FormatMenuVirtualKeyboard") >= 0) return item
        for (var i = 0; i < item.children.length; i++) {
            var r = findFormatMenu(item.children[i], depth + 1)
            if (r) return r
        }
        return null
    }

    function dumpTree(item, depth) {
        if (!item || depth > 3) return
        console.warn("XOVI-TREE: " + "  ".repeat(depth) + item.toString() + " y=" + item.y + " h=" + item.height)
        for (var i = 0; i < item.children.length; i++)
            dumpTree(item.children[i], depth + 1)
    }

    // 诊断：完整 dump 虚拟键盘树，找 Enter 按钮
    function dumpKbdDeep(item, depth) {
        if (!item || depth > 12) return
        var s = item.toString()
        var info = "[" + depth + "] " + s
        if (item.objectName) info += " n=" + item.objectName
        if (item.text !== undefined && item.text !== null && item.text !== "") info += " t=" + JSON.stringify(item.text)
        if (item.key !== undefined) info += " key=0x" + item.key.toString(16)
        if (item.keyType !== undefined) info += " keyType=" + item.keyType
        if (item.label !== undefined && item.label !== "") info += " label=" + JSON.stringify(item.label)
        if (typeof item.x === "number" && item.width > 0) info += " xy=" + item.x + "," + item.y + " wh=" + item.width + "x" + item.height
        console.warn("XOVI-KBD " + info)
        for (var i = 0; i < item.children.length; i++)
            dumpKbdDeep(item.children[i], depth + 1)
    }
    function dumpKbdOnce() {
        if (pinyinIME._kbdDumped) return
        var wins = Qt.application ? Qt.application.allWindows : null
        if (!wins || wins.length === 0) {
            var w = pinyinIME.Window.window
            if (w) wins = [w]
            else return
        }
        pinyinIME._kbdDumped = true
        console.warn("XOVI-KBD === " + wins.length + " windows ===")
        for (var wi = 0; wi < wins.length; wi++) {
            var w2 = wins[wi]
            console.warn("XOVI-KBD --- win#" + wi + " " + w2 + " w=" + w2.width + " h=" + w2.height + " visible=" + w2.visible)
            if (w2.contentItem) dumpKbdDeep(w2.contentItem, 0)
        }
    }

    // 按当前焦点判断 text / direct mode,置好 active/useDirectCommit/focusTarget,
    // 并把候选栏 reparent 到键盘 overlay(避免被虚拟键盘遮挡)。
    // 同时被 onLocaleChanged(英文→中文) 和 onVisibleChanged(visible=true) 调用;
    // 两条路径过去只有 onVisibleChanged 做完整初始化,切换语言这条就会漏 nudgeToolbar。
    function activateForCurrentFocus() {
        var item = pinyinIME.Window.window.activeFocusItem
        console.warn("XOVI-PINYIN: activateForCurrentFocus focus=" + item)
        if (item && item.text !== undefined) {
            pinyinIME.focusTarget = item
            pinyinIME.useDirectCommit = false
            pinyinIME._lastText = item.text
            pinyinIME.active = true
            // text mode：字母走原生 TextInput,不让 hook 拦
            pinyinIME.setMode("chinese", false)
            console.warn("XOVI-PINYIN: text mode")
        } else {
            pinyinIME.focusTarget = item
            pinyinIME.useDirectCommit = true
            pinyinIME.active = true
            if (item && item.controller) ctrlConn.target = item.controller
            // direct mode：字母改道到候选栏
            pinyinIME.setMode("chinese", true)
            // Timer 版靠 charPoller running 条件自动开链; 运行时版显式拉起
            Qt.callLater(pinyinIME._pollChars)
            console.warn("XOVI-PINYIN: direct mode, ctrl=" + (item ? item.controller : null))
        }
        Qt.callLater(pinyinIME.nudgeToolbar)
    }

    function nudgeToolbar() {
        var win = pinyinIME.Window.window
        if (!win) { pinyinIME.detachCandidateBar(); return }
        var root = win.contentItem
        var attached = false
        for (var i = 0; i < root.children.length; i++) {
            var vkw = root.children[i]
            if (vkw.toString().indexOf("VirtualKeyboard") < 0) continue
            for (var j = 0; j < vkw.children.length; j++) {
                var kp = vkw.children[j]
                if (kp.toString().indexOf("KeyboardPanel") < 0) continue
                for (var k = 0; k < kp.children.length; k++) {
                    var kb = kp.children[k]
                    if (kb.y < 100) continue
                    // child[1] 是键盘区域的 QML overlay
                    var overlay = kb.children[1]
                    if (!overlay || overlay.width <= 0) continue
                    // direct mode（编辑器）顶部有 FormatMenu 工具栏，留 80px 间距；
                    // text mode（搜索栏等）没工具栏，贴键盘顶
                    var gap = pinyinIME.useDirectCommit ? 80 : 0
                    console.warn("XOVI-PINYIN: reparenting candidateBar into overlay w=" + overlay.width + " gap=" + gap)
                    candidateBar.parent = overlay
                    candidateBar.x = 0
                    candidateBar.y = -candidateBar.height - gap
                    candidateBar.width = overlay.width
                    attached = true
                }
            }
        }
        // 没找到真实虚拟键盘 overlay（物理键盘 / 键盘未渲染）→ 浮动跟光标
        if (!attached) pinyinIME.detachCandidateBar()
    }

    Component.onCompleted: {
        console.warn("XOVI-PINYIN: IME ready v61-runtime (fast-refresh)")
        setMode("chinese", false)
        setMode("pinyin_active", false)
        // 快刷标记打在常驻整屏 fastZone 上 —— 会话期间几何零变化, 零抖动。
        var z = _markFastRefresh(fastZone)
        // 候选框自己再各标一层: 它俩是 fastZone 的兄弟节点, 谁的屏幕模式盖住候选框
        // 那块区域取决于场景图绘制顺序 —— 候选框可能没吃到 fastZone 的模式 (或被
        // 键盘/原生 ScreenModeItem 盖了), 于是候选框文字质感和正文不一致。
        // 显式给候选框自己标一层, 与 fastZone 同为 Animation, 区域重叠模式一致,
        // 不会引入模式图抖动。
        var z2 = _markFastRefresh(popupBox)
        var z3 = _markFastRefresh(candidateBar)
        console.warn("XOVI-PINYIN: fastZone=" + (z ? "ok" : "n/a")
                     + " popup=" + (z2 ? "ok" : "n/a") + " bar=" + (z3 ? "ok" : "n/a"))
    }

    // 候选栏（虚拟键盘用）：白底黑字，融入键盘界面，与浮动候选框 floatingPopup 统一。
    // 初始 parent=pinyinIME，位置浮动（光标附近 / 屏幕底部 fallback）；
    // 当虚拟键盘可见时由 nudgeToolbar reparent 到键盘 overlay 并硬设 x/y/width（原逻辑不变）。
    Rectangle {
        id: candidateBar
        // direct mode（物理键盘/无虚拟键盘）下由独立 floatingPopup 显示，本候选栏隐藏。
        visible: pinyinIME.pinyinBuffer !== "" && pinyinIME.active && !pinyinIME.useDirectCommit
        x: 0
        y: parent ? parent.height - height - 40 : 0
        width: pinyinIME.floatingBarWidth
        height: 80
        color: "white"
        border.color: "#888888"
        border.width: 1

        Row {
            anchors.left: parent.left
            anchors.top: parent.top
            anchors.bottom: parent.bottom
            anchors.leftMargin: 20
            anchors.right: prevArrow.left
            anchors.rightMargin: 10
            spacing: 0
            clip: true

            // 已输入的拼音串（灰色）
            Text {
                text: pinyinIME.pinyinBuffer
                color: "#888888"
                font.pixelSize: 30
                anchors.verticalCenter: parent.verticalCenter
                rightPadding: 20
            }

            // 分隔线
            Rectangle {
                width: 1
                height: 52
                color: "#bbbbbb"
                anchors.verticalCenter: parent.verticalCenter
                visible: pinyinIME.candidates.length > 0
            }

            // 候选词列表（黑字，点击选词）
            Repeater {
                model: Math.min(pinyinIME.pageSize, pinyinIME.candidates.length - pinyinIME.pageIdx * pinyinIME.pageSize)
                delegate: Item {
                    property int globalIdx: pinyinIME.pageIdx * pinyinIME.pageSize + index
                    width: cText.implicitWidth + 28
                    height: candidateBar.height

                    Text {
                        id: cText
                        anchors.centerIn: parent
                        text: (index + 1) + ". " + pinyinIME.candidates[parent.globalIdx]
                        font.pixelSize: 30
                        color: cTap.pressed ? "#666666" : "black"
                    }
                    MouseArea {
                        id: cTap
                        anchors.fill: parent
                        onClicked: pinyinIME.selectCandidate(parent.globalIdx)
                    }
                }
            }
        }

        // 上一页箭头（锚定到 nextArrow 左侧）
        Item {
            id: prevArrow
            width: visible ? 64 : 0
            height: parent.height
            anchors.right: nextArrow.left
            anchors.top: parent.top
            visible: pinyinIME.candidates.length > pinyinIME.pageSize
            opacity: pinyinIME.pageIdx > 0 ? 1.0 : 0.3
            Text {
                anchors.centerIn: parent
                text: "◀"
                font.pixelSize: 30
                color: prevTap.pressed ? "#666666" : "black"
            }
            MouseArea {
                id: prevTap
                anchors.fill: parent
                enabled: pinyinIME.pageIdx > 0
                onClicked: pinyinIME.pageIdx = pinyinIME.pageIdx - 1
            }
        }

        // 下一页箭头（锚定到候选栏右侧）
        Item {
            id: nextArrow
            width: visible ? 64 : 0
            height: parent.height
            anchors.right: parent.right
            anchors.rightMargin: 20
            anchors.top: parent.top
            visible: pinyinIME.candidates.length > pinyinIME.pageSize
            opacity: pinyinIME.pageIdx < pinyinIME.pageCount - 1 ? 1.0 : 0.3
            Text {
                anchors.centerIn: parent
                text: "▶"
                font.pixelSize: 30
                color: nextTap.pressed ? "#666666" : "black"
            }
            MouseArea {
                id: nextTap
                anchors.fill: parent
                enabled: pinyinIME.pageIdx < pinyinIME.pageCount - 1
                onClicked: pinyinIME.pageIdx = pinyinIME.pageIdx + 1
            }
        }
    }

    // 常驻整屏 Animation 快刷区。
    // 模式图 (EPScreenModeMap) 每变一次就要整屏重新合成一次 (日志实证), 所以关键
    // 不是"区域多小", 而是"变得多少次"。整屏覆盖 → 几何永不变, 只在中文输入会话
    // 开始/结束各变一次; 会话中无论候选框怎么伸缩移动、词怎么上屏, 都零抖动。
    // 代价: 输入期间全屏走 Animation 波形, 退出中文输入即恢复正常灰阶。
    Item {
        id: fastZone
        visible: pinyinIME.active && pinyinIME.isChineseMode
        anchors.fill: parent
    }

    // 物理键盘 direct mode 浮窗：紧凑型，宽度自适应内容，跟随光标。
    // 上面白底拼音框、下面深色圆角候选框（含翻页箭头）。
    Item {
        id: floatingPopup
        visible: pinyinIME.useDirectCommit && pinyinIME.pinyinBuffer !== "" && pinyinIME.active
        width: popupBox.width
        height: popupBox.height
        x: {
            if (pinyinIME.cursorLocalX < 0) return 20
            var parentW = parent ? parent.width : 1404
            var cx = pinyinIME.cursorLocalX - width / 2
            if (cx < 10) cx = 10
            if (cx + width > parentW - 10) cx = parentW - width - 10
            return cx
        }
        y: {
            if (pinyinIME.cursorLocalY < 0) return (parent ? parent.height - height - 40 : 0)
            var parentH = parent ? parent.height : 1872
            var below = pinyinIME.cursorLocalY + 20
            if (below + height <= parentH - 20) return below
            return Math.max(10, pinyinIME.cursorLocalY - height - 10)
        }

        // 单框: 左边拼音字母, 竖线分隔, 右边候选汉字。宽度随内容自适应。
        // (整屏走 Animation 快刷后, 框尺寸/位置变化不再触发全屏重刷, 无需固定尺寸。)
        Rectangle {
            id: popupBox
            color: "white"
            border.color: "black"
            border.width: 1
            radius: 6
            width: candRow.width + 24
            height: candRow.height + 16

            Row {
                id: candRow
                x: 12
                anchors.verticalCenter: parent.verticalCenter
                spacing: 14

                // 已输入的拼音串
                Text {
                    anchors.verticalCenter: parent.verticalCenter
                    text: pinyinIME.pinyinBuffer
                    color: "black"
                    font.pixelSize: 28
                }
                // 分隔线 (有候选时才显示)
                Rectangle {
                    visible: pinyinIME.candidates.length > 0
                    width: 1
                    height: 34
                    color: "#bbbbbb"
                    anchors.verticalCenter: parent.verticalCenter
                }

                Repeater {
                    model: Math.min(pinyinIME.pageSize, pinyinIME.candidates.length - pinyinIME.pageIdx * pinyinIME.pageSize)
                    delegate: Item {
                        property int globalIdx: pinyinIME.pageIdx * pinyinIME.pageSize + index
                        width: cText2.implicitWidth + 6
                        height: cText2.implicitHeight + 14
                        Text {
                            id: cText2
                            anchors.centerIn: parent
                            text: (index + 1) + "." + pinyinIME.candidates[parent.globalIdx]
                            color: cTap2.pressed ? "#666666" : "black"
                            font.pixelSize: 28
                        }
                        MouseArea {
                            id: cTap2
                            anchors.fill: parent
                            onClicked: pinyinIME.selectCandidate(parent.globalIdx)
                        }
                    }
                }

                Item {
                    width: 32
                    height: 38
                    visible: pinyinIME.candidates.length > pinyinIME.pageSize
                    anchors.verticalCenter: parent.verticalCenter
                    Text {
                        anchors.centerIn: parent
                        text: "‹"
                        font.pixelSize: 28
                        color: pinyinIME.pageIdx > 0 ? (prevTap2.pressed ? "#666666" : "black") : "#bbbbbb"
                    }
                    MouseArea {
                        id: prevTap2
                        anchors.fill: parent
                        enabled: pinyinIME.pageIdx > 0
                        onClicked: pinyinIME.pageIdx = pinyinIME.pageIdx - 1
                    }
                }
                Item {
                    width: 32
                    height: 38
                    visible: pinyinIME.candidates.length > pinyinIME.pageSize
                    anchors.verticalCenter: parent.verticalCenter
                    Text {
                        anchors.centerIn: parent
                        text: "›"
                        font.pixelSize: 28
                        color: pinyinIME.pageIdx < pinyinIME.pageCount - 1 ? (nextTap2.pressed ? "#666666" : "black") : "#bbbbbb"
                    }
                    MouseArea {
                        id: nextTap2
                        anchors.fill: parent
                        enabled: pinyinIME.pageIdx < pinyinIME.pageCount - 1
                        onClicked: pinyinIME.pageIdx = pinyinIME.pageIdx + 1
                    }
                }
            }
        }
    }
}
