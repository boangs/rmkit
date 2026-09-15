// 五子棋 — 「空间」内置应用 (从旧高级面板 page 3 迁出, 逻辑原样)
import QtQuick
import QtQuick.Layouts
import device.ui.controls

Item {
    id: root
    property var space          // 外壳注入的 API 对象 (见 space/README.md)
    anchors.fill: parent

    // 15x15 棋盘, 0=空, 1=黑, 2=白. 玩家黑先, AI 持白.
    property var _gomokuBoard: []
    property int _gomokuPlayer: 1
    property bool _gomokuOver: false
    property string _gomokuStatus: ""
    property bool _gomokuVsAi: true
    property var _gomokuLast: ({row: -1, col: -1})

    Component.onCompleted: gomokuReset()

        ColumnLayout {
            anchors.fill: parent
            spacing: 16

            // 状态栏: 状态文字 | 人机单选 | 双人单选 | 重开
            RowLayout {
                Layout.fillWidth: true
                Layout.preferredHeight: 56
                spacing: 32

                Text {
                    text: root._gomokuStatus
                    font.pixelSize: 28
                    elide: Text.ElideRight
                    verticalAlignment: Text.AlignVCenter
                    Layout.fillWidth: true
                    Layout.alignment: Qt.AlignVCenter
                }

                // 人机
                Item {
                    Layout.preferredWidth: _gomokuRadioVsAi.implicitWidth
                    Layout.preferredHeight: 56
                    Layout.alignment: Qt.AlignVCenter
                    RowLayout {
                        id: _gomokuRadioVsAi
                        anchors.fill: parent
                        spacing: 10
                        Rectangle {
                            Layout.preferredWidth: 28
                            Layout.preferredHeight: 28
                            Layout.alignment: Qt.AlignVCenter
                            radius: 14
                            border.width: 2
                            border.color: "black"
                            color: "white"
                            Rectangle {
                                anchors.centerIn: parent
                                width: 16; height: 16
                                radius: 8
                                color: "black"
                                visible: root._gomokuVsAi
                            }
                        }
                        Text {
                            text: "\u4eba\u673a"
                            font.pixelSize: 26
                            verticalAlignment: Text.AlignVCenter
                            Layout.alignment: Qt.AlignVCenter
                        }
                    }
                    MouseArea {
                        anchors.fill: parent
                        onClicked: {
                            if (!root._gomokuVsAi) {
                                root._gomokuVsAi = true
                                root.gomokuReset()
                            }
                        }
                    }
                }

                // 双人
                Item {
                    Layout.preferredWidth: _gomokuRadioPvP.implicitWidth
                    Layout.preferredHeight: 56
                    Layout.alignment: Qt.AlignVCenter
                    RowLayout {
                        id: _gomokuRadioPvP
                        anchors.fill: parent
                        spacing: 10
                        Rectangle {
                            Layout.preferredWidth: 28
                            Layout.preferredHeight: 28
                            Layout.alignment: Qt.AlignVCenter
                            radius: 14
                            border.width: 2
                            border.color: "black"
                            color: "white"
                            Rectangle {
                                anchors.centerIn: parent
                                width: 16; height: 16
                                radius: 8
                                color: "black"
                                visible: !root._gomokuVsAi
                            }
                        }
                        Text {
                            text: "\u53cc\u4eba"
                            font.pixelSize: 26
                            verticalAlignment: Text.AlignVCenter
                            Layout.alignment: Qt.AlignVCenter
                        }
                    }
                    MouseArea {
                        anchors.fill: parent
                        onClicked: {
                            if (root._gomokuVsAi) {
                                root._gomokuVsAi = false
                                root.gomokuReset()
                            }
                        }
                    }
                }

                IconButton {
                    iconSource: "qrc:/ark/icons/restore"
                    title: "\u91cd\u5f00"
                    Layout.alignment: Qt.AlignVCenter
                    onClicked: root.gomokuReset()
                }
            }

            // 棋盘 (Canvas) — 占满状态栏下面剩余空间, 居中放置
            Item {
                Layout.fillWidth: true
                Layout.fillHeight: true

                Canvas {
                    id: _gomokuCanvas
                    width: Math.min(parent.width, parent.height)
                    height: width
                    anchors.centerIn: parent
                    onWidthChanged: requestPaint()
                    // 棋盘几何: 15 个交叉点, 每格间距 step, 边距 margin
                    property int gomokuMargin: Math.max(24, Math.round(width * 0.04))
                    property int gomokuGrid: 15
                    property real gomokuStep: (width - 2 * gomokuMargin) / (gomokuGrid - 1)

                    onPaint: root.gomokuDraw(_gomokuCanvas)

                    MouseArea {
                        anchors.fill: parent
                        onClicked: (mouse) => {
                            var step = parent.gomokuStep
                            var m = parent.gomokuMargin
                            var col = Math.round((mouse.x - m) / step)
                            var row = Math.round((mouse.y - m) / step)
                            root.gomokuTap(row, col)
                        }
                    }
                }
            }
        }

    // ─── 五子棋逻辑 ─────────────────────────────────────────────
    function gomokuReset() {
        var n = 15
        var b = []
        for (var r = 0; r < n; r++) {
            var row = []
            for (var c = 0; c < n; c++) row.push(0)
            b.push(row)
        }
        root._gomokuBoard = b
        root._gomokuPlayer = 1
        root._gomokuOver = false
        root._gomokuLast = ({row: -1, col: -1})
        root._gomokuStatus = "\u9ed1\u68cb\u843d\u5b50"
        if (_gomokuCanvas) _gomokuCanvas.requestPaint()
    }

    function gomokuTap(row, col) {
        if (root._gomokuOver) return
        var n = 15
        if (row < 0 || row >= n || col < 0 || col >= n) return
        var board = root._gomokuBoard
        if (board[row][col] !== 0) return
        // 人机模式下只允许在黑棋(玩家)回合落子
        if (root._gomokuVsAi && root._gomokuPlayer !== 1) return

        gomokuPlace(row, col, root._gomokuPlayer)

        if (!root._gomokuOver && root._gomokuVsAi
            && root._gomokuPlayer === 2) {
            root._gomokuStatus = "AI \u601d\u8003\u4e2d..."
            // 让 UI 刷出"思考中"再算 AI
            _gomokuAiTimer.start()
        }
    }

    function gomokuPlace(row, col, player) {
        var board = root._gomokuBoard
        board[row][col] = player
        root._gomokuBoard = board  // 触发 binding (虽然 var 改了原数组)
        root._gomokuLast = ({row: row, col: col})

        if (gomokuCheckWin(row, col, player)) {
            root._gomokuOver = true
            root._gomokuStatus =
                (player === 1 ? "\u9ed1\u68cb" : "\u767d\u68cb") + "\u80dc\u5229"
        } else if (gomokuIsFull()) {
            root._gomokuOver = true
            root._gomokuStatus = "\u548c\u68cb"
        } else {
            root._gomokuPlayer = (player === 1 ? 2 : 1)
            root._gomokuStatus =
                (root._gomokuPlayer === 1 ? "\u9ed1\u68cb" : "\u767d\u68cb")
                + "\u843d\u5b50"
        }
        if (_gomokuCanvas) _gomokuCanvas.requestPaint()
    }

    function gomokuIsFull() {
        var board = root._gomokuBoard
        for (var r = 0; r < 15; r++)
            for (var c = 0; c < 15; c++)
                if (board[r][c] === 0) return false
        return true
    }

    // 检查 (row,col) 落子后是否形成 5 连珠
    function gomokuCheckWin(row, col, player) {
        var board = root._gomokuBoard
        var dirs = [[0,1], [1,0], [1,1], [1,-1]]
        for (var d = 0; d < 4; d++) {
            var dr = dirs[d][0], dc = dirs[d][1]
            var cnt = 1
            var rr = row + dr, cc = col + dc
            while (rr >= 0 && rr < 15 && cc >= 0 && cc < 15 && board[rr][cc] === player) {
                cnt++; rr += dr; cc += dc
            }
            rr = row - dr; cc = col - dc
            while (rr >= 0 && rr < 15 && cc >= 0 && cc < 15 && board[rr][cc] === player) {
                cnt++; rr -= dr; cc -= dc
            }
            if (cnt >= 5) return true
        }
        return false
    }

    // AI: 评估每个候选空位的"威胁分", 进攻 + 防守加权选最高
    function gomokuAiPlay() {
        var board = root._gomokuBoard
        var best = null
        var bestScore = -1
        // 只考虑距离已有棋子 ≤ 2 的空位 (开局空棋盘下中央)
        var hasAny = false
        for (var r = 0; r < 15 && !hasAny; r++)
            for (var c = 0; c < 15 && !hasAny; c++)
                if (board[r][c] !== 0) hasAny = true
        if (!hasAny) {
            gomokuPlace(7, 7, 2)
            return
        }
        for (var r = 0; r < 15; r++) {
            for (var c = 0; c < 15; c++) {
                if (board[r][c] !== 0) continue
                if (!gomokuNearStone(r, c)) continue
                var attack = gomokuScore(r, c, 2)
                var defend = gomokuScore(r, c, 1)
                // 进攻略高于纯防守; 但对手活四/冲四时防守优先
                var score = attack * 1.05 + defend
                if (score > bestScore) {
                    bestScore = score
                    best = {row: r, col: c}
                }
            }
        }
        if (best) gomokuPlace(best.row, best.col, 2)
    }

    function gomokuNearStone(row, col) {
        var board = root._gomokuBoard
        for (var dr = -2; dr <= 2; dr++) {
            for (var dc = -2; dc <= 2; dc++) {
                if (dr === 0 && dc === 0) continue
                var r = row + dr, c = col + dc
                if (r < 0 || r >= 15 || c < 0 || c >= 15) continue
                if (board[r][c] !== 0) return true
            }
        }
        return false
    }

    // 模拟 (row,col) 落 player 子, 计算四个方向最大威胁评分
    function gomokuScore(row, col, player) {
        var board = root._gomokuBoard
        var dirs = [[0,1], [1,0], [1,1], [1,-1]]
        var total = 0
        for (var d = 0; d < 4; d++) {
            var dr = dirs[d][0], dc = dirs[d][1]
            // 数当前子加上同色连子, 以及两端是否被堵
            var cnt = 1
            var openA = 0, openB = 0
            var rr = row + dr, cc = col + dc
            while (rr >= 0 && rr < 15 && cc >= 0 && cc < 15 && board[rr][cc] === player) {
                cnt++; rr += dr; cc += dc
            }
            if (rr >= 0 && rr < 15 && cc >= 0 && cc < 15 && board[rr][cc] === 0) openA = 1
            rr = row - dr; cc = col - dc
            while (rr >= 0 && rr < 15 && cc >= 0 && cc < 15 && board[rr][cc] === player) {
                cnt++; rr -= dr; cc -= dc
            }
            if (rr >= 0 && rr < 15 && cc >= 0 && cc < 15 && board[rr][cc] === 0) openB = 1
            var open = openA + openB
            // 评分: 5 连最高, 然后活四/冲四/活三/眠三/活二
            var s = 0
            if (cnt >= 5) s = 1000000
            else if (cnt === 4) s = (open === 2 ? 50000 : (open === 1 ? 5000 : 0))
            else if (cnt === 3) s = (open === 2 ? 2000 : (open === 1 ? 200 : 0))
            else if (cnt === 2) s = (open === 2 ? 200 : (open === 1 ? 20 : 0))
            else s = open
            total += s
        }
        return total
    }

    // Canvas 绘制
    function gomokuDraw(canvas) {
        var ctx = canvas.getContext("2d")
        var w = canvas.width, h = canvas.height
        var m = canvas.gomokuMargin
        var step = canvas.gomokuStep
        var n = canvas.gomokuGrid

        // 背景: 木色
        ctx.fillStyle = "#e6c98e"
        ctx.fillRect(0, 0, w, h)

        // 网格线
        ctx.strokeStyle = "#000000"
        ctx.lineWidth = 1
        ctx.beginPath()
        for (var i = 0; i < n; i++) {
            ctx.moveTo(m, m + i * step)
            ctx.lineTo(m + (n - 1) * step, m + i * step)
            ctx.moveTo(m + i * step, m)
            ctx.lineTo(m + i * step, m + (n - 1) * step)
        }
        ctx.stroke()

        // 星位 (天元 + 4 角星)
        ctx.fillStyle = "#000000"
        var stars = [[7,7],[3,3],[3,11],[11,3],[11,11]]
        for (var s = 0; s < stars.length; s++) {
            ctx.beginPath()
            ctx.arc(m + stars[s][1] * step, m + stars[s][0] * step, 4, 0, Math.PI * 2)
            ctx.fill()
        }

        // 棋子
        var board = root._gomokuBoard
        if (!board || board.length === 0) return
        var radius = step * 0.42
        for (var r = 0; r < n; r++) {
            for (var c = 0; c < n; c++) {
                var v = board[r][c]
                if (v === 0) continue
                var x = m + c * step
                var y = m + r * step
                ctx.beginPath()
                ctx.arc(x, y, radius, 0, Math.PI * 2)
                if (v === 1) {
                    ctx.fillStyle = "#000000"
                    ctx.fill()
                } else {
                    ctx.fillStyle = "#ffffff"
                    ctx.fill()
                    ctx.strokeStyle = "#000000"
                    ctx.lineWidth = 1.5
                    ctx.stroke()
                }
            }
        }

        // 标记最近落子 (小红框)
        var last = root._gomokuLast
        if (last && last.row >= 0) {
            var lx = m + last.col * step
            var ly = m + last.row * step
            ctx.strokeStyle = "#cc0000"
            ctx.lineWidth = 2
            ctx.strokeRect(lx - radius, ly - radius, radius * 2, radius * 2)
        }
    }

    Timer {
        id: _gomokuAiTimer
        interval: 60
        repeat: false
        onTriggered: root.gomokuAiPlay()
    }
}
