// 国际象棋 — 「空间」内置应用 (从旧高级面板迁出, 逻辑原样)
import QtQuick
import QtQuick.Layouts
import device.ui.controls

Item {
    id: root
    property var space          // 外壳注入的 API 对象 (见 space/README.md)
    anchors.fill: parent

    // 8x8 棋盘. 棋子编码: 0=空, 正=白(玩家在下), 负=黑(AI 在上)
    // 1/2/3/4/5/6 = 兵/马/象/车/后/王
    property var _chessBoard: []
    property int _chessTurn: 1   // 1=白先, -1=黑
    property bool _chessOver: false
    property string _chessStatus: ""
    property bool _chessVsAi: true
    property var _chessSel: ({row: -1, col: -1})    // 当前选中己方子, -1 = 未选
    property var _chessMoves: []                     // 选中子的合法落点 [{row,col}]
    property var _chessLast: ({fr: -1, fc: -1, tr: -1, tc: -1})  // 最近一手

    Component.onCompleted: chessReset()


    ColumnLayout {
        anchors.fill: parent
        spacing: 16

        // 状态栏: 状态文字 | 人机单选 | 双人单选 | 重开
        RowLayout {
            Layout.fillWidth: true
            Layout.preferredHeight: 56
            spacing: 32

            Text {
                text: root._chessStatus
                font.pixelSize: 28
                elide: Text.ElideRight
                verticalAlignment: Text.AlignVCenter
                Layout.fillWidth: true
                Layout.alignment: Qt.AlignVCenter
            }

            // 人机
            Item {
                Layout.preferredWidth: _chessRadioVsAi.implicitWidth
                Layout.preferredHeight: 56
                Layout.alignment: Qt.AlignVCenter
                RowLayout {
                    id: _chessRadioVsAi
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
                            visible: root._chessVsAi
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
                        if (!root._chessVsAi) {
                            root._chessVsAi = true
                            root.chessReset()
                        }
                    }
                }
            }

            // 双人
            Item {
                Layout.preferredWidth: _chessRadioPvP.implicitWidth
                Layout.preferredHeight: 56
                Layout.alignment: Qt.AlignVCenter
                RowLayout {
                    id: _chessRadioPvP
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
                            visible: !root._chessVsAi
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
                        if (root._chessVsAi) {
                            root._chessVsAi = false
                            root.chessReset()
                        }
                    }
                }
            }

            IconButton {
                iconSource: "qrc:/ark/icons/restore"
                title: "\u91cd\u5f00"
                Layout.alignment: Qt.AlignVCenter
                onClicked: root.chessReset()
            }
        }

        // 棋盘 Canvas (8x8 格)
        Item {
            Layout.fillWidth: true
            Layout.fillHeight: true

            Canvas {
                id: _chessCanvas
                width: Math.min(parent.width, parent.height)
                height: width
                anchors.centerIn: parent
                onWidthChanged: requestPaint()
                property int chessGrid: 8
                property real chessStep: width / chessGrid
                property int chessImagesReady: 0

                Component.onCompleted: {
                    var paths = ["wK","wQ","wR","wB","wN","wP","bK","bQ","bR","bB","bN","bP"]
                    for (var i = 0; i < paths.length; i++) {
                        loadImage("file:///home/root/xovi/exthome/qt-resource-rebuilder/chess/" + paths[i] + ".svg")
                    }
                }
                onImageLoaded: {
                    chessImagesReady += 1
                    requestPaint()
                }
                onPaint: root.chessDraw(_chessCanvas)

                MouseArea {
                    anchors.fill: parent
                    onClicked: (mouse) => {
                        var step = parent.chessStep
                        var col = Math.floor(mouse.x / step)
                        var row = Math.floor(mouse.y / step)
                        root.chessTap(row, col)
                    }
                }
            }
        }
    }

    // ─── 国际象棋 JS ─────────────────────────────────────────
    function chessReset() {
        var b = []
        for (var r = 0; r < 8; r++) {
            b.push([0, 0, 0, 0, 0, 0, 0, 0])
        }
        var back = [4, 2, 3, 5, 6, 3, 2, 4]
        for (var c = 0; c < 8; c++) {
            b[0][c] = -back[c]
            b[1][c] = -1
            b[6][c] = 1
            b[7][c] = back[c]
        }
        _chessBoard = b
        _chessTurn = 1
        _chessOver = false
        _chessSel = {row: -1, col: -1}
        _chessMoves = []
        _chessLast = {fr: -1, fc: -1, tr: -1, tc: -1}
        _chessStatus = _chessVsAi ? "\u767d\u65b9 (\u4f60) \u8d70" : "\u767d\u65b9\u8d70"
        if (typeof _chessCanvas !== "undefined" && _chessCanvas) _chessCanvas.requestPaint()
    }

    function chessValue(piece) {
        var t = Math.abs(piece)
        if (t === 1) return 1
        if (t === 2) return 3
        if (t === 3) return 3
        if (t === 4) return 5
        if (t === 5) return 9
        if (t === 6) return 1000
        return 0
    }

    function chessCopyBoard(board) {
        var nb = []
        for (var r = 0; r < 8; r++) nb.push(board[r].slice())
        return nb
    }

    function chessApplyMove(board, fr, fc, tr, tc) {
        var p = board[fr][fc]
        board[tr][tc] = p
        board[fr][fc] = 0
        // 兵到底自动升后
        if (Math.abs(p) === 1) {
            if ((p > 0 && tr === 0) || (p < 0 && tr === 7)) {
                board[tr][tc] = p > 0 ? 5 : -5
            }
        }
    }

    // 伪合法走法 (不验证走完后己王是否被将)
    function chessPseudoMoves(board, r, c) {
        var p = board[r][c]
        if (p === 0) return []
        var t = Math.abs(p)
        var moves = []

        function inb(rr, cc) { return rr >= 0 && rr < 8 && cc >= 0 && cc < 8 }
        function tryStep(rr, cc) {
            if (!inb(rr, cc)) return
            var q = board[rr][cc]
            if (q === 0 || (q > 0) !== (p > 0)) moves.push({row: rr, col: cc})
        }
        function ray(dr, dc) {
            var rr = r + dr, cc = c + dc
            while (inb(rr, cc)) {
                var q = board[rr][cc]
                if (q === 0) {
                    moves.push({row: rr, col: cc})
                    rr += dr; cc += dc
                    continue
                }
                if ((q > 0) !== (p > 0)) moves.push({row: rr, col: cc})
                return
            }
        }

        if (t === 1) {
            var dir = p > 0 ? -1 : 1
            var startRow = p > 0 ? 6 : 1
            if (inb(r + dir, c) && board[r + dir][c] === 0) {
                moves.push({row: r + dir, col: c})
                if (r === startRow && board[r + 2 * dir][c] === 0) {
                    moves.push({row: r + 2 * dir, col: c})
                }
            }
            var sides = [-1, 1]
            for (var i = 0; i < 2; i++) {
                var nr = r + dir, nc = c + sides[i]
                if (inb(nr, nc)) {
                    var q = board[nr][nc]
                    if (q !== 0 && (q > 0) !== (p > 0)) moves.push({row: nr, col: nc})
                }
            }
        } else if (t === 2) {
            var deltas = [[-2,-1],[-2,1],[-1,-2],[-1,2],[1,-2],[1,2],[2,-1],[2,1]]
            for (var i = 0; i < 8; i++) tryStep(r + deltas[i][0], c + deltas[i][1])
        } else if (t === 3) {
            ray(-1,-1); ray(-1,1); ray(1,-1); ray(1,1)
        } else if (t === 4) {
            ray(-1,0); ray(1,0); ray(0,-1); ray(0,1)
        } else if (t === 5) {
            ray(-1,-1); ray(-1,1); ray(1,-1); ray(1,1)
            ray(-1,0); ray(1,0); ray(0,-1); ray(0,1)
        } else if (t === 6) {
            for (var dr = -1; dr <= 1; dr++) {
                for (var dc = -1; dc <= 1; dc++) {
                    if (dr === 0 && dc === 0) continue
                    tryStep(r + dr, c + dc)
                }
            }
        }
        return moves
    }

    function chessSquareAttacked(board, tr, tc, byColor) {
        for (var r = 0; r < 8; r++) {
            for (var c = 0; c < 8; c++) {
                var p = board[r][c]
                if (p === 0) continue
                if ((p > 0 ? 1 : -1) !== byColor) continue
                var ms = chessPseudoMoves(board, r, c)
                for (var k = 0; k < ms.length; k++) {
                    if (ms[k].row === tr && ms[k].col === tc) return true
                }
            }
        }
        return false
    }

    function chessFindKing(board, color) {
        var target = color * 6
        for (var r = 0; r < 8; r++) {
            for (var c = 0; c < 8; c++) {
                if (board[r][c] === target) return {row: r, col: c}
            }
        }
        return null
    }

    function chessLegalMoves(r, c) {
        var board = _chessBoard
        var p = board[r][c]
        if (p === 0) return []
        var color = p > 0 ? 1 : -1
        var raws = chessPseudoMoves(board, r, c)
        var legal = []
        for (var i = 0; i < raws.length; i++) {
            var nb = chessCopyBoard(board)
            chessApplyMove(nb, r, c, raws[i].row, raws[i].col)
            var k = chessFindKing(nb, color)
            if (!k) continue
            if (!chessSquareAttacked(nb, k.row, k.col, -color)) {
                legal.push(raws[i])
            }
        }
        return legal
    }

    function chessSideHasMove(turn) {
        for (var r = 0; r < 8; r++) {
            for (var c = 0; c < 8; c++) {
                var p = _chessBoard[r][c]
                if (p === 0) continue
                if ((p > 0) !== (turn > 0)) continue
                if (chessLegalMoves(r, c).length > 0) return true
            }
        }
        return false
    }

    function chessKingChecked(color) {
        var k = chessFindKing(_chessBoard, color)
        if (!k) return false
        return chessSquareAttacked(_chessBoard, k.row, k.col, -color)
    }

    function chessTap(row, col) {
        if (_chessOver) return
        if (_chessVsAi && _chessTurn !== 1) return
        var board = _chessBoard
        var sel = _chessSel
        if (sel.row >= 0) {
            for (var i = 0; i < _chessMoves.length; i++) {
                if (_chessMoves[i].row === row && _chessMoves[i].col === col) {
                    chessMakeMove(sel.row, sel.col, row, col)
                    return
                }
            }
            var p = board[row][col]
            if (p !== 0 && (p > 0) === (_chessTurn > 0)) {
                _chessSel = {row: row, col: col}
                _chessMoves = chessLegalMoves(row, col)
                _chessCanvas.requestPaint()
                return
            }
            _chessSel = {row: -1, col: -1}
            _chessMoves = []
            _chessCanvas.requestPaint()
            return
        }
        var p2 = board[row][col]
        if (p2 === 0) return
        if ((p2 > 0) !== (_chessTurn > 0)) return
        _chessSel = {row: row, col: col}
        _chessMoves = chessLegalMoves(row, col)
        _chessCanvas.requestPaint()
    }

    function chessMakeMove(fr, fc, tr, tc) {
        var board = chessCopyBoard(_chessBoard)
        chessApplyMove(board, fr, fc, tr, tc)
        _chessBoard = board
        _chessLast = {fr: fr, fc: fc, tr: tr, tc: tc}
        _chessSel = {row: -1, col: -1}
        _chessMoves = []
        _chessTurn = -_chessTurn

        var anyMove = chessSideHasMove(_chessTurn)
        var inCheck = chessKingChecked(_chessTurn)
        if (!anyMove) {
            _chessOver = true
            if (inCheck) {
                _chessStatus = (_chessTurn > 0 ? "\u9ed1\u65b9" : "\u767d\u65b9") + "\u80dc\u5229"
            } else {
                _chessStatus = "\u548c\u68cb"
            }
        } else {
            if (inCheck) {
                _chessStatus = (_chessTurn > 0 ? "\u767d\u65b9" : "\u9ed1\u65b9") + "\u88ab\u5c06\u519b"
            } else {
                _chessStatus = (_chessTurn > 0 ? "\u767d\u65b9\u8d70" : "\u9ed1\u65b9\u8d70")
            }
            if (_chessVsAi && _chessTurn === -1) {
                _chessStatus = "AI \u601d\u8003\u4e2d..."
                _chessAiTimer.start()
            }
        }
        _chessCanvas.requestPaint()
    }

    function chessEvaluate(board) {
        var s = 0
        for (var r = 0; r < 8; r++) {
            for (var c = 0; c < 8; c++) {
                var p = board[r][c]
                if (p > 0) s -= chessValue(p)
                else if (p < 0) s += chessValue(p)
            }
        }
        return s
    }

    function chessAiPlay() {
        if (_chessOver) return
        if (_chessTurn !== -1) return
        var allMoves = []
        for (var r = 0; r < 8; r++) {
            for (var c = 0; c < 8; c++) {
                var p = _chessBoard[r][c]
                if (p >= 0) continue
                var ms = chessLegalMoves(r, c)
                for (var i = 0; i < ms.length; i++) {
                    allMoves.push({fr: r, fc: c, tr: ms[i].row, tc: ms[i].col})
                }
            }
        }
        if (allMoves.length === 0) return
        var bestScore = -1e9
        var bestMoves = []
        for (var i = 0; i < allMoves.length; i++) {
            var nb = chessCopyBoard(_chessBoard)
            var m = allMoves[i]
            chessApplyMove(nb, m.fr, m.fc, m.tr, m.tc)
            var score = chessEvaluate(nb) + Math.random() * 0.1
            if (score > bestScore) {
                bestScore = score
                bestMoves = [m]
            } else if (score >= bestScore - 0.001) {
                bestMoves.push(m)
            }
        }
        var pick = bestMoves[Math.floor(Math.random() * bestMoves.length)]
        chessMakeMove(pick.fr, pick.fc, pick.tr, pick.tc)
    }

    function chessDraw(canvas) {
        var ctx = canvas.getContext("2d")
        var step = canvas.chessStep
        if (ctx.reset) ctx.reset()
        ctx.clearRect(0, 0, canvas.width, canvas.height)

        for (var r = 0; r < 8; r++) {
            for (var c = 0; c < 8; c++) {
                ctx.fillStyle = ((r + c) % 2 === 0) ? "#f0d9b5" : "#b58863"
                ctx.fillRect(c * step, r * step, step, step)
            }
        }

        var last = _chessLast
        if (last.fr >= 0) {
            ctx.fillStyle = "rgba(255,255,0,0.4)"
            ctx.fillRect(last.fc * step, last.fr * step, step, step)
            ctx.fillRect(last.tc * step, last.tr * step, step, step)
        }

        var sel = _chessSel
        if (sel.row >= 0) {
            ctx.fillStyle = "rgba(50,200,50,0.5)"
            ctx.fillRect(sel.col * step, sel.row * step, step, step)
        }

        // 棋子图片 (SVG) — Cburnett 集
        var imgPathW = ["", "wP", "wN", "wB", "wR", "wQ", "wK"]
        var imgPathB = ["", "bP", "bN", "bB", "bR", "bQ", "bK"]
        var basePath = "file:///home/root/xovi/exthome/qt-resource-rebuilder/chess/"
        var pad = step * 0.06
        for (var r = 0; r < 8; r++) {
            for (var c = 0; c < 8; c++) {
                var p = _chessBoard[r][c]
                if (p === 0) continue
                var name = p > 0 ? imgPathW[p] : imgPathB[-p]
                try {
                    ctx.drawImage(basePath + name + ".svg",
                                  c * step + pad, r * step + pad,
                                  step - 2 * pad, step - 2 * pad)
                } catch (e) {
                    // 图片未加载完时绘制失败 - 跳过, 等 onImageLoaded 重新 paint
                }
            }
        }

        for (var i = 0; i < _chessMoves.length; i++) {
            var m = _chessMoves[i]
            var cx = m.col * step + step / 2
            var cy = m.row * step + step / 2
            var pp = _chessBoard[m.row][m.col]
            ctx.beginPath()
            if (pp === 0) {
                ctx.fillStyle = "rgba(50,150,50,0.6)"
                ctx.arc(cx, cy, step * 0.12, 0, 2 * Math.PI)
                ctx.fill()
            } else {
                ctx.lineWidth = 4
                ctx.strokeStyle = "rgba(50,150,50,0.85)"
                ctx.arc(cx, cy, step * 0.45, 0, 2 * Math.PI)
                ctx.stroke()
            }
        }

        ctx.strokeStyle = "black"
        ctx.lineWidth = 1
        for (var i = 0; i <= 8; i++) {
            ctx.beginPath()
            ctx.moveTo(i * step, 0); ctx.lineTo(i * step, 8 * step); ctx.stroke()
            ctx.beginPath()
            ctx.moveTo(0, i * step); ctx.lineTo(8 * step, i * step); ctx.stroke()
        }
    }

    Timer {
        id: _chessAiTimer
        interval: 60
        repeat: false
        onTriggered: root.chessAiPlay()
    }
}
