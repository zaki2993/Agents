import QtQuick
import QtQuick.Shapes

// Bar glyph: minimal rounded-stroke robot head with a live usage bar beneath.
// Drawn on the same 16x16 / 1.4*s vector grid as the other bar icons.
Item {
  id: root

  property real used: -1           // 0..1, -1 = no data (track only)
  property bool alarming: false
  property color color: "#888888"
  property color alarmColor: "#e06c75"
  property string fontFamily: ""

  readonly property real s: width / 16
  readonly property color ink: alarming ? alarmColor : color

  // Antenna stem + tip
  Shape {
    anchors.fill: parent
    preferredRendererType: Shape.CurveRenderer
    ShapePath {
      strokeColor: root.ink
      strokeWidth: 1.3 * root.s
      capStyle: ShapePath.RoundCap
      fillColor: "transparent"
      startX: 8 * root.s; startY: 1.7 * root.s
      PathLine { x: 8 * root.s; y: 3.7 * root.s }
    }
  }
  Rectangle {
    x: 7.1 * root.s; y: 0.7 * root.s
    width: 1.8 * root.s; height: width
    radius: width / 2
    color: root.ink
  }

  // Side ears
  Shape {
    anchors.fill: parent
    preferredRendererType: Shape.CurveRenderer
    ShapePath {
      strokeColor: root.ink
      strokeWidth: 1.3 * root.s
      capStyle: ShapePath.RoundCap
      fillColor: "transparent"
      startX: 1.2 * root.s; startY: 6.5 * root.s
      PathLine { x: 1.2 * root.s; y: 8.7 * root.s }
      PathMove { x: 14.8 * root.s; y: 6.5 * root.s }
      PathLine { x: 14.8 * root.s; y: 8.7 * root.s }
    }
  }

  // Rounded visor head (1.4*s outline + subtle duotone fill)
  Shape {
    anchors.fill: parent
    preferredRendererType: Shape.CurveRenderer
    ShapePath {
      strokeColor: root.ink
      strokeWidth: 1.4 * root.s
      joinStyle: ShapePath.RoundJoin
      fillColor: Qt.rgba(root.ink.r, root.ink.g, root.ink.b, 0.12)
      PathRectangle {
        x: 2.5 * root.s; y: 3.9 * root.s
        width: 11 * root.s; height: 7.4 * root.s
        radius: 2.6 * root.s
      }
    }
  }

  // Two crisp eyes
  Rectangle {
    x: 5.1 * root.s; y: 6.6 * root.s
    width: 1.6 * root.s; height: 2.0 * root.s
    radius: 0.8 * root.s
    color: root.ink
  }
  Rectangle {
    x: 9.3 * root.s; y: 6.6 * root.s
    width: 1.6 * root.s; height: 2.0 * root.s
    radius: 0.8 * root.s
    color: root.ink
  }

  // Usage bar track
  Rectangle {
    x: 2.2 * root.s; y: 13.7 * root.s
    width: 11.6 * root.s; height: 1.8 * root.s
    radius: height / 2
    color: root.color
    opacity: 0.24
  }

  // Usage bar fill
  Rectangle {
    visible: root.used > 0
    x: 2.2 * root.s; y: 13.7 * root.s
    width: Math.max(height, 11.6 * root.s * Math.min(1, root.used))
    height: 1.8 * root.s
    radius: height / 2
    color: root.ink
  }
}
