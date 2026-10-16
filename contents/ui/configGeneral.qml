import QtQuick
import QtQuick.Layouts
import QtQuick.Controls as QQC2
import org.kde.kirigami as Kirigami
import org.kde.kcmutils as KCM

KCM.SimpleKCM {
    property alias cfg_opacity: slider.value
    property int cfg_opacityDefault: 82
    property alias cfg_requireLuks: luksBox.checked
    property alias cfg_requireFirewall: fwBox.checked
    property alias cfg_requireUsbguard: usbBox.checked

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

        Kirigami.Separator {
            Kirigami.FormData.isSection: true
            Kirigami.FormData.label: "Seguridad"
        }
        QQC2.Label {
            text: "Un servicio habilitado que no está corriendo siempre genera alerta.\n"
                + "Marcá lo que esta máquina debe tener: si falta, también alerta."
            wrapMode: Text.WordWrap
            opacity: 0.7
            Layout.maximumWidth: Kirigami.Units.gridUnit * 22
        }
        QQC2.CheckBox {
            id: luksBox
            Kirigami.FormData.label: "Exigir:"
            text: "Raíz (/) cifrada con LUKS"
        }
        QQC2.CheckBox {
            id: fwBox
            text: "Firewall activo (ufw, firewalld, nftables o iptables)"
        }
        QQC2.CheckBox {
            id: usbBox
            text: "USBGuard activo"
        }
    }
}
