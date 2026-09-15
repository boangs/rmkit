// 快艇骰子 — 「空间」内置应用 (从旧高级面板迁出, 逻辑原样)
import QtQuick
import QtQuick.Layouts
import device.ui.controls

Item {
    id: root
    property var space          // 外壳注入的 API 对象 (见 space/README.md)
    anchors.fill: parent

    // 2-3 人轮流投掷, 每回合 3 次投掷机会, 共 13 类别填完游戏结束
    property int _yzPlayers: 2
    property int _yzCurrent: 0
    property var _yzDice: []      // [{value, hold}, ...] 5 颗
    property int _yzRolls: 3      // 当前回合剩余投掷次数
    property var _yzScores: []    // [{cat: score|null, ...}, ...] 每位玩家
    property bool _yzOver: false
    property string _yzMessage: ""
    readonly property var _yzCats: ["ones","twos","threes","fours","fives","sixes",
                                     "chance","fourOfKind","fullHouse",
                                     "smallStraight","largeStraight","yahtzee"]
    readonly property var _yzRows: ["ones","twos","threes","fours","fives","sixes",
                                     "_bonus",
                                     "chance","fourOfKind","fullHouse",
                                     "smallStraight","largeStraight","yahtzee",
                                     "_total"]

    Component.onCompleted: yzReset()


    ColumnLayout {
        anchors.fill: parent
        spacing: 14

        // 状态栏: 当前玩家 + 剩余投掷 + 人数选择 + 重开
        RowLayout {
            Layout.fillWidth: true
            Layout.preferredHeight: 56
            spacing: 24

            // 当前玩家彩色标签
            Rectangle {
                Layout.preferredWidth: 240
                Layout.preferredHeight: 52
                Layout.alignment: Qt.AlignVCenter
                radius: 10
                color: root._yzOver ? "#7f8c8d"
                       : root.yzPlayerColor(root._yzCurrent)
                Text {
                    anchors.centerIn: parent
                    text: root._yzOver
                          ? root._yzMessage
                          : (root.yzPlayerName(root._yzCurrent) + " \u8f6e\u6b21")
                    color: "white"
                    font.pixelSize: 26
                    font.weight: Font.Bold
                }
            }

            Text {
                Layout.alignment: Qt.AlignVCenter
                visible: !root._yzOver
                text: "\u5269\u4f59: " + root._yzRolls + " / 3"
                font.pixelSize: 24
                font.weight: Font.Medium
            }

            Item { Layout.fillWidth: true }

            // 人数选择 2/3
            Repeater {
                model: 2
                delegate: Item {
                    property int playerCount: index + 2
                    Layout.preferredWidth: yzRadioRow.implicitWidth
                    Layout.preferredHeight: 52
                    Layout.alignment: Qt.AlignVCenter
                    RowLayout {
                        id: yzRadioRow
                        anchors.fill: parent
                        spacing: 8
                        Rectangle {
                            Layout.preferredWidth: 24
                            Layout.preferredHeight: 24
                            Layout.alignment: Qt.AlignVCenter
                            radius: 12
                            border.width: 2
                            border.color: "black"
                            color: "white"
                            Rectangle {
                                anchors.centerIn: parent
                                width: 14; height: 14
                                radius: 7
                                color: "black"
                                visible: root._yzPlayers === playerCount
                            }
                        }
                        Text {
                            text: playerCount + " \u4eba"
                            font.pixelSize: 22
                            verticalAlignment: Text.AlignVCenter
                            Layout.alignment: Qt.AlignVCenter
                        }
                    }
                    MouseArea {
                        anchors.fill: parent
                        onClicked: {
                            if (root._yzPlayers !== playerCount) {
                                root._yzPlayers = playerCount
                                root.yzReset()
                            }
                        }
                    }
                }
            }

            IconButton {
                iconSource: "qrc:/ark/icons/restore"
                title: "\u91cd\u5f00"
                Layout.alignment: Qt.AlignVCenter
                onClicked: root.yzReset()
            }
        }

        // 骰子区
        RowLayout {
            Layout.alignment: Qt.AlignHCenter
            Layout.preferredHeight: root.space.largeScreen ? 160 : 110
            spacing: root.space.largeScreen ? 28 : 18

            Repeater {
                model: 5
                delegate: Rectangle {
                    Layout.preferredWidth: root.space.largeScreen ? 150 : 96
                    Layout.preferredHeight: root.space.largeScreen ? 150 : 96
                    property var dieData: root._yzDice[index]
                    property int dieValue: dieData ? dieData.value : 1
                    property bool dieHold: dieData ? dieData.hold : false

                    radius: 14
                    color: dieHold ? "#fff5d9" : "#ffffff"
                    border.color: dieHold ? "#c0392b" : "#1a0f04"
                    border.width: dieHold ? 4 : 2

                    // 7 个固定点位 (TL, TR, ML, MR, BL, BR, Center)
                    Repeater {
                        model: 7
                        delegate: Rectangle {
                            property int slot: index
                            property real cx: slot===6 ? 0.5 : (slot%2===0 ? 0.27 : 0.73)
                            property real cy: slot===6 ? 0.5 :
                                              (slot<2 ? 0.27 : (slot<4 ? 0.5 : 0.73))
                            visible: {
                                var v = parent.dieValue
                                if (v === 1) return slot === 6
                                if (v === 2) return slot === 0 || slot === 5
                                if (v === 3) return slot === 0 || slot === 6 || slot === 5
                                if (v === 4) return slot === 0 || slot === 1 || slot === 4 || slot === 5
                                if (v === 5) return slot === 0 || slot === 1 || slot === 6 || slot === 4 || slot === 5
                                if (v === 6) return slot < 6
                                return false
                            }
                            x: cx * parent.width - width/2
                            y: cy * parent.height - height/2
                            width: parent.width * 0.15
                            height: width
                            radius: width / 2
                            color: "#1a0f04"
                        }
                    }

                    // 锁定红点
                    Rectangle {
                        anchors.right: parent.right
                        anchors.top: parent.top
                        anchors.margins: 4
                        width: 12; height: 12
                        radius: 6
                        visible: parent.dieHold
                        color: "#c0392b"
                        border.color: "#1a0f04"
                        border.width: 1
                    }

                    MouseArea {
                        anchors.fill: parent
                        onClicked: root.yzToggleHold(index)
                    }
                }
            }
        }

        // 投掷按钮
        Rectangle {
            Layout.preferredWidth: 220
            Layout.preferredHeight: 60
            Layout.alignment: Qt.AlignHCenter
            property bool canRoll: !root._yzOver && root._yzRolls > 0
            radius: 14
            gradient: Gradient {
                GradientStop { position: 0.0; color: parent.canRoll ? "#f5d76e" : "#bdc3c7" }
                GradientStop { position: 1.0; color: parent.canRoll ? "#c0922d" : "#7f8c8d" }
            }
            border.color: "#1a0f04"
            border.width: 2

            Text {
                anchors.centerIn: parent
                text: "\u6295  \u9aa8"
                font.pixelSize: 26
                font.weight: Font.Bold
                color: "#1a0f04"
            }

            MouseArea {
                anchors.fill: parent
                enabled: parent.canRoll
                onClicked: root.yzRoll()
            }
        }

        // 计分表 (15 行: 6 上半 + 奖励 + 7 下半 + 总分)
        Rectangle {
            Layout.fillWidth: true
            Layout.fillHeight: true
            color: "transparent"
            border.color: "#bdbdbd"
            border.width: 1
            radius: 4

            GridLayout {
                anchors.fill: parent
                anchors.margins: 1
                columns: root._yzPlayers + 1
                rowSpacing: 0
                columnSpacing: 0

                Repeater {
                    model: root._yzRows.length * (root._yzPlayers + 1)
                    delegate: Rectangle {
                        id: cell
                        property int totalCols: root._yzPlayers + 1
                        property int rowIdx: Math.floor(index / totalCols)
                        property int colIdx: index % totalCols
                        property string rowKey: root._yzRows[rowIdx]
                        property int playerIdx: colIdx - 1
                        property bool isBonus: rowKey === "_bonus"
                        property bool isTotal: rowKey === "_total"
                        property bool isSummary: isBonus || isTotal
                        property bool isUpper: rowKey === "ones" || rowKey === "twos" || rowKey === "threes"
                                               || rowKey === "fours" || rowKey === "fives" || rowKey === "sixes"
                        property int dieValue: rowKey === "ones" ? 1 : rowKey === "twos" ? 2
                                               : rowKey === "threes" ? 3 : rowKey === "fours" ? 4
                                               : rowKey === "fives" ? 5 : rowKey === "sixes" ? 6 : 0
                        property bool isCurrent: !root._yzOver
                                                 && playerIdx >= 0
                                                 && playerIdx === root._yzCurrent

                        Layout.fillWidth: true
                        Layout.preferredHeight: isBonus ? 34 : (isTotal ? 60 : 50)
                        border.color: "#cfcfcf"
                        border.width: 1

                        color: {
                            if (isTotal) return "#3b2a18"
                            if (isBonus) return "#e8e6df"
                            if (colIdx === 0) return rowIdx % 2 === 0 ? "#f5f3ec" : "#fafaf6"
                            var s = root._yzScores[playerIdx]
                            var v = s ? s[rowKey] : null
                            if (isCurrent) {
                                if (v !== null && v !== undefined) return "#e6b94a"
                                return "#ffd866"
                            }
                            if (v !== null && v !== undefined) return "#dcdcd5"
                            return "#ffffff"
                        }

                        // 第一列: 图标 + 类别名
                        RowLayout {
                            anchors.fill: parent
                            anchors.leftMargin: 14
                            anchors.rightMargin: 8
                            visible: cell.colIdx === 0
                            spacing: 12

                            // 上半骰子 mini-die
                            Rectangle {
                                visible: cell.isUpper
                                Layout.alignment: Qt.AlignVCenter
                                Layout.preferredWidth: 34
                                Layout.preferredHeight: 34
                                radius: 6
                                color: "#ffffff"
                                border.color: "#1a0f04"
                                border.width: 1.6
                                Repeater {
                                    model: 7
                                    delegate: Rectangle {
                                        visible: {
                                            var dv = cell.dieValue
                                            var slot = index
                                            if (dv === 1) return slot === 6
                                            if (dv === 2) return slot === 0 || slot === 5
                                            if (dv === 3) return slot === 0 || slot === 6 || slot === 5
                                            if (dv === 4) return slot === 0 || slot === 1 || slot === 4 || slot === 5
                                            if (dv === 5) return slot === 0 || slot === 1 || slot === 6 || slot === 4 || slot === 5
                                            if (dv === 6) return slot < 6
                                            return false
                                        }
                                        x: parent.width * (index===6 ? 0.5 : (index%2===0 ? 0.27 : 0.73)) - width/2
                                        y: parent.height * (index===6 ? 0.5 : (index<2 ? 0.27 : (index<4 ? 0.5 : 0.73))) - height/2
                                        width: 5; height: 5; radius: 2.5
                                        color: "#1a0f04"
                                    }
                                }
                            }

                            // 下半组合 badge
                            Rectangle {
                                visible: !cell.isUpper && !cell.isSummary
                                Layout.alignment: Qt.AlignVCenter
                                Layout.preferredWidth: 34
                                Layout.preferredHeight: 34
                                radius: 6
                                color: cell.rowKey === "yahtzee" ? "#c0392b"
                                       : cell.rowKey === "largeStraight" ? "#27ae60"
                                       : cell.rowKey === "smallStraight" ? "#16a085"
                                       : cell.rowKey === "fullHouse" ? "#e67e22"
                                       : cell.rowKey === "fourOfKind" ? "#8e44ad"
                                       : cell.rowKey === "chance" ? "#2980b9"
                                       : "#7f8c8d"
                                border.color: "#1a0f04"
                                border.width: 1.6
                                Text {
                                    anchors.centerIn: parent
                                    text: cell.rowKey === "chance" ? "\u5168"
                                          : cell.rowKey === "fourOfKind" ? "\u56db"
                                          : cell.rowKey === "fullHouse" ? "\u846b"
                                          : cell.rowKey === "smallStraight" ? "\u5c0f"
                                          : cell.rowKey === "largeStraight" ? "\u5927"
                                          : cell.rowKey === "yahtzee" ? "\u2605"
                                          : ""
                                    color: "white"
                                    font.pixelSize: 18
                                    font.weight: Font.Bold
                                }
                            }

                            // 类别名
                            Text {
                                Layout.alignment: Qt.AlignVCenter
                                Layout.fillWidth: true
                                text: cell.isBonus ? "\u5956\u52b1 (\u4e0a\u534a \u2265 63)"
                                      : cell.isTotal ? "\u603b\u5206"
                                      : root.yzCategoryName(cell.rowKey)
                                font.pixelSize: cell.isTotal ? 28 : (cell.isBonus ? 18 : 22)
                                font.weight: cell.isSummary ? Font.Bold : Font.Medium
                                color: cell.isTotal ? "#ffffff" : "#1a0f04"
                                verticalAlignment: Text.AlignVCenter
                                elide: Text.ElideRight
                            }
                        }

                        // 数据列文字
                        Text {
                            anchors.fill: parent
                            anchors.leftMargin: 8
                            anchors.rightMargin: 14
                            visible: cell.colIdx > 0
                            horizontalAlignment: Text.AlignRight
                            verticalAlignment: Text.AlignVCenter
                            font.pixelSize: cell.isTotal ? 32 : (cell.isBonus ? 18 : 26)
                            font.weight: cell.isSummary ? Font.Bold : Font.Medium
                            text: {
                                if (cell.isBonus) {
                                    var sum = root.yzUpperSum(cell.playerIdx)
                                    var bn = root.yzBonus(cell.playerIdx)
                                    return sum + " / 63" + (bn > 0 ? "  +35" : "")
                                }
                                if (cell.isTotal) return root.yzPlayerTotal(cell.playerIdx)
                                var s = root._yzScores[cell.playerIdx]
                                var v = s ? s[cell.rowKey] : null
                                if (v !== null && v !== undefined) return v.toString()
                                if (cell.isCurrent && root._yzRolls < 3) {
                                    return root.yzCalcScore(cell.rowKey, root._yzDice).toString()
                                }
                                return ""
                            }
                            color: {
                                if (cell.isTotal) return "#ffffff"
                                if (cell.isBonus) return "#1a0f04"
                                var s = root._yzScores[cell.playerIdx]
                                var v = s ? s[cell.rowKey] : null
                                if (v !== null && v !== undefined) return "#1a0f04"
                                return "#9aa0a4"
                            }
                        }

                        MouseArea {
                            anchors.fill: parent
                            enabled: !cell.isSummary && cell.colIdx > 0
                            onClicked: {
                                if (root._yzOver) return
                                if (cell.playerIdx !== root._yzCurrent) return
                                if (root._yzRolls === 3) return
                                if (root._yzScores[cell.playerIdx][cell.rowKey] !== null) return
                                root.yzScore(cell.rowKey)
                            }
                        }
                    }
                }
            }
        }
    }

    // ─── 快艇骰子 (Yahtzee) JS 逻辑 ───────────────────────────
    function yzPlayerName(idx) {
        var names = ["\u7389", "\u73c0", "\u8001\u7237"]  // 玉/珀/老爷
        return "\u73a9\u5bb6 " + (idx + 1)
    }
    function yzPlayerColor(idx) {
        var colors = ["#c0392b", "#2980b9", "#27ae60"]
        return colors[idx % colors.length]
    }
    function yzCategoryName(key) {
        var names = {
            ones: "\u4e00\u70b9",
            twos: "\u4e8c\u70b9",
            threes: "\u4e09\u70b9",
            fours: "\u56db\u70b9",
            fives: "\u4e94\u70b9",
            sixes: "\u516d\u70b9",
            chance: "\u5168\u9009",
            fourOfKind: "\u56db\u9ab0\u540c\u82b1",
            fullHouse: "\u846b\u82a6",
            smallStraight: "\u5c0f\u987a",
            largeStraight: "\u5927\u987a",
            yahtzee: "\u5feb\u8247"
        }
        return names[key] || key
    }
    function yzReset() {
        var dice = []
        for (var i = 0; i < 5; i++) dice.push({ value: 1, hold: false })
        _yzDice = dice
        var scores = []
        for (var p = 0; p < _yzPlayers; p++) {
            var s = {}
            for (var k = 0; k < _yzCats.length; k++) s[_yzCats[k]] = null
            scores.push(s)
        }
        _yzScores = scores
        _yzCurrent = 0
        _yzRolls = 3
        _yzOver = false
        _yzMessage = ""
    }
    function yzToggleHold(idx) {
        if (_yzOver) return
        if (_yzRolls === 3) return  // 还没投, 不能锁
        var d = _yzDice.slice()
        d[idx] = { value: d[idx].value, hold: !d[idx].hold }
        _yzDice = d
    }
    function yzRoll() {
        if (_yzOver) return
        if (_yzRolls <= 0) return
        var d = _yzDice.slice()
        for (var i = 0; i < d.length; i++) {
            if (!d[i].hold) {
                d[i] = { value: 1 + Math.floor(Math.random() * 6), hold: false }
            }
        }
        _yzDice = d
        _yzRolls = _yzRolls - 1
    }
    function yzCounts(dice) {
        var c = [0, 0, 0, 0, 0, 0, 0]
        for (var i = 0; i < dice.length; i++) c[dice[i].value]++
        return c
    }
    function yzSum(dice) {
        var s = 0
        for (var i = 0; i < dice.length; i++) s += dice[i].value
        return s
    }
    function yzCalcScore(key, dice) {
        if (!dice || dice.length === 0) return 0
        var c = yzCounts(dice)
        if (key === "ones") return c[1] * 1
        if (key === "twos") return c[2] * 2
        if (key === "threes") return c[3] * 3
        if (key === "fours") return c[4] * 4
        if (key === "fives") return c[5] * 5
        if (key === "sixes") return c[6] * 6
        if (key === "fourOfKind") {
            for (var j = 1; j <= 6; j++) if (c[j] >= 4) return yzSum(dice)
            return 0
        }
        if (key === "fullHouse") {
            var has3 = false, has2 = false
            for (var k = 1; k <= 6; k++) {
                if (c[k] === 3) has3 = true
                else if (c[k] === 2) has2 = true
                else if (c[k] === 5) { has3 = true; has2 = true }  // 5 同也算
            }
            return (has3 && has2) ? 25 : 0
        }
        if (key === "smallStraight") {
            var seqs = [[1,2,3,4],[2,3,4,5],[3,4,5,6]]
            for (var s1 = 0; s1 < seqs.length; s1++) {
                var ok = true
                for (var s2 = 0; s2 < 4; s2++) if (c[seqs[s1][s2]] === 0) { ok = false; break }
                if (ok) return 30
            }
            return 0
        }
        if (key === "largeStraight") {
            if (c[1]&&c[2]&&c[3]&&c[4]&&c[5]) return 40
            if (c[2]&&c[3]&&c[4]&&c[5]&&c[6]) return 40
            return 0
        }
        if (key === "yahtzee") {
            for (var y = 1; y <= 6; y++) if (c[y] === 5) return 50
            return 0
        }
        if (key === "chance") return yzSum(dice)
        return 0
    }
    function yzUpperSum(playerIdx) {
        var s = _yzScores[playerIdx]
        if (!s) return 0
        var keys = ["ones","twos","threes","fours","fives","sixes"]
        var t = 0
        for (var i = 0; i < keys.length; i++) {
            var v = s[keys[i]]
            if (v !== null && v !== undefined) t += v
        }
        return t
    }
    function yzBonus(playerIdx) {
        return yzUpperSum(playerIdx) >= 63 ? 35 : 0
    }
    function yzPlayerTotal(playerIdx) {
        var s = _yzScores[playerIdx]
        if (!s) return 0
        var t = 0
        for (var k = 0; k < _yzCats.length; k++) {
            var v = s[_yzCats[k]]
            if (v !== null && v !== undefined) t += v
        }
        t += yzBonus(playerIdx)
        return t
    }
    function yzAllFilled() {
        for (var p = 0; p < _yzScores.length; p++) {
            var s = _yzScores[p]
            for (var k = 0; k < _yzCats.length; k++) {
                if (s[_yzCats[k]] === null) return false
            }
        }
        return true
    }
    function yzScore(key) {
        if (_yzOver) return
        if (_yzRolls === 3) return
        var p = _yzCurrent
        if (_yzScores[p][key] !== null) return
        var pts = yzCalcScore(key, _yzDice)
        var newScores = _yzScores.slice()
        var ns = {}
        for (var k in newScores[p]) ns[k] = newScores[p][k]
        ns[key] = pts
        newScores[p] = ns
        _yzScores = newScores
        // 切换到下一个玩家
        _yzCurrent = (p + 1) % _yzPlayers
        _yzRolls = 3
        // 重置骰子锁定
        var d = []
        for (var i = 0; i < 5; i++) d.push({ value: 1, hold: false })
        _yzDice = d
        if (yzAllFilled()) {
            var totals = []
            var max = -1, winner = -1, tie = false
            for (var pi = 0; pi < _yzPlayers; pi++) {
                var t = yzPlayerTotal(pi)
                totals.push(t)
                if (t > max) { max = t; winner = pi; tie = false }
                else if (t === max) { tie = true }
            }
            _yzOver = true
            if (tie) _yzMessage = "\u5e73\u5c40\uff01" + max + " \u5206"
            else _yzMessage = yzPlayerName(winner) + " \u80dc\u5229 " + max + " \u5206"
        }
    }
}
