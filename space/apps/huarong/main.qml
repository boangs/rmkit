// 华容道 — 「空间」内置应用 (从旧高级面板迁出, 逻辑原样)
import QtQuick
import QtQuick.Layouts
import device.ui.controls

Item {
    id: root
    property var space          // 外壳注入的 API 对象 (见 space/README.md)
    anchors.fill: parent

    // 4 列 × 5 行. 32 关古典布局, 曹操 (2x2) 从底部中央两格出口逃脱获胜.
    // 每个 piece: { id, name, color, r, c, w, h }
    // 棋盘字符串 5*4=20 char 编码:
    //   A 出现 4 次 -> 曹操 2x2  |  H/I/J/K/L/M 重复 2 次纵向 -> 1x2 竖将
    //   B/C/D/E/F/G 重复 2 次横向 -> 2x1 横将  |  N..[ -> 1x1 卒  |  @ -> 空
    property var _huarongPieces: []
    property bool _huarongOver: false
    property string _huarongStatus: ""
    property int _huarongMoves: 0
    property int _huarongLevel: 0   // 0..31
    property int _huarongMaxUnlocked: 0   // 已解锁到的最高关 index, 通关本关 +1
    readonly property var _huarongLevels: [
        { name: "\u6a2a\u5200\u7acb\u9a6c",     mini: 81, board: "HAAIHAAIJBBKJNOKP@@Q" },
        { name: "\u6307\u6325\u82e5\u5b9a",     mini: 70, board: "HAAIHAAINBBOJPQKJ@@K" },
        { name: "\u5c06\u62e5\u66f9\u8425",     mini: 72, board: "@AA@HAAIHJKINJKOBBPQ" },
        { name: "\u9f50\u5934\u5e76\u8fdb",     mini: 60, board: "HAAIHAAINOPQJBBKJ@@K" },
        { name: "\u5175\u5206\u4e09\u8def",     mini: 72, board: "NAAOHAAIHBBIJPQKJ@@K" },
        { name: "\u96e8\u58f0\u6dc5\u6ca5",     mini: 47, board: "HAANHAAOIBBJIK@JPK@Q" },
        { name: "\u5de6\u53f3\u5e03\u5175",     mini: 54, board: "NAAOPAAQHIJKHIJK@BB@" },
        { name: "\u6843\u82b1\u56ed\u4e2d",     mini: 70, board: "NAAOHAAIHJKIPJKQ@BB@" },
        { name: "\u4e00\u8def\u8fdb\u519b",     mini: 58, board: "HAANHAAOIJKPIJKQ@BB@" },
        { name: "\u4e00\u8def\u987a\u98ce",     mini: 39, board: "HAANHAAOIBBJIPKJ@QK@" },
        { name: "\u56f4\u800c\u4e0d\u6b7c",     mini: 62, board: "HAANHAAOIBBPIJKQ@JK@" },
        { name: "\u6377\u8db3\u5148\u767b",     mini: 32, board: "NAAOPAAQ@BB@HIJKHIJK" },
        { name: "\u63d2\u7fc5\u96be\u98de",     mini: 62, board: "HAANHAAOBBPQICCJI@@J" },
        { name: "\u5b88\u53e3\u5982\u74f6\u4e00", mini: 81, board: "HAAIHAAINJ@OPJ@QBBCC" },
        { name: "\u5b88\u53e3\u5982\u74f6\u4e8c", mini: 99, board: "NAAOHAAIHJ@IPJ@QBBCC" },
        { name: "\u53cc\u5c06\u6321\u8def",     mini: 73, board: "HAANHAAOIBBJICCJP@@Q" },
        { name: "\u6a2a\u9a6c\u5f53\u5173",     mini: 83, board: "HAAIHAAIBBCCNJ@OPJ@Q" },
        { name: "\u5c42\u5c42\u8bbe\u9632\u4e00", mini:102, board: "HAAIHAAINBBOPCCQ@DD@" },
        { name: "\u5c42\u5c42\u8bbe\u9632\u4e8c", mini:120, board: "NAAOHAAIHBBIPCCQ@DD@" },
        { name: "\u5175\u6321\u5c06\u963b",     mini: 87, board: "NAAHOAAHIBBPICCQ@DD@" },
        { name: "\u5835\u585e\u8981\u9053",     mini: 40, board: "NAAOPAAQHIBBHICC@DD@" },
        { name: "\u74ee\u4e2d\u4e4b\u9cd6",     mini:103, board: "HAAIHAAIBBCCNDDOP@@Q" },
        { name: "\u5c42\u5ce6\u53e0\u5d82",     mini: 98, board: "HAAIHAAINBBOCCDDP@@Q" },
        { name: "\u6c34\u6cc4\u4e0d\u901a",     mini: 79, board: "HAANHAAOBBCCDDEEP@@Q" },
        { name: "\u56db\u8def\u8fdb\u5175",     mini: 77, board: "NAAOPAAQH@BBH@CCDDEE" },
        { name: "\u5165\u5730\u65e0\u95e8",     mini: 87, board: "HAANHAAOPBBQCCDD@EE@" },
        { name: "\u52c7\u95ef\u4e94\u5173",     mini: 34, board: "NAAOPAAQBBCCDDEE@FF@" },
        { name: "\u4e00\u6a2a\u6700\u96be",     mini: 84, board: "HAANHAAIBBJIKOJPK@@Q" },
        { name: "\u4e00\u6a2a\u6700\u6613",     mini: 32, board: "NAAOHAAIHPQIJBBKJ@@K" },
        { name: "\u4e8c\u6a2a\u6700\u96be",     mini:103, board: "NAAHOAAHBBIJPQIJ@CC@" },
        { name: "\u4e8c\u6a2a\u6700\u6613",     mini: 56, board: "NAAHOAAHIJBBIJPQ@CC@" },
        { name: "\u56db\u6a2a\u6700\u6613",     mini: 69, board: "NAAOHAAPHQBBCCDD@EE@" }
    ]

    Component.onCompleted: { huarongReset(); huarongLoadProgress() }


    ColumnLayout {
        anchors.fill: parent
        spacing: 16

        // 状态栏: 关号 | 关名 | 最少步 | 步数 | 间距 | 上关 | 下关 | 重开
        RowLayout {
            Layout.fillWidth: true
            Layout.preferredHeight: 56
            spacing: 16

            Text {
                text: "\u7b2c " + (root._huarongLevel + 1) + " / 32"
                font.pixelSize: 24
                font.weight: Font.Medium
                verticalAlignment: Text.AlignVCenter
                Layout.alignment: Qt.AlignVCenter
            }

            Text {
                text: root._huarongOver
                    ? "\u80dc\u5229\uff01" + root._huarongLevels[root._huarongLevel].name
                    : root._huarongLevels[root._huarongLevel].name
                color: root._huarongOver ? "#c0392b" : "#1a0f04"
                font.pixelSize: 26
                font.weight: Font.Bold
                verticalAlignment: Text.AlignVCenter
                Layout.alignment: Qt.AlignVCenter
            }

            Item { Layout.fillWidth: true }

            Text {
                text: "\u5df2\u8d70: " + root._huarongMoves
                font.pixelSize: 24
                font.weight: Font.Medium
                verticalAlignment: Text.AlignVCenter
                horizontalAlignment: Text.AlignRight
                Layout.alignment: Qt.AlignVCenter
                Layout.preferredWidth: 140
            }

            Rectangle {
                Layout.preferredWidth: 72
                Layout.preferredHeight: 48
                Layout.leftMargin: 24
                Layout.alignment: Qt.AlignVCenter
                radius: 6
                readonly property bool enabledNav: root._huarongLevel > 0
                color: enabledNav ? "#fafafa" : "#e8e4de"
                border.color: enabledNav ? "#1a0f04" : "#888888"
                border.width: 1
                opacity: enabledNav ? 1.0 : 0.5
                Text {
                    anchors.centerIn: parent
                    text: "\u4e0a\u5173"
                    font.pixelSize: 22
                    color: parent.enabledNav ? "#1a0f04" : "#888888"
                }
                MouseArea {
                    anchors.fill: parent
                    enabled: parent.enabledNav
                    onClicked: root.huarongGoLevel(-1)
                }
            }

            Rectangle {
                Layout.preferredWidth: 72
                Layout.preferredHeight: 48
                Layout.alignment: Qt.AlignVCenter
                radius: 6
                readonly property bool enabledNav: root._huarongLevel < root._huarongMaxUnlocked
                color: enabledNav ? "#fafafa" : "#e8e4de"
                border.color: enabledNav ? "#1a0f04" : "#888888"
                border.width: 1
                opacity: enabledNav ? 1.0 : 0.5
                Text {
                    anchors.centerIn: parent
                    text: "\u4e0b\u5173"
                    font.pixelSize: 22
                    color: parent.enabledNav ? "#1a0f04" : "#888888"
                }
                MouseArea {
                    anchors.fill: parent
                    enabled: parent.enabledNav
                    onClicked: root.huarongGoLevel(1)
                }
            }

            IconButton {
                iconSource: "qrc:/ark/icons/restore"
                title: "\u91cd\u5f00"
                Layout.alignment: Qt.AlignVCenter
                onClicked: root.huarongReset()
            }
        }

        // 棋盘容器: 4 列 × 5 行, 底部中央两格为出口
        Item {
            Layout.fillWidth: true
            Layout.fillHeight: true

            Item {
                id: _huarongBoard
                property int huarongStep: Math.min(parent.width / 4, parent.height / 5.4)
                width: 4 * huarongStep
                height: 5 * huarongStep
                anchors.horizontalCenter: parent.horizontalCenter
                anchors.verticalCenter: parent.verticalCenter

                // 棋盘外框 (淡木色)
                Rectangle {
                    anchors.fill: parent
                    anchors.margins: -10
                    radius: 12
                    gradient: Gradient {
                        GradientStop { position: 0.0; color: "#f0e6d2" }
                        GradientStop { position: 0.5; color: "#e8dcc0" }
                        GradientStop { position: 1.0; color: "#dccfac" }
                    }
                    border.color: "#a07848"
                    border.width: 2
                }

                // 棋盘内层 (与外框同色, 一体感)
                Rectangle {
                    id: _huarongInner
                    anchors.fill: parent
                    radius: 4
                    gradient: Gradient {
                        GradientStop { position: 0.0; color: "#f0e6d2" }
                        GradientStop { position: 1.0; color: "#dccfac" }
                    }
                    border.color: "#a07848"
                    border.width: 1
                    clip: true

                    // 横向木纹年轮 (8 条若隐若现的细线)
                    Repeater {
                        model: 8
                        delegate: Rectangle {
                            anchors.left: parent.left
                            anchors.right: parent.right
                            y: (index + 1) * (_huarongInner.height / 9) + (index % 2 === 0 ? -2 : 3)
                            height: 1
                            color: "#8a6a3a"
                            opacity: index % 3 === 0 ? 0.18 : 0.10
                        }
                    }
                }

                // 空格虚线指示 (5×4 = 20 格遍历, 仅在空格处显示)
                Repeater {
                    model: 20
                    delegate: Rectangle {
                        property int row: Math.floor(index / 4)
                        property int col: index % 4
                        visible: root._huarongPieces.length > 0 && root.huarongIsEmpty(row, col)
                        x: col * _huarongBoard.huarongStep + 8
                        y: row * _huarongBoard.huarongStep + 8
                        width: _huarongBoard.huarongStep - 16
                        height: _huarongBoard.huarongStep - 16
                        color: "transparent"
                        border.color: "#fff2c0"
                        border.width: 2
                        radius: 6
                        opacity: 0.55
                    }
                }

                // 4 角铜钉装饰
                Repeater {
                    model: 4
                    delegate: Rectangle {
                        x: index % 2 === 0 ? -4 : _huarongBoard.width - 12
                        y: index < 2 ? -4 : _huarongBoard.height - 12
                        width: 16
                        height: 16
                        radius: 8
                        gradient: Gradient {
                            GradientStop { position: 0.0; color: "#e8c473" }
                            GradientStop { position: 1.0; color: "#7a5a20" }
                        }
                        border.color: "#1a0f04"
                        border.width: 1
                        Rectangle {
                            anchors.centerIn: parent
                            width: 5; height: 5; radius: 2.5
                            color: "#fff2c0"
                            opacity: 0.7
                            anchors.verticalCenterOffset: -2
                            anchors.horizontalCenterOffset: -2
                        }
                    }
                }

                // 出口拱门 (底部中央 2 格外)
                Rectangle {
                    x: _huarongBoard.huarongStep - 2
                    y: _huarongBoard.height + 4
                    width: _huarongBoard.huarongStep * 2 + 4
                    height: 32
                    radius: 6
                    gradient: Gradient {
                        GradientStop { position: 0.0; color: "#e25a3a" }
                        GradientStop { position: 0.5; color: "#c0392b" }
                        GradientStop { position: 1.0; color: "#7d1f12" }
                    }
                    border.color: "#4a0d05"
                    border.width: 2
                    Text {
                        anchors.centerIn: parent
                        text: "\u51fa  \u53e3"
                        color: "#fff2c0"
                        font.pixelSize: 22
                        font.weight: Font.Bold
                        font.letterSpacing: 4
                        style: Text.Outline
                        styleColor: "#4a0d05"
                    }
                }

                // 棋子
                Repeater {
                    model: root._huarongPieces
                    delegate: Item {
                        // delegate 满格 (严格 w:h 比例), padding 在 Image 上按比例做
                        x: modelData.c * _huarongBoard.huarongStep
                        y: modelData.r * _huarongBoard.huarongStep
                        width: modelData.w * _huarongBoard.huarongStep
                        height: modelData.h * _huarongBoard.huarongStep

                        // 棋子主体: 有 icon 时 PNG 充满, 无 icon 时渐变 + 描边 + 高光 + 大字
                        // (拆成两个互斥 visible 的容器, 避免 QML 三元里 inline Gradient 的非法语法)
                        Image {
                            visible: modelData.icon !== ""
                            anchors.fill: parent
                            // 5px 等比 padding: 短边 5, 长边 5 * (长/短), 保证 inner 区域严格 w:h, fit 不留白
                            anchors.leftMargin: 5
                            anchors.rightMargin: 5
                            anchors.topMargin: 5 * modelData.h / modelData.w
                            anchors.bottomMargin: 5 * modelData.h / modelData.w
                            fillMode: Image.PreserveAspectFit
                            source: modelData.icon === "" ? "" :
                                    "file:///home/root/xovi/exthome/qt-resource-rebuilder/chess/" + modelData.icon + ".png"
                            sourceSize.width: 512
                            sourceSize.height: 512
                            smooth: true
                            cache: false
                        }

                        Rectangle {
                            visible: modelData.icon === ""
                            anchors.fill: parent
                            radius: 8
                            border.color: "#1a0f04"
                            border.width: 2
                            gradient: Gradient {
                                GradientStop { position: 0.0; color: Qt.lighter(modelData.color, 1.35) }
                                GradientStop { position: 0.55; color: modelData.color }
                                GradientStop { position: 1.0; color: Qt.darker(modelData.color, 1.3) }
                            }

                            // 内描边高亮
                            Rectangle {
                                anchors.fill: parent
                                anchors.margins: 3
                                radius: 6
                                color: "transparent"
                                border.color: "#60ffffff"
                                border.width: 1
                            }

                            // 顶部高光条
                            Rectangle {
                                anchors.left: parent.left
                                anchors.right: parent.right
                                anchors.top: parent.top
                                anchors.leftMargin: 6
                                anchors.rightMargin: 6
                                anchors.topMargin: 5
                                height: parent.height * 0.22
                                radius: 5
                                opacity: 0.45
                                gradient: Gradient {
                                    GradientStop { position: 0.0; color: "#ffffff" }
                                    GradientStop { position: 1.0; color: "#00ffffff" }
                                }
                            }

                            // 兵的名字大字居中
                            Text {
                                anchors.centerIn: parent
                                text: modelData.name
                                font.pixelSize: 46
                                font.weight: Font.Black
                                font.family: "Noto Serif CJK SC"
                                color: "#fff5d9"
                                style: Text.Outline
                                styleColor: "#1a0f04"
                            }
                        }

                        MouseArea {
                            anchors.fill: parent
                            property real startX: 0
                            property real startY: 0
                            onPressed: (mouse) => { startX = mouse.x; startY = mouse.y }
                            onReleased: (mouse) => {
                                var dx = mouse.x - startX
                                var dy = mouse.y - startY
                                var ax = Math.abs(dx)
                                var ay = Math.abs(dy)
                                var threshold = _huarongBoard.huarongStep / 6
                                if (Math.max(ax, ay) < threshold) {
                                    root.huarongAutoMove(modelData.id)
                                    return
                                }
                                var dr = 0, dc = 0
                                if (ax > ay) dc = (dx > 0) ? 1 : -1
                                else dr = (dy > 0) ? 1 : -1
                                root.huarongMove(modelData.id, dr, dc)
                            }
                        }
                    }
                }
            }
        }
    }

    // ─── 华容道 JS ─────────────────────────────────────────────
    function huarongParseBoard(s) {
        // 从 5*4=20 字符的 board 字符串构造 pieces 数组
        // 名字/图标/颜色按棋型动态分配:
        //   2x2 -> 曹 (固定)  |  1x2 竖 -> 张/赵/马/黄 循环  |  2x1 横 -> 关/张/赵/马 循环  |  1x1 -> 卒
        var verNames  = ["\u5f20", "\u8d75", "\u9a6c", "\u9ec4"]
        var verIcons  = ["hr-zhang", "hr-zhao", "hr-ma", "hr-huang"]
        var verColors = ["#27ae60", "#2980b9", "#e67e22", "#8e44ad"]
        // 横将图源只有关羽是 2:1 横版, 其余角色都是 1:2 竖版,
        // 用竖图填 2x1 横格 PreserveAspectFit 会缩成卒大小, 因此横将统一用 hr-guan.
        var horNames  = ["\u5173", "\u5173", "\u5173", "\u5173"]
        var horIcons  = ["hr-guan", "hr-guan", "hr-guan", "hr-guan"]
        var horColors = ["#f1c40f", "#16a085", "#d35400", "#34495e"]
        var bingIcons = ["hr-bing1", "hr-bing2", "hr-bing3", "hr-bing4"]
        var visited = []
        for (var i = 0; i < 20; i++) visited.push(false)
        var pieces = []
        var nextId = 0
        var verIdx = 0, horIdx = 0, bingIdx = 0
        for (var r = 0; r < 5; r++) {
            for (var c = 0; c < 4; c++) {
                var idx = r * 4 + c
                if (visited[idx]) continue
                var ch = s.charAt(idx)
                if (ch === "@") { visited[idx] = true; continue }
                if (ch === "A") {
                    // 曹操 2x2: 占 idx, idx+1, idx+4, idx+5
                    pieces.push({ id: nextId++, name: "\u66f9", color: "#e74c3c",
                                  icon: "hr-cao", r: r, c: c, w: 2, h: 2 })
                    visited[idx] = visited[idx+1] = visited[idx+4] = visited[idx+5] = true
                    continue
                }
                // 检测竖 (向下) 还是横 (向右)
                if (r + 1 < 5 && s.charAt(idx + 4) === ch) {
                    // 1x2 竖
                    var vi = verIdx % 4
                    pieces.push({ id: nextId++, name: verNames[vi], color: verColors[vi],
                                  icon: verIcons[vi], r: r, c: c, w: 1, h: 2 })
                    visited[idx] = visited[idx+4] = true
                    verIdx++
                    continue
                }
                if (c + 1 < 4 && s.charAt(idx + 1) === ch) {
                    // 2x1 横
                    var hi = horIdx % 4
                    pieces.push({ id: nextId++, name: horNames[hi], color: horColors[hi],
                                  icon: horIcons[hi], r: r, c: c, w: 2, h: 1 })
                    visited[idx] = visited[idx+1] = true
                    horIdx++
                    continue
                }
                // 1x1 卒
                var bi = bingIdx % 4
                pieces.push({ id: nextId++, name: "\u5352", color: "#bdc3c7",
                              icon: bingIcons[bi], r: r, c: c, w: 1, h: 1 })
                visited[idx] = true
                bingIdx++
            }
        }
        return pieces
    }

    function huarongReset() {
        var lv = _huarongLevels[_huarongLevel]
        _huarongPieces = huarongParseBoard(lv.board)
        _huarongOver = false
        _huarongMoves = 0
        _huarongStatus = "\u7b2c " + (_huarongLevel + 1) + " / 32 \u5173 \u00b7 " + lv.name +
                         " \u00b7 \u6700\u5c11 " + lv.mini + " \u6b65"
    }

    function huarongGoLevel(delta) {
        var n = _huarongLevels.length
        _huarongLevel = (_huarongLevel + delta + n) % n
        huarongReset()
        huarongSaveProgress()
    }

    function huarongIsEmpty(r, c) {
        return huarongOccupy(_huarongPieces, r, c, -1) === -1
    }

    function huarongAutoMove(pieceId) {
        var dirs = [[-1,0],[1,0],[0,-1],[0,1]]
        var found = []
        for (var i = 0; i < dirs.length; i++) {
            if (huarongCanMove(pieceId, dirs[i][0], dirs[i][1])) {
                found.push(dirs[i])
            }
        }
        if (found.length === 1) huarongMove(pieceId, found[0][0], found[0][1])
    }

    function huarongOccupy(pieces, r, c, ignoreId) {
        for (var i = 0; i < pieces.length; i++) {
            var p = pieces[i]
            if (p.id === ignoreId) continue
            if (r >= p.r && r < p.r + p.h && c >= p.c && c < p.c + p.w) return p.id
        }
        return -1
    }

    function huarongCanMove(pieceId, dr, dc) {
        var pieces = _huarongPieces
        var p = null
        for (var i = 0; i < pieces.length; i++) if (pieces[i].id === pieceId) { p = pieces[i]; break }
        if (!p) return false
        var nr = p.r + dr
        var nc = p.c + dc
        if (nr < 0 || nc < 0) return false
        if (nr + p.h > 5 || nc + p.w > 4) return false
        // 新位置覆盖的每一格不能被其他棋子占用
        for (var rr = nr; rr < nr + p.h; rr++) {
            for (var cc = nc; cc < nc + p.w; cc++) {
                if (huarongOccupy(pieces, rr, cc, pieceId) !== -1) return false
            }
        }
        return true
    }

    function huarongMove(pieceId, dr, dc) {
        if (_huarongOver) return
        if (!huarongCanMove(pieceId, dr, dc)) return
        var newPieces = []
        for (var i = 0; i < _huarongPieces.length; i++) {
            var p = _huarongPieces[i]
            if (p.id === pieceId) {
                newPieces.push({ id: p.id, name: p.name, color: p.color, icon: p.icon,
                                 r: p.r + dr, c: p.c + dc, w: p.w, h: p.h })
            } else {
                newPieces.push(p)
            }
        }
        _huarongPieces = newPieces
        _huarongMoves += 1
        // 胜利: 真曹操 (2x2 棋子) 到达 r=3 c=1 (占满最底两行中央 2x2)
        for (var k = 0; k < newPieces.length; k++) {
            var pk = newPieces[k]
            if (pk.w === 2 && pk.h === 2 && pk.r === 3 && pk.c === 1) {
                _huarongOver = true
                _huarongStatus = "\u80dc\u5229\uff01\u66f9\u64cd\u9003\u8131\u6210\u529f"
                if (_huarongLevel + 1 > _huarongMaxUnlocked && _huarongLevel + 1 < _huarongLevels.length) {
                    _huarongMaxUnlocked = _huarongLevel + 1
                    huarongSaveProgress()
                }
                break
            }
        }
    }

    // 进度持久化: 写到 /home/root/.local/share/rmkit-cn/progress.json
    // file:// XHR 写需要 drop-in 设 QML_XHR_ALLOW_FILE_WRITE=1
    readonly property string _huarongProgressPath:
        "file:///home/root/.local/share/rmkit-cn/progress.json"
    function huarongLoadProgress() {
        var x = new XMLHttpRequest()
        x.open("GET", _huarongProgressPath)
        x.onreadystatechange = function() {
            if (x.readyState !== XMLHttpRequest.DONE) return
            try {
                var data = JSON.parse(x.responseText)
                if (typeof data.huarongMaxUnlocked === "number") {
                    _huarongMaxUnlocked = data.huarongMaxUnlocked
                }
                if (typeof data.huarongLevel === "number" &&
                    data.huarongLevel >= 0 &&
                    data.huarongLevel < _huarongLevels.length) {
                    _huarongLevel = data.huarongLevel
                    huarongReset()
                }
            } catch (e) {}
        }
        x.send()
    }
    function huarongSaveProgress() {
        var x = new XMLHttpRequest()
        x.open("PUT", _huarongProgressPath)
        x.send(JSON.stringify({
            huarongMaxUnlocked: _huarongMaxUnlocked,
            huarongLevel: _huarongLevel
        }))
    }
}
