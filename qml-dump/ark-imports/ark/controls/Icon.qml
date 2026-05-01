import QtQuick
import ark.tokens as ArkTokens
import ark.controls as ArkControls

/** \addtogroup controls
 *  @{
 */
/*! Icon styled with ark tokens

    \code
    ...
    Icon {
        color: "pink"
        size: 40
        source: "path/to/image"
    }
    ...
    \endcode

    * If the source is empty, the item becomes invisible.
    * If the file is not found or failed to be parsed or rendered, the item becomes invisible and sets `hasError`.
    * `hasError` is reset and the icon attempts to render again when you change the source, style, antialiasing, or assetToken.
    * `hasError` is read only.
*/

Item {
    id: root

    /// path to icon source
    property string source: ""

    /// width and height of the icon
    property int size: -1

    /// basic icon color
    property color color

    /// this property is deprecated. 
    property bool multicolor: false

    /// set true when antialiasing is desired, false otherwise
    antialiasing: true

    // For ark-library developers: apply tokens style directly
    // /instead of size and color
    property var style: {
        "sizing": root.size,
        "borderColor": root.color,
        "fill": root.color
    }

    // rest is private and should not be changed
    property color borderColor: style.borderColor ?? (style.fill ?? "")
    property color backgroundColor: style.backgroundColor ?? ""
    property color fill: style.fill ?? (style.borderColor ?? "")

    property arkImageInfo _info: {
        let blackAndWhite = !root.antialiasing && ArkTokens.Style.variable.isPaper;
        return ArkImageDataProvider.resolveImageInfo(root.source, blackAndWhite, root.borderColor, root.fill);
    }

    visible: !!source

    readonly property size sourceSize: _info.size
    implicitWidth: (style.sizing >= 0) ? style.sizing : sourceSize.width
    implicitHeight: (style.sizing >= 0) ? style.sizing : sourceSize.height

    Image {
        sourceSize: (style.sizing >= 0) ? Qt.size(style.sizing, style.sizing) : _info.size
        source: _info.source
    }
}

/** @}*/
