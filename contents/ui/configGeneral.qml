import QtQuick
import QtQuick.Layouts
import QtQuick.Controls as QQC2
import org.kde.kirigami as Kirigami
import org.kde.kcmutils as KCM

KCM.SimpleKCM {
    property alias cfg_opacity: slider.value
    property int cfg_opacityDefault: 82

    Kirigami.FormLayout {
        RowLayout {
            Kirigami.FormData.label: "Opacidad del fondo:"
            spacing: Kirigami.Units.smallSpacing
            QQC2.Slider {
                id: slider
                from: 0
                to: 100
                stepSize: 1
                Layout.preferredWidth: Kirigami.Units.gridUnit * 14
            }
            QQC2.Label {
                text: Math.round(slider.value) + " %"
                font.features: { "tnum": 1 }
                Layout.minimumWidth: Kirigami.Units.gridUnit * 3
            }
        }
        QQC2.Button {
            text: "Restablecer (82 %)"
            icon.name: "edit-undo"
            onClicked: slider.value = cfg_opacityDefault
        }
    }
}
