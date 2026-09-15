// 函数绘图 — 「空间」内置应用 (从旧高级面板迁出, 逻辑原样)
import QtQuick
import QtQuick.Layouts
import device.ui.controls

Item {
    id: root
    property var space          // 外壳注入的 API 对象 (见 space/README.md)
    anchors.fill: parent

    // 每个 eq: { id, color, expr, parsed, error }
    property var _fpEquations: []
    property int _fpNextId: 1
    property int _fpFocusedId: 0
    property real _fpXmin: -10
    property real _fpXmax: 10
    property real _fpYmin: -5
    property real _fpYmax: 5
    readonly property var _fpColors: ["#c0392b", "#2980b9", "#27ae60", "#e67e22"]
    readonly property var _fpSymbols: ["7", "8", "9", "/", "sin", "cos", "tan", "log",
                                        "4", "5", "6", "*", "sqrt", "abs", "pi", "e",
                                        "1", "2", "3", "-", "x", "^", "\u0028", "\u0029",
                                        "0", ".", "\u00b2", "\u00b3", "+", "\u232b", "C"]
    property var _fpInputs: ({})
    property var _fpParsedById: ({})
    property var _fpErrorById: ({})
    property bool _fpPresetOpen: false
    property int _fpPresetTargetId: 0
    readonly property var _fpPresets: [
        { "n": "\u6b63\u5f26 sin(x)",      "e": "sin(x)" },
        { "n": "\u4f59\u5f26 cos(x)",      "e": "cos(x)" },
        { "n": "\u6b63\u5207 tan(x)",      "e": "tan(x)" },
        { "n": "\u76f4\u7ebf y=x",         "e": "x" },
        { "n": "\u629b\u7269\u7ebf x\u00b2","e": "x^2" },
        { "n": "\u7acb\u65b9 x\u00b3",     "e": "x^3" },
        { "n": "\u53cd\u6bd4 1/x",         "e": "1/x" },
        { "n": "\u5e73\u65b9\u6839 \u221ax","e": "sqrt(x)" },
        { "n": "\u5bf9\u6570 log(x)",      "e": "log(x)" },
        { "n": "\u7edd\u5bf9\u503c |x|",   "e": "abs(x)" },
        { "n": "\u4e0a\u534a\u5706 R=5",   "e": "sqrt(25-x^2)" },
        { "n": "\u4e0b\u534a\u5706 R=5",   "e": "-sqrt(25-x^2)" },
        { "n": "\u5fc3\u5f62\u4e0a\u534a", "e": "abs(x)^(2/3)+sqrt(1-x^2)" },
        { "n": "\u5fc3\u5f62\u4e0b\u534a", "e": "abs(x)^(2/3)-sqrt(1-x^2)" }
    ]
    ListModel { id: _fpEquationsModel }

    Component.onCompleted: fpReset()


    Timer {
        id: fpRenderTimer
        interval: 180
        repeat: false
        onTriggered: fpCanvas.requestPaint()
    }

    ColumnLayout {
        anchors.fill: parent
        spacing: 14

        // 顶部: 方程列表 (固定 2 行)
        Rectangle {
            Layout.fillWidth: true
            Layout.preferredHeight: 28 + 2 * 58 + 8
            color: "transparent"
            border.color: "#cccccc"
            border.width: 1
            radius: 8

            ColumnLayout {
                id: fpEqCol
                anchors.fill: parent
                anchors.margins: 14
                spacing: 8

                Repeater {
                    model: _fpEquationsModel
                    delegate: RowLayout {
                        Layout.fillWidth: true
                        Layout.preferredHeight: 58
                        spacing: 14

                        Rectangle {
                            Layout.preferredWidth: 28
                            Layout.preferredHeight: 28
                            Layout.alignment: Qt.AlignVCenter
                            radius: 14
                            color: model.color
                            border.color: "#1a0f04"
                            border.width: 1.5
                        }

                        Text {
                            Layout.alignment: Qt.AlignVCenter
                            text: "y ="
                            font.pixelSize: 26
                            font.weight: Font.Medium
                        }

                        Rectangle {
                            Layout.fillWidth: true
                            Layout.preferredHeight: 52
                            Layout.maximumWidth: 420
                            border.color: root._fpFocusedId === model.id ? "#1a0f04" : "#cccccc"
                            border.width: root._fpFocusedId === model.id ? 2 : 1
                            radius: 4
                            color: "white"

                            Text {
                                anchors.fill: parent
                                anchors.leftMargin: 12
                                anchors.rightMargin: 12
                                verticalAlignment: Text.AlignVCenter
                                font.pixelSize: 26
                                clip: true
                                text: (model.expr || "") + (root._fpFocusedId === model.id ? "_" : "")
                            }
                            MouseArea {
                                anchors.fill: parent
                                onClicked: { root._fpFocusedId = model.id }
                            }
                        }

                        Text {
                            Layout.preferredWidth: 32
                            Layout.alignment: Qt.AlignVCenter
                            visible: !!root._fpErrorById[model.id]
                            text: "\u26a0"
                            color: "#c0392b"
                            font.pixelSize: 28
                            horizontalAlignment: Text.AlignHCenter
                        }

                        Item { Layout.fillWidth: true }

                        Rectangle {
                            Layout.preferredWidth: 150
                            Layout.preferredHeight: 52
                            Layout.alignment: Qt.AlignVCenter
                            radius: 6
                            color: "#fafafa"
                            border.color: "#1a0f04"
                            border.width: 1
                            Row {
                                anchors.centerIn: parent
                                spacing: 8
                                Text {
                                    anchors.verticalCenter: parent.verticalCenter
                                    text: "\u9884\u8bbe"
                                    font.pixelSize: 22
                                    font.weight: Font.Medium
                                }
                                Canvas {
                                    anchors.verticalCenter: parent.verticalCenter
                                    width: 14
                                    height: 10
                                    onPaint: {
                                        var ctx = getContext("2d")
                                        ctx.reset()
                                        ctx.fillStyle = "#1a0f04"
                                        ctx.beginPath()
                                        ctx.moveTo(0, 0)
                                        ctx.lineTo(width, 0)
                                        ctx.lineTo(width / 2, height)
                                        ctx.closePath()
                                        ctx.fill()
                                    }
                                }
                            }
                            MouseArea {
                                anchors.fill: parent
                                onClicked: {
                                    root._fpFocusedId = model.id
                                    root._fpPresetTargetId = model.id
                                    root._fpPresetOpen = true
                                }
                            }
                        }
                    }
                }
            }
        }

        // Canvas 绘图区
        Rectangle {
            Layout.fillWidth: true
            Layout.fillHeight: true
            border.color: "#1a0f04"
            border.width: 1
            radius: 4
            color: "white"

            Canvas {
                id: fpCanvas
                anchors.fill: parent
                anchors.margins: 1
                renderStrategy: Canvas.Cooperative
                onPaint: root.fpPaint(getContext("2d"), width, height)
                onWidthChanged: requestPaint()
                onHeightChanged: requestPaint()
            }
        }

        // 快捷符号键盘 (4 行 8 列, 固定每键 50px)
        GridLayout {
            Layout.fillWidth: true
            Layout.preferredHeight: 4 * 50 + 3 * 6
            Layout.maximumHeight: 4 * 50 + 3 * 6
            columns: 8
            rowSpacing: 6
            columnSpacing: 6
            Repeater {
                model: root._fpSymbols
                delegate: Rectangle {
                    Layout.fillWidth: true
                    Layout.preferredHeight: 50
                    Layout.maximumHeight: 50
                    radius: 6
                    color: "#fafafa"
                    border.color: "#1a0f04"
                    border.width: 1
                    Text {
                        anchors.centerIn: parent
                        text: modelData === "pi" ? "\u03c0" : modelData
                        font.pixelSize: modelData.length > 2 ? 20 : 26
                        font.weight: Font.Medium
                    }
                    MouseArea {
                        anchors.fill: parent
                        onClicked: root.fpInsertSymbol(modelData)
                    }
                }
            }
        }

        // 范围 + 缩放
        RowLayout {
            Layout.fillWidth: true
            Layout.preferredHeight: 50
            spacing: 14

            Text {
                Layout.alignment: Qt.AlignVCenter
                text: "x: [" + root._fpXmin.toFixed(1) + ", " + root._fpXmax.toFixed(1) + "]   y: [" + root._fpYmin.toFixed(1) + ", " + root._fpYmax.toFixed(1) + "]"
                font.pixelSize: 18
                color: "#444"
            }

            Item { Layout.fillWidth: true }

            Rectangle {
                Layout.preferredWidth: 70; Layout.preferredHeight: 44
                radius: 6; color: "#fafafa"; border.color: "#1a0f04"; border.width: 1
                Text { anchors.centerIn: parent; text: "\u2212"; font.pixelSize: 28; font.weight: Font.Bold }
                MouseArea { anchors.fill: parent; onClicked: root.fpZoom(1.5) }
            }
            Rectangle {
                Layout.preferredWidth: 70; Layout.preferredHeight: 44
                radius: 6; color: "#fafafa"; border.color: "#1a0f04"; border.width: 1
                Text { anchors.centerIn: parent; text: "+"; font.pixelSize: 28; font.weight: Font.Bold }
                MouseArea { anchors.fill: parent; onClicked: root.fpZoom(0.7) }
            }
            IconButton {
                iconSource: "qrc:/ark/icons/restore"
                title: "\u91cd\u7f6e"
                Layout.alignment: Qt.AlignVCenter
                onClicked: root.fpResetView()
            }
        }
    }

    // 预设公式 popup
    Rectangle {
        anchors.fill: parent
        color: "#80000000"
        visible: root._fpPresetOpen
        z: 50
        MouseArea {
            anchors.fill: parent
            onClicked: root._fpPresetOpen = false
        }
        Rectangle {
            anchors.centerIn: parent
            width: 660
            height: Math.min(parent.height - 80, root._fpPresets.length * 64 + 80)
            radius: 8
            color: "white"
            border.color: "#1a0f04"
            border.width: 1
            MouseArea { anchors.fill: parent }
            ColumnLayout {
                anchors.fill: parent
                anchors.margins: 16
                spacing: 8
                Text {
                    Layout.fillWidth: true
                    Layout.preferredHeight: 38
                    text: "\u9009\u62e9\u9884\u8bbe\u51fd\u6570"
                    font.pixelSize: 28
                    font.weight: Font.Medium
                    verticalAlignment: Text.AlignVCenter
                }
                Flickable {
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    contentHeight: presetCol.implicitHeight
                    clip: true
                    ColumnLayout {
                        id: presetCol
                        width: parent.width
                        spacing: 4
                        Repeater {
                            model: root._fpPresets
                            delegate: Rectangle {
                                Layout.fillWidth: true
                                Layout.preferredHeight: 60
                                radius: 4
                                color: "#fafafa"
                                border.color: "#cccccc"
                                border.width: 1
                                RowLayout {
                                    anchors.fill: parent
                                    anchors.leftMargin: 16
                                    anchors.rightMargin: 16
                                    spacing: 14
                                    Text {
                                        Layout.fillWidth: true
                                        Layout.alignment: Qt.AlignVCenter
                                        text: modelData.n
                                        font.pixelSize: 24
                                    }
                                    Text {
                                        Layout.alignment: Qt.AlignVCenter
                                        text: modelData.e
                                        font.pixelSize: 20
                                        color: "#666"
                                        font.family: "monospace"
                                    }
                                }
                                MouseArea {
                                    anchors.fill: parent
                                    onClicked: {
                                        root.fpUpdateExpr(root._fpPresetTargetId, modelData.e)
                                        root._fpFocusedId = root._fpPresetTargetId
                                        root._fpPresetOpen = false
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    // ─── 函数绘图 (Plot) JS 逻辑 ───────────────────────────────
    function fpReset() {
        _fpEquationsModel.clear()
        _fpInputs = ({})
        _fpParsedById = ({})
        _fpErrorById = ({})
        _fpNextId = 1
        _fpFocusedId = 0
        _fpXmin = -10; _fpXmax = 10
        _fpYmin = -5; _fpYmax = 5
        fpAdd("sin(x)")
        fpAdd("cos(x)")
        _fpFocusedId = 1
    }
    function fpAdd(initialExpr) {
        if (_fpEquationsModel.count >= 4) return
        var id = _fpNextId
        _fpNextId = _fpNextId + 1
        var color = _fpColors[_fpEquationsModel.count % _fpColors.length]
        var expr = (typeof initialExpr === "string") ? initialExpr : ""
        _fpEquationsModel.append({ id: id, color: color, expr: expr })
        if (expr.length > 0) fpUpdateExpr(id, expr)
        _fpFocusedId = id
        fpRender()
    }
    function fpRemove(id) {
        for (var i = 0; i < _fpEquationsModel.count; i++) {
            if (_fpEquationsModel.get(i).id === id) {
                _fpEquationsModel.remove(i, 1)
                break
            }
        }
        var p = {}
        for (var k1 in _fpParsedById) if (parseInt(k1) !== id) p[k1] = _fpParsedById[k1]
        _fpParsedById = p
        var e = {}
        for (var k2 in _fpErrorById) if (parseInt(k2) !== id) e[k2] = _fpErrorById[k2]
        _fpErrorById = e
        var n = {}
        for (var k3 in _fpInputs) if (parseInt(k3) !== id) n[k3] = _fpInputs[k3]
        _fpInputs = n
        fpRender()
    }
    function fpUpdateExpr(id, expr) {
        for (var i = 0; i < _fpEquationsModel.count; i++) {
            if (_fpEquationsModel.get(i).id === id) {
                if (_fpEquationsModel.get(i).expr !== expr) _fpEquationsModel.setProperty(i, "expr", expr)
                break
            }
        }
        var p = {}
        for (var k1 in _fpParsedById) p[k1] = _fpParsedById[k1]
        var e = {}
        for (var k2 in _fpErrorById) e[k2] = _fpErrorById[k2]
        try {
            var rpn = fpParse(expr)
            p[id] = rpn
            delete e[id]
        } catch (err) {
            p[id] = null
            e[id] = err.toString()
        }
        _fpParsedById = p
        _fpErrorById = e
        fpRender()
    }
    function fpInsertSymbol(s) {
        if (_fpEquationsModel.count === 0) return
        var id = _fpFocusedId
        var idx = -1
        for (var i = 0; i < _fpEquationsModel.count; i++) {
            if (_fpEquationsModel.get(i).id === id) { idx = i; break }
        }
        if (idx < 0) { idx = 0; id = _fpEquationsModel.get(0).id; _fpFocusedId = id }
        var cur = _fpEquationsModel.get(idx).expr || ""
        if (s === "\u232b") {
            cur = cur.slice(0, -1)
        } else if (s === "C") {
            cur = ""
        } else {
            var insert = s
            if (s === "sin" || s === "cos" || s === "tan" || s === "log" || s === "sqrt" || s === "abs") {
                insert = s + "("
            } else if (s === "\u00b2") {
                insert = "^2"
            } else if (s === "\u00b3") {
                insert = "^3"
            }
            cur = cur + insert
        }
        fpUpdateExpr(id, cur)
    }
    function fpZoom(factor) {
        var cx = (_fpXmin + _fpXmax) / 2
        var cy = (_fpYmin + _fpYmax) / 2
        var hw = (_fpXmax - _fpXmin) / 2 * factor
        var hh = (_fpYmax - _fpYmin) / 2 * factor
        _fpXmin = cx - hw; _fpXmax = cx + hw
        _fpYmin = cy - hh; _fpYmax = cy + hh
        fpRender()
    }
    function fpResetView() {
        _fpXmin = -10; _fpXmax = 10
        _fpYmin = -5; _fpYmax = 5
        fpRender()
    }
    function fpRender() {
        if (typeof fpRenderTimer !== "undefined" && fpRenderTimer) fpRenderTimer.restart()
    }

    // ─── parser ───
    function fpTokenize(s) {
        var tokens = []
        var i = 0, n = s.length
        while (i < n) {
            var c = s.charAt(i)
            if (c === " " || c === "\t") { i++; continue }
            var code = c.charCodeAt(0)
            if ((code >= 48 && code <= 57) || c === ".") {
                var j = i
                while (j < n) {
                    var cj = s.charAt(j)
                    var cjc = cj.charCodeAt(0)
                    if ((cjc >= 48 && cjc <= 57) || cj === ".") j++
                    else break
                }
                tokens.push({ type: "num", val: parseFloat(s.substring(i, j)) })
                i = j
            } else if ((code >= 65 && code <= 90) || (code >= 97 && code <= 122) || c === "_") {
                var j = i
                while (j < n) {
                    var cj = s.charAt(j)
                    var cjc = cj.charCodeAt(0)
                    if ((cjc >= 48 && cjc <= 57) || (cjc >= 65 && cjc <= 90) || (cjc >= 97 && cjc <= 122) || cj === "_") j++
                    else break
                }
                tokens.push({ type: "id", val: s.substring(i, j).toLowerCase() })
                i = j
            } else if (c === "\u03c0") {
                tokens.push({ type: "id", val: "pi" }); i++
            } else if (c === "+" || c === "-" || c === "*" || c === "/" || c === "^" || c === "(" || c === ")") {
                tokens.push({ type: c, val: c }); i++
            } else if (c === ",") {
                tokens.push({ type: ",", val: "," }); i++
            } else {
                throw new Error("\u975e\u6cd5\u5b57\u7b26: " + c)
            }
        }
        return tokens
    }
    function fpToRpn(tokens) {
        var output = []
        var stack = []
        var prec = { "+": 1, "-": 1, "*": 2, "/": 2, "^": 4, "u-": 5 }
        var rightAssoc = { "^": true, "u-": true }
        var prev = null
        for (var i = 0; i < tokens.length; i++) {
            var t = tokens[i]
            if (t.type === "num") {
                output.push(t)
            } else if (t.type === "id") {
                if (i + 1 < tokens.length && tokens[i+1].type === "(") {
                    stack.push({ type: "fn", val: t.val })
                } else {
                    output.push(t)
                }
            } else if (t.type === "(") {
                stack.push(t)
            } else if (t.type === ")") {
                while (stack.length > 0 && stack[stack.length-1].type !== "(") {
                    output.push(stack.pop())
                }
                if (stack.length === 0) throw new Error("\u62ec\u53f7\u4e0d\u5339\u914d")
                stack.pop()
                if (stack.length > 0 && stack[stack.length-1].type === "fn") {
                    output.push(stack.pop())
                }
            } else if (t.type === ",") {
                while (stack.length > 0 && stack[stack.length-1].type !== "(") {
                    output.push(stack.pop())
                }
            } else {
                var op = t.type
                var isUnary = (op === "-" || op === "+") && (prev === null
                    || (prev.type !== "num" && prev.type !== "id" && prev.type !== ")"))
                if (isUnary && op === "-") {
                    op = "u-"
                    t = { type: "op", val: "u-" }
                } else if (isUnary && op === "+") {
                    prev = tokens[i]
                    continue
                } else {
                    t = { type: "op", val: op }
                }
                while (stack.length > 0) {
                    var top = stack[stack.length-1]
                    if (top.type === "(") break
                    if (top.type !== "op" && top.type !== "fn") break
                    var topPrec = top.type === "fn" ? 100 : prec[top.val]
                    var curPrec = prec[op]
                    if (rightAssoc[op] ? topPrec > curPrec : topPrec >= curPrec) {
                        output.push(stack.pop())
                    } else break
                }
                stack.push(t)
            }
            prev = tokens[i]
        }
        while (stack.length > 0) {
            var topp = stack.pop()
            if (topp.type === "(" || topp.type === ")") throw new Error("\u62ec\u53f7\u4e0d\u5339\u914d")
            output.push(topp)
        }
        return output
    }
    function fpParse(expr) {
        if (!expr) return null
        var s = ("" + expr).replace(/^\s+|\s+$/g, "")
        if (s.length === 0) return null
        if (s.indexOf("y=") === 0) s = s.substring(2).replace(/^\s+/, "")
        else if (s.indexOf("y =") === 0) s = s.substring(3).replace(/^\s+/, "")
        else if (s.indexOf("Y=") === 0) s = s.substring(2).replace(/^\s+/, "")
        if (s.length === 0) return null
        return fpToRpn(fpTokenize(s))
    }
    function fpEval(rpn, x) {
        if (!rpn) return NaN
        var st = []
        for (var i = 0; i < rpn.length; i++) {
            var t = rpn[i]
            if (t.type === "num") st.push(t.val)
            else if (t.type === "id") {
                if (t.val === "x") st.push(x)
                else if (t.val === "pi") st.push(Math.PI)
                else if (t.val === "e") st.push(Math.E)
                else throw new Error("\u672a\u77e5\u53d8\u91cf: " + t.val)
            }
            else if (t.type === "op") {
                if (t.val === "u-") {
                    st.push(-st.pop())
                } else {
                    var b = st.pop(), a = st.pop()
                    if (t.val === "+") st.push(a + b)
                    else if (t.val === "-") st.push(a - b)
                    else if (t.val === "*") st.push(a * b)
                    else if (t.val === "/") st.push(a / b)
                    else if (t.val === "^") st.push(Math.pow(a, b))
                }
            }
            else if (t.type === "fn") {
                var v = st.pop()
                if (t.val === "sin") st.push(Math.sin(v))
                else if (t.val === "cos") st.push(Math.cos(v))
                else if (t.val === "tan") st.push(Math.tan(v))
                else if (t.val === "asin") st.push(Math.asin(v))
                else if (t.val === "acos") st.push(Math.acos(v))
                else if (t.val === "atan") st.push(Math.atan(v))
                else if (t.val === "log" || t.val === "ln") st.push(Math.log(v))
                else if (t.val === "log10" || t.val === "lg") st.push(Math.log(v) / Math.LN10)
                else if (t.val === "exp") st.push(Math.exp(v))
                else if (t.val === "sqrt") st.push(Math.sqrt(v))
                else if (t.val === "abs") st.push(Math.abs(v))
                else if (t.val === "floor") st.push(Math.floor(v))
                else if (t.val === "ceil") st.push(Math.ceil(v))
                else if (t.val === "round") st.push(Math.round(v))
                else if (t.val === "sign") st.push(v > 0 ? 1 : (v < 0 ? -1 : 0))
                else if (t.val === "sinh") st.push((Math.exp(v) - Math.exp(-v)) / 2)
                else if (t.val === "cosh") st.push((Math.exp(v) + Math.exp(-v)) / 2)
                else if (t.val === "tanh") {
                    var ex = Math.exp(2*v)
                    st.push((ex - 1) / (ex + 1))
                }
                else throw new Error("\u672a\u77e5\u51fd\u6570: " + t.val)
            }
        }
        return st[0]
    }
    function fpNiceStep(range) {
        if (range <= 0) return 1
        var raw = range / 8
        var pow = Math.pow(10, Math.floor(Math.log(raw) / Math.LN10))
        var nn = raw / pow
        if (nn < 1.5) nn = 1
        else if (nn < 3) nn = 2
        else if (nn < 7) nn = 5
        else nn = 10
        return nn * pow
    }
    function fpPaint(ctx, w, h) {
        if (!ctx) return
        ctx.fillStyle = "white"
        ctx.fillRect(0, 0, w, h)
        var xmin = _fpXmin, xmax = _fpXmax
        var ymin = _fpYmin, ymax = _fpYmax
        if (xmax <= xmin || ymax <= ymin) return
        // 等比例缩放: x/y 共用同一 px/unit, 居中扩展窄方向
        var scale = Math.min(w / (xmax - xmin), h / (ymax - ymin))
        var cx = (xmin + xmax) / 2
        var cy = (ymin + ymax) / 2
        var halfW = w / scale / 2
        var halfH = h / scale / 2
        xmin = cx - halfW; xmax = cx + halfW
        ymin = cy - halfH; ymax = cy + halfH
        var xs = scale
        var ys = scale
        // 网格
        ctx.strokeStyle = "#dddddd"
        ctx.lineWidth = 1
        var xstep = fpNiceStep(xmax - xmin)
        var ystep = fpNiceStep(ymax - ymin)
        ctx.beginPath()
        var gx = Math.ceil(xmin / xstep) * xstep
        while (gx <= xmax + 1e-9) {
            var px = (gx - xmin) * xs
            ctx.moveTo(px, 0); ctx.lineTo(px, h)
            gx += xstep
        }
        var gy = Math.ceil(ymin / ystep) * ystep
        while (gy <= ymax + 1e-9) {
            var py = h - (gy - ymin) * ys
            ctx.moveTo(0, py); ctx.lineTo(w, py)
            gy += ystep
        }
        ctx.stroke()
        // 坐标轴
        ctx.strokeStyle = "#000000"
        ctx.lineWidth = 2
        var x0 = -xmin * xs
        var y0 = h - (-ymin) * ys
        if (xmin <= 0 && 0 <= xmax) {
            ctx.beginPath(); ctx.moveTo(x0, 0); ctx.lineTo(x0, h); ctx.stroke()
        }
        if (ymin <= 0 && 0 <= ymax) {
            ctx.beginPath(); ctx.moveTo(0, y0); ctx.lineTo(w, y0); ctx.stroke()
        }
        // 刻度
        ctx.fillStyle = "#000000"
        ctx.font = "16px sans-serif"
        ctx.textAlign = "center"; ctx.textBaseline = "top"
        var labelY = (ymin <= 0 && 0 <= ymax) ? Math.min(h - 22, Math.max(2, y0 + 4)) : h - 22
        gx = Math.ceil(xmin / xstep) * xstep
        while (gx <= xmax + 1e-9) {
            if (Math.abs(gx) > xstep * 0.5) {
                var lab = (Math.round(gx * 1000) / 1000).toString()
                ctx.fillText(lab, (gx - xmin) * xs, labelY)
            }
            gx += xstep
        }
        ctx.textAlign = "right"; ctx.textBaseline = "middle"
        var labelX = (xmin <= 0 && 0 <= xmax) ? Math.max(28, Math.min(w - 4, x0 - 6)) : w - 4
        gy = Math.ceil(ymin / ystep) * ystep
        while (gy <= ymax + 1e-9) {
            if (Math.abs(gy) > ystep * 0.5) {
                var lab2 = (Math.round(gy * 1000) / 1000).toString()
                ctx.fillText(lab2, labelX, h - (gy - ymin) * ys)
            }
            gy += ystep
        }
        // 曲线
        var samples = Math.min(900, Math.max(200, Math.floor(w)))
        var jumpThresh = (ymax - ymin) * 5
        for (var ei = 0; ei < _fpEquationsModel.count; ei++) {
            var em = _fpEquationsModel.get(ei)
            var rpn = _fpParsedById[em.id]
            if (!rpn) continue
            ctx.strokeStyle = em.color
            ctx.lineWidth = 2.5
            ctx.beginPath()
            var moved = false, prevY = NaN
            for (var sIdx = 0; sIdx <= samples; sIdx++) {
                var x = xmin + (xmax - xmin) * sIdx / samples
                var y
                try { y = fpEval(rpn, x) } catch (eErr) { y = NaN }
                if (isFinite(y)) {
                    var pyy = h - (y - ymin) * ys
                    if (!moved || !isFinite(prevY) || Math.abs(y - prevY) > jumpThresh) {
                        ctx.moveTo((x - xmin) * xs, pyy)
                    } else {
                        ctx.lineTo((x - xmin) * xs, pyy)
                    }
                    moved = true
                    prevY = y
                } else {
                    moved = false
                    prevY = NaN
                }
            }
            ctx.stroke()
        }
    }
}
