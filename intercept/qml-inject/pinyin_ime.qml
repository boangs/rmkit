// pinyin_ime.qml — 拼音候选框 (pinyin_interceptor.qmd 的运行时注入版, v61-runtime)
// 由 qml_inject_impl.so 在启动后创建, parent = 主窗口 contentItem (等价于原 qmd
// 注入点 MainView.qml 的 FocusScope#rootItem, 都是全屏根节点)。
//
// 与 qmd 版的差异:
// A) Timer 替换 (运行时注入组件里 Timer 不触发, 见 memory feedback_runtime_qml_no_timer):
//    1. charPoller (500ms, long-poll 链兜底) → C++ 每 250ms 写 imeTick 属性驱动
//    2. textWatcher (80ms 轮询 TextInput.text) → Connections onTextChanged 事件驱动
//    (原 candidatesDebounce 250ms 防抖已移除 —— 整屏 Animation 快刷后刷新代价低,
//     候选框实时跟手)
// B) e-ink 快刷: 中文输入时整屏走 Animation 波形 (fastZone), 消除打字卡顿+闪屏,
//    汉字上屏更快更清晰 (见下方 _markFastRefresh / fastZone 注释)。
import QtQuick

Item {
    id: pinyinIME
    objectName: "rmkitPinyinIME"
    z: 99999

    // ── 横屏支持 ───────────────────────────────────────────────────
    // xochitl 横屏不是转窗口, 而是把各个原生窗口 (ShortcutsWindow/GesturesWindow
    // 等) 各自旋转 90° 并位移: 根节点仍是竖屏 954x1696, 而它们变成 1696x954
    // pos=(-371,371)。我们注入在根节点上, 不在那些被旋转的容器里, 所以不会跟着转
    // —— 表现为界面横过来了、候选框却还竖着侧躺 (实测截图)。
    //
    // 对策: 自己复制那套变换。检测到原生窗口是横屏尺寸时, 把自己也按屏幕中心
    // 旋转 90°, 并交换宽高, 这样内部所有布局按横屏的宽高算, 与原生 UI 对齐。
    // 判定横屏: 找"尺寸与根节点交换"的原生窗口容器。
    // 不能用"任一子节点宽>高"—— 工具栏/状态栏天生宽>高, 竖屏下也会误判,
    // 结果候选框在竖屏被转了 90 度 (用户实测)。
    // 实测数据: 竖屏时所有容器都是 954x1696 (同根节点);
    //           横屏时变成 1696x954 pos=(-371,371)。
    property bool _landscape: {
        var w = pinyinIME.Window.window
        if (!w || !w.contentItem) return false
        var root = w.contentItem
        var kids = root.children
        for (var i = 0; i < kids.length; i++) {
            var k = kids[i]
            if (k !== pinyinIME && k.width > 100 && k.height > 100 &&
                Math.abs(k.width - root.height) < 8 && Math.abs(k.height - root.width) < 8)
                return true
        }
        return false
    }
    // 竖屏: 直接铺满。横屏: 宽高互换 + 绕中心转 90°, 与原生窗口同一套变换。
    width: _landscape ? (parent ? parent.height : 1696) : (parent ? parent.width : 954)
    height: _landscape ? (parent ? parent.width : 954) : (parent ? parent.height : 1696)
    x: _landscape && parent ? (parent.width - width) / 2 : 0
    y: _landscape && parent ? (parent.height - height) / 2 : 0
    rotation: _landscape ? 90 : 0

    // ime-server 地址。所有接口 (含 setMode) 统一走这个地址, 不能分裂 ——
    // 曾经 setMode 写死 19876 而 rime 接口指向验证实例 19899, 生产服务一停
    // 标志就建不起来, 表现为"只能打英文"。
    property string rimeBase: "http://127.0.0.1:19876"

    property string pinyinBuffer: ""
    property var candidates: []
    property int pageIdx: 0
    // librime 返回的分页信息 (它自己管分页, QML 不再本地切片)
    property bool _isLastPage: true
    property int _highlighted: 0
    readonly property int pageSize: 5
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
    // 靠"光标位移"反推虚拟键盘的回车/退格 (onTextCursorIndexChanged 里那套)。
    // 只对 reMarkable 虚拟键盘有意义——它的回车/退格键绕过 hook 和 setCommitString,
    // 唯一线索就是光标动了没。物理键盘的回车/退格由 hook 直接送引擎, 根本不需要它;
    // 而在五笔这种"短码 + 唯一码自动上屏"下, 上屏推动光标前移会被误判成回车,
    // 触发 commitBufferAfterEnter 去 selectTextRange 替换, 把已上屏的字也吃掉。
    // 默认关闭; 将来做虚拟键盘拦截时, 对应设备再置 true (且要先修准误判)。
    property bool cursorKeyInference: false
    property bool _kbdDumped: false
    // long-poll 链状态: true 时表示 /pop-all-chars-blocking xhr 在挂,
    // 阻止 fallback 重复发起。响应到达后 chain 立即重发。
    property bool _charXhrActive: false

    // ── Timer 替代机制 ──────────────────────────────────────────────
    // C++ (qml_inject_impl) 每 250ms 自增写入 imeTick。
    property int imeTick: 0
    // C++ 事件过滤器在真实焦点事件 (FocusIn/WindowActivate) 时自增此属性。
    // QML 自己的 onActiveFocusItemChanged 并非所有路径都触发 —— 实测用户点进
    // 已打开的记事本时收不到, 于是永远不激活、打不出中文。改由 C++ 侧驱动。
    // controller 未就绪时的重试余额 (焦点事件触发, 用完即止, 不是持续轮询)
    property int _ctrlRetry: 0
    // C++ 在焦点事件时定向找到的编辑器 (SceneView)。焦点本身常落在
    // ActionHeader 等无关元素上, 只看 activeFocusItem 会永远激活不了。
    property var editorItem: null
    property int _xhrStuck: 0
    property int _interceptStuck: 0
    // 输入活动窗口: 快刷区的开关依据 (见 fastZone 注释)
    property bool _inputBusy: false
    property int _lastInputTick: -999
    // 在途的长轮询 XHR。强制复位时必须 abort 它, 否则连接泄漏 (见下)。
    property var _charXhr: null
    // 长轮询非 200/网络错误累计次数 (只用于限流日志)
    property int _pollErrs: 0
    property int focusPing: 0
    onFocusPingChanged: {
        if (!active) enterDirectModeIfApplicable()
    }
    // text 模式上一次的文本快照 (原 textWatcher.lastText)
    property string _lastText: ""
    onImeTickChanged: {
        // 原 charPoller Timer (500ms) 职责: long-poll 链兜底重启
        // (_pollChars 内部有 _charXhrActive / intercepting / mode 守卫, 幂等)
        // 二重保险: XHR 若静默失效 (既不回调也不超时), _charXhrActive 会永远
        // 卡在 true。连续 40 个 tick (10s, 远超服务端 5s 长轮询) 仍未回来就强制复位。
        if (_charXhrActive) {
            _xhrStuck++
            if (_xhrStuck > 120) {   // 30s, 远超服务端 5s 长轮询, 避免误判
                _xhrStuck = 0
                // ★ 必须 abort 旧请求再复位标志。
                // 只置 _charXhrActive=false 的话旧连接一直挂着, 复位一次泄漏一条;
                // Qt 对同一主机的并发连接数有上限 (默认 6), 攒满之后新请求永远排队
                // 不发出 —— 表现就是"每 30 秒复位一次却再也拉不到东西, 中文彻底没了"
                // (实测 netstat 看到 4 条 ESTABLISHED 挂在 19876 上)。
                if (_charXhr) {
                    try { _charXhr.abort() } catch (e) {}
                    _charXhr = null
                }
                _charXhrActive = false
                console.warn("XOVI-PINYIN: 拉取链卡死, 已 abort 旧请求并复位")
            }
        } else {
            _xhrStuck = 0
        }
        // intercepting 死锁兜底: 它在多处被手动置位/复位, 只要有一条路径中途抛异常
        // 就会永久停在 true, 而 _pollChars 开头就被它挡住 —— 拉取链彻底停摆, 没有
        // 任何自愈机会 (实测 placeAnchor 空 controller 抛异常就是这么锁死的)。
        // 正常的 intercepting 窗口只有一两帧, 连续 20 拍 (5 秒) 还没复位必是异常。
        if (intercepting) {
            _interceptStuck++
            if (_interceptStuck > 20) {
                _interceptStuck = 0
                intercepting = false
                console.warn("[rmkit-ime] intercepting 卡死, 已强制复位")
            }
        } else {
            _interceptStuck = 0
        }
        if (_inputBusy && imeTick-_lastInputTick > 20) _inputBusy = false
        if (active && isChineseMode) _pollChars()   // 两种模式都要拉链
        // 仅在"焦点已到编辑器但 controller 还没绑好"时短暂重试, 用完即止。
        // 平时这里什么都不做 —— 持续轮询会和打字渲染抢主线程 (实测明显卡顿)。
        if (_ctrlRetry > 0 && !active) {
            _ctrlRetry--
            enterDirectModeIfApplicable()
        }
    }

    // ── 中文模式判定 ───────────────────────────────────────────────
    // 不能只信 Qt.inputMethod.locale: 它要等虚拟键盘出现过一次才会变成 zh_CN。
    // 用户接物理键盘直接打开记事本时虚拟键盘从未出现 → locale 还是默认值 →
    // 判定为非中文 → 不开拦截 → 字母直接进正文 (必须先调出虚拟键盘才正常, 实测)。
    // 回退到读 xochitl 配置里的 Keyboard=, 那才是用户真正设定的键盘。
    property bool _cfgChinese: false
    function _loadKeyboardCfg() {
        try {
            var xhr = new XMLHttpRequest()
            xhr.open("GET", "file:///home/root/.config/remarkable/xochitl.conf", false)
            xhr.send()
            pinyinIME._cfgChinese = /Keyboard\s*=\s*zh/i.test(xhr.responseText || "")
            console.warn("XOVI-PINYIN: 键盘配置 zh=" + pinyinIME._cfgChinese)
        } catch (e) {
            console.warn("XOVI-PINYIN: 读键盘配置失败 " + e)
        }
    }
    // locale 可信时以它为准 (用户在虚拟键盘上切语言要能立刻生效);
    // locale 尚未初始化 (空 / 不含区域信息) 时才用配置兜底。
    // 注意: 不要在这里读文件。_cfgChinese 是启动时读一次的缓存 ——
    // 早先版本每次调用都同步 XHR 读配置 (阻塞主线程做磁盘 IO), 而本函数被
    // 激活检查每秒调用数次 → 打字明显卡顿。
    function _isChineseNow() {
        var loc = Qt.inputMethod.locale
        var lang = loc ? loc.name : ""
        if (lang.indexOf("zh") === 0) return true
        if (lang === "" || lang === "C") return pinyinIME._cfgChinese
        return false
    }

    // 模式标志也走 rimeBase, 不能写死 19876 —— 否则验证期把 rime 接口指到测试
    // 端口后, setMode 仍打生产端口; 生产服务一停请求就全失败, chinese_mode 标志
    // 建不起来, 事件过滤器永不拦截 → 只能打英文 (实测踩过)。
    function setMode(key, val) {
        var xhr = new XMLHttpRequest()
        xhr.open("GET", rimeBase + "/set-mode?" + key + "=" + (val ? "1" : "0"))
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
    property int _diagN: 0
    function enterDirectModeIfApplicable() {
        var dbg = pinyinIME._diagN < 20
        if (dbg) pinyinIME._diagN++
        var win = pinyinIME.Window.window
        if (!win) { if (dbg) console.warn("[rmkit-ime] 无 window"); return false }
        var item = win.activeFocusItem
        // 焦点项没有 controller 时改用 C++ 定向找到的编辑器
        if ((!item || item.controller === undefined || !item.controller) &&
            pinyinIME.editorItem && pinyinIME.editorItem.controller)
            item = pinyinIME.editorItem
        if (!item) { if (dbg) console.warn("[rmkit-ime] 无焦点项"); return false }
        if (!pinyinIME._isChineseNow()) {
            if (dbg) console.warn("[rmkit-ime] 判定非中文 locale=" +
                (Qt.inputMethod.locale ? Qt.inputMethod.locale.name : "?") +
                " cfg=" + pinyinIME._cfgChinese)
            return false
        }
        if (item.text !== undefined) {
            if (dbg) console.warn("[rmkit-ime] 焦点是 TextInput → " + item)
            return false
        }
        if (!item.controller) {
            // 焦点已经落在编辑器 (SceneView) 上, 但它的 controller 属性此刻还没
            // 绑定完 —— 焦点事件比属性就绪早。以前靠虚拟键盘的 onVisibleChanged
            // (时机晚得多) 才成功, 这正是"必须先调出虚拟键盘才能打中文"的根源。
            // 安排有限次重试: 由焦点事件触发, 最多 8 次 (约 2 秒) 后自动停止,
            // 不是无限轮询。
            if (item.text === undefined && pinyinIME._ctrlRetry <= 0)
                pinyinIME._ctrlRetry = 8
            if (dbg) console.warn("[rmkit-ime] controller 未就绪, 安排重试 → " + item)
            return false
        }
        pinyinIME.focusTarget = item
        pinyinIME.useDirectCommit = true
        pinyinIME.active = true
        pinyinIME.isChineseMode = true
        ctrlConn.target = item.controller
        pinyinIME.setMode("chinese", true)
        // 物理键盘没有虚拟键盘 overlay → 候选栏必须 detach 回 pinyinIME，
        // 否则之前 nudgeToolbar 把它 reparent 到 overlay (width=0) 会看不见。
        pinyinIME.detachCandidateBar()
        // 清空服务端 librime session: 它是常驻的, 不清会把上一轮/上一个焦点
        // 遗留的 preedit 继续累积 (实测过: 打一个 n 就把历史输入全吐出来)
        pinyinIME._rimeCall("/rime/clear")
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
        // text 模式 (搜索框等 GeneralTextInput) 没有 controller —— 它直接改
        // TextInput.text, 不需要零宽空格占位符。
        // 曾经这里不判空: ctrl 为 undefined 时先把 intercepting 置成 true 再抛
        // TypeError, 于是 intercepting 永远卡在 true, _pollChars 开头的守卫让
        // 拉取链彻底锁死 (250ms 心跳兜底也救不回来), 服务端 20 秒后判定 QML
        // 停止拉取清掉模式标志 —— 表现就是"没有候选框, 过几秒变成输出英文"。
        if (!ctrl) return
        // 占位符只为"光标位移反推虚拟键盘按键"服务 (见 cursorKeyInference)。
        // 那套关闭时, 占位符纯属多余: 组字期间往光标处插零宽空格再靠延后回调挪
        // 光标, 一插一挪正是"光标落到中间"的来源。关闭推断时直接不插, 组字期间
        // 文档保持原样, 上屏时汉字落在光标处。
        if (!cursorKeyInference) return
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
        if (!ctrl) { hasAnchor = false; return }
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
            console.warn("XOVI-PINYIN: Shortcut Enter captured, preedit=" + pinyinIME.pinyinBuffer)
            // 把回车按键送给 librime 由它决定上屏内容 (整句成型 / 上原拼音),
            // 不再由 QML 自行拼装 —— 服务端 /rime/input 已按 keysym 处理 \\r。
            pinyinIME._rimeCall("/rime/key?code=13")
        }
    }

    // long-poll 字符处理 — 调用 ime-server /pop-all-chars-blocking
    // 该 endpoint 通过 ime_hook 的 unix socket notify 实现 0-polling 唤醒,
    // 字符到达立刻返回 (~5ms)。响应处理完后 chain 递归立刻发下一次 xhr,
    // 形成持续 long-poll 链。imeTick (250ms) 仅作 fallback (网络
    // 错误 / 服务重启时把链拉回来)。
    // 两种模式共用: direct(记事本 SceneView) 和 text(搜索栏等 TextInput)。
    // 事件过滤器统一截键 → 服务端 librime 出候选 → 这里取回并显示/上屏。
    function _pollChars() {
        if (pinyinIME._charXhrActive) return
        if (pinyinIME.intercepting) return
        if (!pinyinIME.active || !pinyinIME.isChineseMode) return
        // direct 模式需要 controller 往文档写; text 模式直接改 TextInput.text,
        // 没有 controller 也要继续 (否则搜索栏里永远收不到候选)。
        var ctrl = pinyinIME.focusTarget ? pinyinIME.focusTarget.controller : null
        if (pinyinIME.useDirectCommit && !ctrl) return

        pinyinIME._charXhrActive = true
        // ★ 卡死计数按"当前这条请求"从零起算。原先只在某个 tick 恰好没有请求在飞时
        // 才清零, 而健康的长轮询链永远有请求在飞 (回来就立刻续链), 于是每 121 tick
        // (30.25s, 与 rm2 日志间隔严丝合缝) 误判一次, 把正常请求 abort 掉重发。
        pinyinIME._xhrStuck = 0
        var xhr = new XMLHttpRequest()
        pinyinIME._charXhr = xhr
        xhr.timeout = 6000  // 略大于 ime-server blocking 5s timeout
        xhr.onreadystatechange = function() {
            if (xhr.readyState !== 4) return
            pinyinIME._charXhrActive = false
            if (pinyinIME._charXhr === xhr) pinyinIME._charXhr = null
            if (xhr.status === 200 && xhr.responseText) {
                var st = null
                try { st = JSON.parse(xhr.responseText) } catch (e) {}
                // _applyState 抛异常绝不能中断拉取链: 它下面就是续链的 callLater,
                // 一旦异常逃逸, 链就永久停在这里, 且 intercepting 可能停在 true。
                if (st) {
                    try {
                        pinyinIME._applyState(st, ctrl)
                    } catch (e2) {
                        pinyinIME.intercepting = false
                        console.warn("[rmkit-ime] 应用状态异常, 已复位并续链: " + e2)
                    }
                }
            }
            // chain — Qt.callLater 避免栈深递归 + 让 QML 事件循环处理一轮再发。
            // ★ 只有 200 才立即续链。非 200 (后端版本不带 /rime 路由 → 404、
            // 后端重启中 → 503) 绝不能零延迟重发: 实测 rm2 上 404 让这里每秒打
            // 上千次 XHR, 32 位 xochitl 几分钟就 std::bad_alloc 崩掉。
            // 非 200 时放手, 由 onImeTickChanged (250ms) 兜底重新拉链 = 天然退避。
            if (xhr.status === 200) {
                Qt.callLater(pinyinIME._pollChars)
            } else {
                pinyinIME._pollErrs++
                if (pinyinIME._pollErrs === 1 || pinyinIME._pollErrs % 200 === 0)
                    console.warn("[rmkit-ime] 长轮询非 200 (status=" + xhr.status + ", 累计 " + pinyinIME._pollErrs + " 次), 交由 tick 退避重试")
            }
        }
        // 超时/网络错误必须复位标志, 否则拉取链永久卡住:
        // 链一断 → 服务端看门狗判定"QML 停止拉取"清掉模式标志 → hook 不再拦截
        // → 候选消失; 同时"打字时跳过扫描"的保护也失效, 1.6s 的扫描就撞进打字里。
        xhr.ontimeout = function() {
            pinyinIME._charXhrActive = false
            Qt.callLater(pinyinIME._pollChars)
        }
        xhr.onerror = function() {
            // 连接被拒 (ime-server 未起/重启中) 同样不能零延迟重发, 交给 tick 退避
            pinyinIME._charXhrActive = false
            pinyinIME._pollErrs++
            if (pinyinIME._pollErrs === 1 || pinyinIME._pollErrs % 200 === 0)
                console.warn("[rmkit-ime] 长轮询网络错误 (累计 " + pinyinIME._pollErrs + " 次), 交由 tick 退避重试")
        }
        try {
            xhr.open("GET", rimeBase + "/rime/input")
            xhr.send()
        } catch (e) {
            pinyinIME._charXhrActive = false
            console.warn("[rmkit-ime] 长轮询发送失败: " + e)
        }
    }

    // 把 ime-server 返回的输入状态应用到界面 + 文档。
    // librime 已在服务端完成全部输入逻辑 (音节切分、整句、选词、翻页、标点、
    // 退格、userdb 调频), QML 只做两件事: 显示 preedit/候选, 把 commit 上屏。
    function _applyState(st, ctrl) {
        pinyinIME.refreshCursorPosition()
        var newPreedit = st.preedit || ""
        var hadPreedit = pinyinIME.pinyinBuffer !== ""
        if (newPreedit !== "" || (st.commit && st.commit.length > 0)) {
            pinyinIME._lastInputTick = pinyinIME.imeTick
            pinyinIME._inputBusy = true
        }

        // 上屏文本 (librime 在选词/整句成型/回车时产生)
        // ★ 上屏与新编码可能在同一个状态里到达 (快速连打时服务端把积压按键一次
        // 喂完: 例如五笔 "i␣d" 返回 commit=不 + preedit=d)。insertToDoc 插完字后
        // 光标停在选区起点, 要靠延后回调才归位到字后面; 若此时立刻放占位符, 读到的
        // 是归位前的旧光标 → 占位符插到"不"前面 → 真实光标比锚点多两格 → 被
        // "前移超一格当回车"误判, 把编码原样上屏并把"不"替换掉。实测 rm2 五笔
        // 快打 "你不在这里" 变成 "你id里这" 就是这条路。
        // 对策: 有上屏时把占位符的放置排到光标归位之后 (deferAnchor), 而不是同步放。
        var deferAnchor = false
        if (st.commit && st.commit.length > 0) {
            pinyinIME.intercepting = true
            pinyinIME.removeAnchor(ctrl)          // 先撤零宽空格占位符 (text 模式无占位符)
            if (ctrl) {
                deferAnchor = newPreedit !== ""
                pinyinIME.insertToDoc(ctrl, st.commit, deferAnchor ? function() {
                    // 光标已归位到上屏文本之后, 此时再放占位符位置才正确
                    if (pinyinIME.pinyinBuffer !== "" && !pinyinIME.hasAnchor)
                        pinyinIME.placeAnchor(ctrl)
                } : null)      // direct 模式: 走文档 API
            } else {
                pinyinIME.insertToTextInput(st.commit)      // text 模式: 直接改 TextInput
            }
            pinyinIME.intercepting = false
        }

        // 编辑区文本: 非空时需要占位符吸收退格; 空了就撤掉。
        // pinyin_active 标志不在这里设 —— 已改由 ime-server 在返回状态时同步写
        // (QML 侧发请求去设中间隔一次往返, 连续打字时空格会赶在标志生效前按下,
        // hook 不吞 → librime 收不到提交 → preedit 无限累积)。
        // 只要还在输入就保证占位符在位 (原来只在"从空变非空"时放, 而虚拟键盘退格
        // 会把占位符删掉 → 之后没东西可删 → 光标不动 → 检测不到, 只能删一次)。
        // 虚拟键盘的退格既不走 setCommitString 也不走 processKeyEvent (探针实证),
        // 直接改文档, 所以占位符是唯一能感知它的手段, 必须持续维护。
        if (newPreedit !== "" && !pinyinIME.hasAnchor) {
            if (!deferAnchor) pinyinIME.placeAnchor(ctrl)   // 有上屏时由 insertToDoc 回调延后放
        } else if (newPreedit === "" && hadPreedit) {
            pinyinIME.removeAnchor(ctrl)
            // 兜底: 候选框一消失就清服务端 session。即使还有没覆盖到的路径让
            // 两边状态不一致, 也不会让脏状态长期留着继续累积。
            pinyinIME._rimeCall("/rime/clear")
        }

        pinyinIME.pinyinBuffer = newPreedit
        pinyinIME.candidates = st.candidates || []
        pinyinIME.showBar = newPreedit !== ""
        // 分页由 librime 管, 它返回的就是当前页; pageIdx 仅供 UI 显示页码
        pinyinIME.pageIdx = st.pageNo || 0
        pinyinIME._isLastPage = !!st.isLastPage
        pinyinIME._highlighted = st.highlighted || 0
    }

    // 通用: 请求 ime-server 的某个 rime 端点并应用返回状态 (选词/翻页/清空)
    function _rimeCall(path) {
        // ctrl 可以为 null —— text 模式 (搜索框) 本来就没有 controller, _applyState
        // 会按有无 controller 分流上屏路径。
        // 这里原先有 `if (!ctrl) return`, 于是 text 模式下本函数**一个请求都发不出去**:
        // 点候选 (/rime/select)、退格 (/rime/key)、激活时清会话 (/rime/clear) 全部
        // 静默失效 —— 表现为"空格能上屏, 点候选没反应", 且上次的 preedit 一直留在
        // 服务端会话里。空格能用是因为它走 hook → 字符队列 → /rime/input 另一条通路。
        var ctrl = pinyinIME.focusTarget ? pinyinIME.focusTarget.controller : null
        var xhr = new XMLHttpRequest()
        xhr.onreadystatechange = function() {
            if (xhr.readyState !== 4) return
            if (xhr.status === 200 && xhr.responseText) {
                var st = null
                try { st = JSON.parse(xhr.responseText) } catch (e) {}
                if (st) pinyinIME._applyState(st, ctrl)
            }
        }
        xhr.open("GET", rimeBase + path)
        xhr.send()
    }

    // (原 charPoller Timer 位置 — 已由 onImeTickChanged 的 _pollChars 兜底取代)

    // ── SceneView controller：检测退格（U+200B 占位符被删） ──────────
    Connections {
        id: ctrlConn
        target: null

        function onTextCursorIndexChanged() {
            // 光标位移反推回车/退格默认关闭 (见 cursorKeyInference 注释)。
            // 物理键盘用户走 hook 正路, 开着只会在五笔上吃字。
            if (!pinyinIME.cursorKeyInference) return
            if (pinyinIME.intercepting || !pinyinIME.isChineseMode || !pinyinIME.useDirectCommit) return
            if (!pinyinIME.hasAnchor || pinyinIME.pinyinBuffer === "") return
            var ctrl = pinyinIME.focusTarget ? pinyinIME.focusTarget.controller : null
            if (!ctrl) return
            var newIdx = ctrl.textCursorIndex

            // 光标退到占位符位置或更前 → 占位符被退格键删掉了。
            // ime_hook 只是"吞掉"退格 (免得它删正文), 并不转发给引擎 —— 所以必须
            // 由这里把退格补送给 librime, 否则它的 preedit 原封不动, 下一个字母
            // 直接接在后面 (实测: NI 退格后再打 N 变成 NNI, 越积越长)。
            // 旧版是 QML 自己维护缓冲区才能本地 slice; 现在缓冲区归 librime。
            if (newIdx <= pinyinIME.anchorIdx) {
                pinyinIME.hasAnchor = false
                pinyinIME.anchorIdx = newIdx
                console.warn("XOVI-PINYIN: 虚拟退格 → 转发 librime (idx=" + newIdx + ")")
                // code=8 → 服务端映射成 BackSpace keysym 送进 rime session。
                // 返回的新状态会重建占位符 (preedit 非空时 _applyState 会 placeAnchor)
                pinyinIME._rimeCall("/rime/key?code=8")
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
            var isChinese = pinyinIME._isChineseNow()   // locale 优先, 未初始化时用配置兜底
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
                var isChinese = pinyinIME._isChineseNow()
                pinyinIME.isChineseMode = isChinese
                console.warn("XOVI-PINYIN: kb visible locale=" + lang + " chinese=" + isChinese)
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
                    // 字母转发给 librime (它维护缓冲区+候选), 不再本地累积
                    pinyinIME._rimeCall("/rime/key?code=" + added.charCodeAt(added.length - 1))
                } else if (pinyinIME.pinyinBuffer !== "") {
                    pinyinIME.commitTextMode(added.length)
                }
            } else if (t.length < pinyinIME._lastText.length) {
                pinyinIME._lastText = t
                if (pinyinIME.pinyinBuffer !== "") {
                    pinyinIME._rimeCall("/rime/key?code=8")   // 退格同样转发
                }
            }
        }
    }

    // then: 可选回调, 在光标归位到上屏文本之后执行 (见 _applyState 的 deferAnchor)。
    function insertToDoc(ctrl, text, then) {
        if (!text || !ctrl) return
        try {
            var startIdx = ctrl.textCursorIndex
            ctrl.beginInputMethodTransaction()
            ctrl.replaceComposeText(text, true)
            ctrl.commitInputMethod()
            ctrl.clearComposeRange()
            ctrl.endInputMethodTransaction()
            Qt.callLater(function() {
                ctrl.setCursorIndex(startIdx + text.length)
                // 再让事件循环走一拍, 确保光标归位已落地, 回调里读到的才是新位置
                if (then) Qt.callLater(function() {
                    try { then() } catch (e2) { console.warn("XOVI-PINYIN: insertToDoc then FAIL: " + e2) }
                })
            })
        } catch(e) {
            console.warn("XOVI-PINYIN: insertToDoc FAIL: " + e)
        }
    }

    // text 模式 (搜索框等 GeneralTextInput) 的上屏: 直接改 TextInput.text。
    //
    // 这条路径原先是缺的 —— insertToDoc 见 ctrl 为空就 return, 于是搜索框里
    // "有候选、选完却什么都不进框"。老的 commitTextMode 那套"按 pinyinBuffer
    // 长度回切文本"逻辑是自研引擎时代的遗留: 那时字母真的被打进输入框, 再整体
    // 替换; 现在字母全被 hook 吞走, 框里根本没有拼音可替换。
    // 调用方负责 intercepting 的置位/复位 (改 text 会触发 onTextChanged)。
    function insertToTextInput(text) {
        if (!text || !focusTarget || focusTarget.text === undefined) return
        var before = focusTarget.text
        var pos = focusTarget.cursorPosition
        if (pos === undefined || pos < 0 || pos > before.length) pos = before.length

        // 优先用 TextInput 原生 insert(): 直接给 text 赋值在被 binding 绑住的
        // 封装组件 (xochitl 的 GeneralTextInput) 上会被静默覆盖, 看起来就是
        // "候选选了却什么都没进框"。insert() 走内部编辑路径, 不与 binding 打架。
        var ok = false
        try {
            if (typeof focusTarget.insert === "function") {
                focusTarget.insert(pos, text)
                ok = (focusTarget.text !== before)
            }
        } catch (e) {}
        if (!ok) {
            focusTarget.text = before.substring(0, pos) + text + before.substring(pos)
            focusTarget.cursorPosition = pos + text.length
            ok = (focusTarget.text !== before)
        }
        pinyinIME._lastText = focusTarget.text
        if (!ok)
            console.warn("[rmkit-ime] text 模式上屏失败: 目标不接受写入 " + focusTarget)
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

    // 空格/回车的上屏行为已交给 librime (按键随字符流送到服务端, 由它决定
    // 上首选还是上原拼音)。这里只保留清空入口给焦点切换等场景。
    function abandonInput() {
        pinyinIME._rimeCall("/rime/clear")
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

    // 选词交给 librime: 整句输入下选一个候选是"把它并入已选、继续等后续音节",
    // 不是简单地把字符串上屏 —— 本地无法模拟, 必须走服务端。
    function selectCandidate(idx) {
        pinyinIME._rimeCall("/rime/select?index=" + idx)
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
        // 本地清空的同时也清服务端 session, 两边状态必须一致
        if (pinyinBuffer !== "") pinyinIME._rimeCall("/rime/clear")
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
            // text mode (搜索栏等 TextInput)。
            // ★ 必须同样开启拦截: 旧架构下 text 模式让字母原生进 TextInput、QML
            // 轮询 text 变化, 所以故意 setMode("chinese", false)。改用事件过滤器 +
            // librime 后两种模式的输入路径已统一, 再关拦截就等于这里完全没有中文
            // —— 实测虚拟键盘弹出时焦点是 GeneralTextInput, 走到这里把中文关掉,
            // 于是"输不出汉字"。
            pinyinIME.setMode("chinese", true)
            pinyinIME._rimeCall("/rime/clear")
            console.warn("XOVI-PINYIN: text mode (拦截已开启)")
        } else {
            pinyinIME.focusTarget = item
            pinyinIME.useDirectCommit = true
            pinyinIME.active = true
            if (item && item.controller) ctrlConn.target = item.controller
            // direct mode：字母改道到候选栏
            pinyinIME.setMode("chinese", true)
            pinyinIME._rimeCall("/rime/clear")   // 同上: 每次激活都从干净状态开始
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
        console.warn("XOVI-PINYIN: IME ready v62-runtime (event-filter)")
        _loadKeyboardCfg()
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
                model: pinyinIME.candidates.length
                delegate: Item {
                    width: cText.implicitWidth + 28
                    height: candidateBar.height

                    Text {
                        id: cText
                        anchors.centerIn: parent
                        text: (index + 1) + ". " + pinyinIME.candidates[index]
                        font.pixelSize: 30
                        color: cTap.pressed ? "#666666" : "black"
                    }
                    MouseArea {
                        id: cTap
                        anchors.fill: parent
                        onClicked: pinyinIME.selectCandidate(index)
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
            visible: !pinyinIME._isLastPage || pinyinIME.pageIdx > 0
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
                onClicked: pinyinIME._rimeCall("/rime/page?backward=1")
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
            visible: !pinyinIME._isLastPage || pinyinIME.pageIdx > 0
            opacity: !pinyinIME._isLastPage ? 1.0 : 0.3
            Text {
                anchors.centerIn: parent
                text: "▶"
                font.pixelSize: 30
                color: nextTap.pressed ? "#666666" : "black"
            }
            MouseArea {
                id: nextTap
                anchors.fill: parent
                enabled: !pinyinIME._isLastPage
                onClicked: pinyinIME._rimeCall("/rime/page")
            }
        }
    }

    // 常驻整屏 Animation 快刷区。
    // 模式图 (EPScreenModeMap) 每变一次就要整屏重新合成一次 (日志实证), 所以关键
    // 不是"区域多小", 而是"变得多少次"。整屏覆盖 → 几何永不变, 只在中文输入会话
    // 开始/结束各变一次; 会话中无论候选框怎么伸缩移动、词怎么上屏, 都零抖动。
    // 代价: 输入期间全屏走 Animation 波形, 退出中文输入即恢复正常灰阶。
    // ★ 只跟"输入活动"而非"IME 激活": PDF/EPUB 查看器也是 SceneView + controller,
    // IME 会在阅读界面误判激活 —— 若快刷区跟 active 走, 看 PDF 时整屏挂上
    // Animation 波形, 彩色被压成灰 (用户实测"看 PDF 颜色全灰")。
    // 改为打字时开 (收到非空 preedit/commit 刷新活动时间), 停止输入 5 秒后关。
    // 代价: 每个输入会话头尾各一次全刷, 换来阅读场景完全不受干扰。
    Item {
        id: fastZone
        visible: pinyinIME.active && pinyinIME.isChineseMode && pinyinIME._inputBusy
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
                    model: pinyinIME.candidates.length
                    delegate: Item {
                            width: cText2.implicitWidth + 6
                        height: cText2.implicitHeight + 14
                        Text {
                            id: cText2
                            anchors.centerIn: parent
                            text: (index + 1) + "." + pinyinIME.candidates[index]
                            color: cTap2.pressed ? "#666666" : "black"
                            font.pixelSize: 28
                        }
                        MouseArea {
                            id: cTap2
                            anchors.fill: parent
                            onClicked: pinyinIME.selectCandidate(index)
                        }
                    }
                }

                Item {
                    width: 32
                    height: 38
                    visible: !pinyinIME._isLastPage || pinyinIME.pageIdx > 0
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
                        onClicked: pinyinIME._rimeCall("/rime/page?backward=1")
                    }
                }
                Item {
                    width: 32
                    height: 38
                    visible: !pinyinIME._isLastPage || pinyinIME.pageIdx > 0
                    anchors.verticalCenter: parent.verticalCenter
                    Text {
                        anchors.centerIn: parent
                        text: "›"
                        font.pixelSize: 28
                        color: !pinyinIME._isLastPage ? (nextTap2.pressed ? "#666666" : "black") : "#bbbbbb"
                    }
                    MouseArea {
                        id: nextTap2
                        anchors.fill: parent
                        enabled: !pinyinIME._isLastPage
                        onClicked: pinyinIME._rimeCall("/rime/page")
                    }
                }
            }
        }
    }
}
