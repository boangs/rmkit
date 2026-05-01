import QtQuick
import ark.tokens as ArkTokens

/** \addtogroup controls
 *  @{
 */
/*! A button with an icon

\image html client-IconButton.qml.png Client
\image html paperTablet-IconButton.qml.png paperTablet

\note
    IconButton size is determined by buttonSize and can not be changed
\note
    IconButton states for paperTablet are idle, selected and disabled

### Usage example
\code
    ArkControls.IconButton {
        type: ArkTokens.IconButton.primary
        iconSource: "path/to/icon.svg"
    }
\endcode
*/
ButtonBase {
    id: root

    /*!
        ArkTokens\.IconButton type. Default is primary

        - ArkTokens.IconButton.primary
        - ArkTokens.IconButton.primary_inverted

        Only for paperTablet
        - ArkTokens.IconButton.secondary
        - ArkTokens.IconButton.secondary_inverted
        - ArkTokens.IconButton.tertiary
        - ArkTokens.IconButton.tertiary_inverted
    */
    type: ArkTokens.IconButton.primary
    
    /// Default size is Small. Change it with values from \ref Size enum
    buttonSize: IconButton.Size.Small


    /// set to false to disable dither effect on disabled state (when disabled state has its own icon)
    property bool ditherOnDisabled: true

    /// this property is depricated
    property bool multicolor: false

    // rest is private and should not be touched
    contentItem: Icon {
        id: _icon
        source: root.iconSource
        size: root.tokens.content.icon.idle.sizing
        color: root.tokens.content.icon[root.state].fill

        antialiasing: root.antialiasing

        Loader {
            id: _ditherLoader
            anchors.fill: parent
            active: root.state === "disabled" && ArkTokens.Style.variable.isPaper && root.ditherOnDisabled
            sourceComponent: Image {
                anchors.fill: parent
                source: Details.overlaySource(ditherBackgroundColor)
                fillMode: Image.Tile
            }
        }
    }

    states: {
        if (ArkTokens.Style.variable.isPaper)
            return ButtonBase.ButtonState.Idle | ButtonBase.ButtonState.Selected | ButtonBase.ButtonState.Disabled;
        return ButtonBase.ButtonState.Active | ButtonBase.ButtonState.Selected | ButtonBase.ButtonState.Disabled | ButtonBase.ButtonState.Hover | ButtonBase.ButtonState.Idle;
    }
}
/** @}*/
