import QtQuick

// Bar glyph: the robot with a usage bar under it. The bar fills with the
// selected provider's busiest limit and turns urgent near the cap.
Item {
  id: root

  property real used: -1           // 0..1, -1 = no data (track only)
  property bool alarming: false
  property color color: "#888888"
  property color alarmColor: "#e06c75"
  property string fontFamily: ""

  readonly property real s: width / 16

  Text {
    anchors.horizontalCenter: parent.horizontalCenter
    y: -1.2 * root.s
    text: "󱚣"
    font.family: root.fontFamily
    font.pixelSize: Math.round(13 * root.s)
    color: root.alarming ? root.alarmColor : root.color
  }

  // track
  Rectangle {
    x: 1.5 * root.s; y: 13.6 * root.s
    width: 13 * root.s; height: 2 * root.s
    radius: height / 2
    color: root.color
    opacity: 0.25
  }

  // fill
  Rectangle {
    visible: root.used > 0
    x: 1.5 * root.s; y: 13.6 * root.s
    width: Math.max(height, 13 * root.s * Math.min(1, root.used))
    height: 2 * root.s
    radius: height / 2
    color: root.alarming ? root.alarmColor : root.color
  }
}
