import QtQuick
import QtQuick.Layouts
import ark.tokens as ArkTokens

/** \addtogroup controls
 *  @{
 */
/*!

Container that organize buttons in a row

\image html paperTablet-ContextualMenu.qml.png paperTablet
\image html client-ContextualMenu.qml.png client

See \ref example-ContextualMenu.qml for usage examples
*/
Container {
    id: root

    /// Set to true to force buttons in horizontal menu to be of the same width
    property bool uniformSize: false

    /// ContextualMenu with items arranged in a column
    component Vertical: Container {
        id: vertical
        style: ArkTokens.ContextualMenu.primary.container
        contentItem: ColumnLayout {
            spacing: 0
            Repeater {
                model: vertical.contentModel
            }
        }
    }

    /// Button for ContextualMenu
    component Button: ButtonBase {

        type: ArkTokens.Button.tertiary

        /// Set button size with Button.Size values (paperTablet only). Default is Small
        buttonSize: ButtonBase.Size.XSmall // size is small but typography is even smaller

        // rest is private
        tokens: {
            if (!ArkTokens.Style.variable.isPaper) {
                return ArkTokens.ContextualMenu.primary.button;
            }
            const buttonType = ArkTokens.Button.tertiary;
            const iconButtonType = ArkTokens.IconButton.primary_inverted;
            let path = ""
            switch (buttonSize) {
            case ButtonBase.Size.Large:
                path = !!text ? buttonType.large : iconButtonType.large; break;
            case ButtonBase.Size.Medium:
                path = !!text ? buttonType.medium : iconButtonType.medium; break;
            case ButtonBase.Size.Small:
                path = !!text ? buttonType.small : iconButtonType.small; break;
            case ButtonBase.Size.XSmall:
                path = !!text ? buttonType.xsmall : iconButtonType.small; break;
            }
            let t = path.split('.').reduce((acc, c) => acc && acc[c], ArkTokens);
            return t;
        }

        states: {
            if (ArkTokens.Style.variable.isPaper) {
                return ButtonBase.ButtonState.Idle | ButtonBase.ButtonState.Selected;
            }
            return ButtonBase.ButtonState.Active | ButtonBase.ButtonState.Selected | ButtonBase.ButtonState.Disabled | ButtonBase.ButtonState.Hover | ButtonBase.ButtonState.Idle;
        }
    }

    /// Optional Divider between buttons
    component Divider: Item {
        width: ArkTokens.ContextualMenu.primary.container.borderWidth
        height: ArkTokens.ContextualMenu.primary.container.borderWidth
    }

    // rest is private
    style: ArkTokens.ContextualMenu.primary.container

    contentItem: ButtonRow {
        uniformCellSizes: root.uniformSize
        spacing: 0
        Repeater {
            model: root.contentModel
        }
    }
}
/** @}*/
