import QtQuick
import Quickshell
import qs.Commons as Commons
import qs.Ui

// Compact popup for the quotabot display file. KeyboardPanel calls
// requestPopout and releasePopout on the injected bar facade. This item has
// no required properties; the host may construct it before bar is set.
Item {
  id: root

  property QtObject bar: null
  property Item anchorItem: null
  property var display: null
  property bool refreshing: false

  signal refreshRequested()

  property bool opened: false
  property bool popoutSwitchClosing: false

  function open() {
    opened = true
  }

  function close() {
    opened = false
  }

  function closeForPopoutSwitch() {
    popoutSwitchClosing = true
    opened = false
  }

  readonly property color ink: Commons.Color.popups.text
  readonly property color dim: Commons.Color.muted
  readonly property color alarm: Commons.Color.urgent
  readonly property string fontFamily: bar && bar.fontFamily ? bar.fontFamily : "monospace"
  readonly property var accounts: display && display.accounts ? display.accounts : []

  function remainingText(row) {
    if (!row) return "unknown"
    if (row.freshness === "drift") return "drift, not routable"
    if (row.freshness === "unknown" || row.headroom_percent === null || row.headroom_percent === undefined)
      return "unknown"
    var prefix = row.local ? "local " : ""
    var suffix = row.freshness === "stale" ? "% remaining, stale" : "% remaining"
    return prefix + Math.round(Number(row.headroom_percent)) + suffix
  }

  function windowText(row) {
    if (!row || !row.windows) return ""
    if (row.freshness !== "live" && row.freshness !== "stale" && row.freshness !== "drift")
      return ""
    var parts = []
    var index
    for (index = 0; index < row.windows.length; index++) {
      var item = row.windows[index]
      if (!item || item.used_percent === null || item.used_percent === undefined) continue
      if (row.freshness === "drift")
        parts.push(item.label + " used " + Math.round(Number(item.used_percent)) + "%")
      else
        parts.push(item.label + " " + Math.round(100 - Number(item.used_percent)) + "% left")
    }
    if (parts.length === 0) return ""
    if (row.freshness === "drift") return "last trusted, not routable: " + parts.join(", ")
    return parts.join("  ")
  }

  function resetText(value) {
    if (typeof value !== "number") return "reset unknown"
    return "resets " + Qt.formatDateTime(new Date(value * 1000), "d MMM HH:mm")
  }

  function evidenceText(row) {
    if (!row) return ""
    if (row.source_class === "manual") return "self-reported"
    if (row.source_class === "status_only") return "status only"
    if (row.request_admission === "denied") return "admission denied"
    if (row.request_admission === "unresolved") return "admission unresolved"
    if (row.local_readiness === "loaded" || row.local_readiness === "cold") return row.local_readiness
    return ""
  }

  function recommendationTitle() {
    var recommendation = display ? display.recommendation : null
    if (!recommendation) return "No recommendation"
    var where = recommendation.local ? "local " + recommendation.provider : recommendation.provider
    var who = recommendation.account_label ? " (" + recommendation.account_label + ")" : ""
    return where + who
  }

  function fallbackText() {
    var item = display ? display.fallback : null
    if (!item) return "Fallback unknown"
    var kind = item.kind || "passthrough"
    var provider = item.provider || "none"
    return "Fallback: " + kind + " " + provider
  }

  KeyboardPanel {
    id: panel

    anchorItem: root.anchorItem
    bar: root.bar
    owner: root
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Commons.Style.space(360))
    contentHeight: panel.fittedContentHeight(column.implicitHeight, Commons.Style.space(520))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onCloseRequested: root.close()
      onActivateRequested: root.refreshRequested()
      onTextKey: function(text) {
        if (text === "r" || text === "R") root.refreshRequested()
      }
    }

    Rectangle {
      anchors.fill: parent
      color: Commons.Color.popups.background
      radius: Commons.Style.cornerRadius
    }

    Flickable {
      id: flick
      anchors.fill: parent
      contentWidth: width
      contentHeight: column.implicitHeight
      clip: true

      Column {
        id: column
        width: flick.width
        spacing: Commons.Style.space(8)

        Text {
          width: column.width
          color: root.ink
          font.family: root.fontFamily
          font.pixelSize: Commons.Style.font.title
          text: "quotabot"
        }

        Text {
          width: column.width
          wrapMode: Text.WordWrap
          color: display && display.read_ok === false ? root.alarm : root.dim
          font.family: root.fontFamily
          font.pixelSize: Commons.Style.font.bodySmall
          text: {
            if (!display) return "No snapshot yet. Refresh reads the local quotabot CLI."
            if (display.read_ok === false) return display.read_error || "Refresh failed. Last snapshot kept."
            var policy = display.routing_policy || "unknown"
            return "Policy " + policy
          }
        }

        Text {
          width: column.width
          wrapMode: Text.WordWrap
          color: root.ink
          font.family: root.fontFamily
          font.pixelSize: Commons.Style.font.subtitle
          text: root.recommendationTitle()
        }

        Text {
          width: column.width
          wrapMode: Text.WordWrap
          color: {
            var recommendation = display ? display.recommendation : null
            if (!recommendation) return root.alarm
            if (recommendation.freshness === "drift" || recommendation.freshness === "unknown" || recommendation.available === false)
              return root.alarm
            return root.ink
          }
          font.family: root.fontFamily
          font.pixelSize: Commons.Style.font.body
          text: root.remainingText(display ? display.recommendation : null)
        }

        Text {
          visible: display && display.reason
          width: column.width
          wrapMode: Text.WordWrap
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Commons.Style.font.bodySmall
          text: display && display.reason ? display.reason : ""
        }

        Text {
          width: column.width
          wrapMode: Text.WordWrap
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Commons.Style.font.bodySmall
          text: root.fallbackText()
        }

        Repeater {
          model: root.accounts

          delegate: Column {
            width: column.width
            spacing: Commons.Style.space(2)
            property var row: modelData

            Text {
              width: parent.width
              elide: Text.ElideRight
              color: root.ink
              font.family: root.fontFamily
              font.pixelSize: Commons.Style.font.body
              text: (row.display_name || row.provider || "provider") + "  " + (row.account_label || "unknown")
            }

            Text {
              width: parent.width
              wrapMode: Text.WordWrap
              color: row.ok === false || row.freshness === "drift" || row.freshness === "unknown" ? root.alarm : root.ink
              font.family: root.fontFamily
              font.pixelSize: Commons.Style.font.bodySmall
              text: root.remainingText(row) + "  " + root.resetText(row.resets_at)
            }

            Text {
              visible: root.evidenceText(row) !== "" || root.windowText(row) !== ""
              width: parent.width
              wrapMode: Text.WordWrap
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Commons.Style.font.caption
              text: {
                var evidence = root.evidenceText(row)
                var windows = root.windowText(row)
                if (evidence && windows) return evidence + "  " + windows
                return evidence || windows
              }
            }

            Text {
              visible: row.error
              width: parent.width
              wrapMode: Text.WordWrap
              color: root.alarm
              font.family: root.fontFamily
              font.pixelSize: Commons.Style.font.caption
              text: row.error || ""
            }
          }
        }

        Text {
          width: column.width
          color: root.refreshing ? root.dim : root.ink
          font.family: root.fontFamily
          font.pixelSize: Commons.Style.font.body
          text: root.refreshing ? "Refreshing metadata" : "Refresh"

          MouseArea {
            anchors.fill: parent
            enabled: !root.refreshing
            onClicked: root.refreshRequested()
          }
        }

        Text {
          width: column.width
          wrapMode: Text.WordWrap
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Commons.Style.font.caption
          text: "Refresh reads quota metadata. It does not switch an account or run a model."
        }
      }
    }
  }
}
