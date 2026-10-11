import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

Panel {
  id: root
  moduleName: "omarchy.agents"
  ipcTarget: "omarchy.agents"
  manageIpc: false

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color urgent: bar ? bar.urgent : Color.urgent
  readonly property color dim: Qt.darker(foreground, 1.55)
  readonly property color surface: Color.popups.background
  readonly property color track: Style.selectedFillFor(foreground, Color.accent)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  readonly property var providers: usage.enabledProviders
  // The selection follows the provider, not the slot it happens to sit in: a
  // provider whose first scan lands while the panel is open would otherwise
  // shift the list underneath you and swap out what you were reading.
  property string selectedProviderId: ""
  readonly property int providerIndex: {
    for (var i = 0; i < providers.length; i++)
      if (providers[i].providerId === selectedProviderId) return i
    return 0
  }
  readonly property var provider: providers.length > 0 ? providers[providerIndex] : null

  property bool cursorActive: false

  // Countdowns and "updated" read this instead of Date.now() so the
  // panel keeps telling the truth while it sits open.
  property double nowMs: Date.now()

  readonly property var limits: limitWindows(provider)
  readonly property var models: modelRows(provider)
  readonly property var headline: bindingWindow(provider)
  readonly property string dayUnit: provider ? String(provider.dayUnit || "tokens") : "tokens"
  readonly property var balance: provider ? (provider.balance || null) : null
  // A prepaid account runs low the way a subscription window fills up: the
  // last 10% of the funded credits lights the same alarm.
  readonly property bool balanceAlarming: !!balance && balance.funded > 0
    && balance.remaining / balance.funded <= 0.1
  readonly property bool alarming: (!!headline && headline.percent >= 0.9) || balanceAlarming

  function clamp(v, lo, hi) { return Math.max(lo, Math.min(hi, v)) }
  function alpha(c, a) { return Qt.rgba(c.r, c.g, c.b, a) }

  function selectProvider(index) {
    if (providers.length === 0) return
    var wrapped = ((index % providers.length) + providers.length) % providers.length
    selectedProviderId = providers[wrapped].providerId
  }

  function refreshNow() {
    usage.refreshAll(true)
  }

  function launchAgent() {
    if (root.bar) root.bar.run("omarchy-agent --pick")
    root.close()
  }

  // ---------------------------------------------------------------- limits
  //
  // Both providers report the same two shapes: a short rolling session window
  // and a long weekly one. Everything below normalizes them into one record so
  // the meters and the hero speak a single language.

  // Claude spells its windows out ("Session (5-hour)"), Codex abbreviates
  // them ("5h window", "30m window"). Both have to land on the same record.
  function windowIsLong(text) {
    return text.indexOf("week") >= 0 || text.indexOf("7-day") >= 0 || text.indexOf("seven") >= 0
      || text.indexOf("month") >= 0 || text.indexOf("30-day") >= 0
  }

  function windowSpanMs(label) {
    var text = String(label || "").toLowerCase()
    if (text.indexOf("month") >= 0 || text.indexOf("30-day") >= 0) return 30 * 24 * 3600 * 1000
    if (windowIsLong(text)) return 7 * 24 * 3600 * 1000
    var hours = text.match(/(\d+)\s*-?\s*h(?:our)?\b/)
    if (hours) return Number(hours[1]) * 3600 * 1000
    var minutes = text.match(/(\d+)\s*-?\s*m(?:in(?:ute)?s?)?\b/)
    if (minutes) return Number(minutes[1]) * 60 * 1000
    return 0
  }

  function windowTitle(label) {
    var text = String(label || "").toLowerCase()
    if (text.indexOf("month") >= 0) return "Monthly"
    if (windowIsLong(text)) return "Weekly"
    if (text.indexOf("session") >= 0 || windowSpanMs(label) > 0) return "Session"
    var plain = String(label || "").replace(/\s*\(.*\)\s*/, "").trim()
    return plain === "" ? "Limit" : plain
  }

  // A collector that already knows which window a limit belongs to says so,
  // and that beats reading it back out of the label: a model-scoped limit is
  // titled after its model, and a name like "Opus 5 (1M context)" would parse
  // as a one-minute window.
  // A collector may also state the window's length outright (Antigravity's
  // pools are titled after their models, not their windows).
  function limitWindow(label, percent, resetAt, title, windowSeconds) {
    var spanMs = Number(windowSeconds) > 0 ? Number(windowSeconds) * 1000
      : (String(title || "") !== "" ? 0 : windowSpanMs(label))
    return {
      title: String(title || "") !== "" ? String(title) : windowTitle(label),
      percent: Number(percent),
      resetAt: String(resetAt || ""),
      spanMs: spanMs
    }
  }

  // The ring has room for one short word.
  function ringCaption(w) {
    if (!w) return "left"
    if (w.spanMs >= 7 * 24 * 3600 * 1000) return "weekly"
    if (w.spanMs > 0) return w.spanMs <= 6 * 3600 * 1000 ? "5-hour" : "session"
    return w.title.toLowerCase()
  }

  // Where usage "should" be if it were spread evenly over the window: the
  // elapsed fraction. -1 when the window's length or reset is unknown.
  function paceMarker(w) {
    if (!w || !(w.spanMs > 0)) return -1
    var remainingMs = resetMsFor(w)
    if (!(remainingMs > 0) || remainingMs > w.spanMs) return -1
    return clamp(1 - remainingMs / w.spanMs, 0, 1)
  }

  function paceText(w) {
    var expected = paceMarker(w)
    if (expected < 0 || expected < 0.02) return ""
    var delta = w.percent - expected
    if (Math.abs(delta) < 0.05) return "on pace"
    return Math.round(Math.abs(delta) * 100) + "% " + (delta > 0 ? "over pace" : "in reserve")
  }

  function limitWindows(p) {
    if (!p) return []
    var out = []
    var list = p.limits || []
    for (var i = 0; i < list.length; i++) {
      var entry = list[i] || {}
      var percent = Number(entry.percent)
      if (percent >= 0) out.push(limitWindow(entry.label, percent, entry.resetsAt, entry.title, entry.windowSeconds))
    }
    return out
  }

  // The window that decides how much room is left — the fullest one, since
  // that is what stops the next prompt.
  function bindingWindow(p) {
    var windows = limitWindows(p)
    var best = null
    for (var i = 0; i < windows.length; i++) {
      if (!best || windows[i].percent > best.percent) best = windows[i]
    }
    return best
  }

  function resetMsFor(w) {
    if (!w || w.resetAt === "") return -1
    var ms = new Date(w.resetAt).getTime()
    return isFinite(ms) ? ms - root.nowMs : -1
  }

  function formatDuration(ms) {
    if (!(ms > 0)) return "now"
    var minutes = Math.floor(ms / 60000)
    var hours = Math.floor(minutes / 60)
    var days = Math.floor(hours / 24)
    if (days > 0) return days + "d " + (hours % 24) + "h"
    if (hours > 0) return hours + "h " + (minutes % 60) + "m"
    return Math.max(1, minutes) + "m"
  }

  // ---------------------------------------------------------------- balance
  //
  // Prepaid agents report a credit ledger instead of rate-limit windows: the
  // record's balance object carries remaining, funded, and spent amounts.

  function currencyPrefix(currency) {
    var code = String(currency || "USD").toUpperCase()
    if (code === "USD") return "$"
    if (code === "EUR") return "€"
    if (code === "GBP") return "£"
    return code + " "
  }

  function formatMoney(value, currency) {
    var amount = Number(value)
    if (!isFinite(amount)) amount = 0
    return currencyPrefix(currency) + amount.toFixed(2)
  }

  function balanceDetailText(b) {
    if (!b || !(b.funded > 0)) return ""
    var text = formatMoney(b.spent, b.currency) + " spent of " + formatMoney(b.funded, b.currency) + " funded"
    if (b.estimated) text += " · estimated"
    return text
  }

  // ---------------------------------------------------------------- content

  // The plan you pay for, under the name of the tool it pays for. Limits live
  // in their own section; the hero just says what this is.
  function heroMeta(p) {
    if (!p) return ""
    if (String(p.usageStatusText || "") !== "") return p.usageStatusText
    var tier = String(p.tierLabel || "")
    if (tier === "") return "Subscription"
    return tier.charAt(0).toUpperCase() + tier.slice(1)
  }

  // Local calendar date, recomputed from nowMs so a panel left open across
  // midnight moves the "Today" row with the clock.
  function todayDate() {
    var now = new Date(root.nowMs)
    return now.getFullYear()
      + "-" + String(now.getMonth() + 1).padStart(2, "0")
      + "-" + String(now.getDate()).padStart(2, "0")
  }

  function dayName(date) {
    var parsed = new Date(String(date || "") + "T00:00:00")
    if (isNaN(parsed.getTime())) return String(date || "")
    return ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"][parsed.getDay()]
  }

  function dayLabel(date, today) {
    if (today) return "Today"
    return dayName(date)
  }

  function dayTooltip(day, today) {
    if (!day) return ""
    var parsed = new Date(String(day.date) + "T00:00:00")
    var label = isNaN(parsed.getTime())
      ? String(day.date)
      : dayName(day.date) + " " + (parsed.getMonth() + 1) + "/" + parsed.getDate()
    var text = label + " · " + formatDayCount(Number(day.messageCount || 0)) + " " + root.dayUnit
    // Prompt and session counts only exist for today, so they ride along here
    // instead of taking a section of their own. Billing-API agents never
    // count prompts, and "0 prompts" would read as a quiet day, not a gap.
    if (today && provider && provider.hasPromptStats !== false)
      text += " · " + Number(provider.todayPrompts || 0) + " prompts · "
        + Number(provider.todaySessions || 0) + " sessions"
    return text
  }

  function weekPeak(p) {
    var days = p ? (p.recentDays || []) : []
    var peak = 0
    for (var i = 0; i < days.length; i++) peak = Math.max(peak, Number(days[i].messageCount || 0))
    return peak
  }

  function weekTotal(p) {
    var days = p ? (p.recentDays || []) : []
    var total = 0
    for (var i = 0; i < days.length; i++) total += Number(days[i].messageCount || 0)
    return total
  }

  function unitIsTokens(p) {
    return !p || String(p.dayUnit || "tokens") === "tokens"
  }

  function formatDayCount(n) {
    return unitIsTokens(provider) ? usage.formatTokenCount(n) : String(Math.round(Number(n) || 0))
  }

  // The three numbers worth a glance before any chart: today's volume, how
  // much of it was you, and how steady the habit is.
  function statTiles(p) {
    if (!p) return []
    var tiles = []
    if (unitIsTokens(p)) tiles.push({ label: "Tokens today", value: usage.formatTokenCount(Number(p.todayTotalTokens || 0)) })
    if (p.hasPromptStats !== false) {
      tiles.push({ label: "Prompts today", value: String(Number(p.todayPrompts || 0)) })
      if (!unitIsTokens(p)) tiles.push({ label: "Sessions today", value: String(Number(p.todaySessions || 0)) })
    }
    tiles.push({ label: "Active days", value: String(Number(p.activeDays || 0)) })
    return tiles
  }

  // The tab strip's one-line answer per agent: the fullest limit, else the
  // credit left, else what today looked like.
  function providerRatio(p) {
    var w = bindingWindow(p)
    if (w) return w.percent
    if (p && p.balance && p.balance.funded > 0) return clamp(1 - p.balance.remaining / p.balance.funded, 0, 1)
    return -1
  }

  function providerAlarming(p) {
    var w = bindingWindow(p)
    if (w && w.percent >= 0.9) return true
    return !!(p && p.balance && p.balance.funded > 0 && p.balance.remaining / p.balance.funded <= 0.1)
  }

  function providerSummary(p) {
    if (!p) return ""
    if (String(p.usageStatusText || "") !== "") return "offline"
    var w = bindingWindow(p)
    if (w) return Math.round(w.percent * 100) + "% used"
    if (p.balance) return formatMoney(p.balance.remaining, p.balance.currency) + " left"
    if (unitIsTokens(p)) return usage.formatTokenCount(Number(p.todayTotalTokens || 0)) + " today"
    return Number(p.todayPrompts || 0) + " today"
  }

  // Canvas wants CSS colors; Qt's "#aarrggbb" spelling would read as RGBA.
  function cssColor(c) {
    return "rgba(" + Math.round(c.r * 255) + "," + Math.round(c.g * 255) + ","
      + Math.round(c.b * 255) + "," + c.a + ")"
  }

  function modelRows(p) {
    var usageByModel = p ? (p.modelUsage || {}) : {}
    var rows = []
    for (var id in usageByModel) {
      var bucket = usageByModel[id] || {}
      var input = Number(bucket.inputTokens || 0)
      var output = Number(bucket.outputTokens || 0)
      var cacheRead = Number(bucket.cacheReadInputTokens || 0)
      var cacheWrite = Number(bucket.cacheCreationInputTokens || 0)
      rows.push({
        name: usage.friendlyModelName(id),
        total: input + output + cacheRead + cacheWrite,
        input: input,
        output: output,
        cacheRead: cacheRead,
        cacheWrite: cacheWrite
      })
    }
    rows.sort(function(a, b) { return b.total - a.total })
    return rows.slice(0, 4)
  }

  function modelTooltip(row) {
    if (!row) return ""
    return "In " + usage.formatTokenCount(row.input)
      + " · out " + usage.formatTokenCount(row.output)
      + " · cache read " + usage.formatTokenCount(row.cacheRead)
      + " · cache write " + usage.formatTokenCount(row.cacheWrite)
  }

  // Only speaks up when the numbers cover more than this machine.
  function footerText() {
    if (usage.syncStatusText !== "") return usage.syncStatusText
    if (provider && provider.syncEnabled && provider.syncDeviceCount > 0)
      return "Merged from " + provider.syncDeviceCount + " device" + (provider.syncDeviceCount === 1 ? "" : "s")
    return ""
  }

  // Agents that ship a white mark carry an `assets/<id>-light.svg` twin for
  // light surfaces; marks that work on both (Claude's brand-orange) ship one
  // file. The luminance check decides which candidate to try first.
  function colorChannelLuminance(value) {
    var channel = Number(value)
    if (!isFinite(channel)) return 0
    return channel <= 0.03928 ? channel / 12.92 : Math.pow((channel + 0.055) / 1.055, 2.4)
  }

  function colorLuminance(color) {
    return 0.2126 * colorChannelLuminance(color.r)
      + 0.7152 * colorChannelLuminance(color.g)
      + 0.0722 * colorChannelLuminance(color.b)
  }

  // Marks resolve by convention, so a new agent's data file needs nothing
  // from this panel: assets/<id>.svg if it ships one, the module's bar glyph
  // if it doesn't.
  function iconCandidatesForProvider(p, surfaceColor) {
    if (!p) return []
    var candidates = []
    if (colorLuminance(surfaceColor || Color.background) >= 0.5)
      candidates.push(Qt.resolvedUrl("assets/" + p.providerId + "-light.svg"))
    candidates.push(Qt.resolvedUrl("assets/" + p.providerId + ".svg"))
    // Full-color app icons (Antigravity) ship as a PNG rather than a mark.
    candidates.push(Qt.resolvedUrl("assets/" + p.providerId + ".png"))
    return candidates
  }

  // Nothing to report, nothing in the bar: Bar.qml collapses a slot whose item
  // is invisible, so the icon appears the moment the first scan finds usage and
  // stays away entirely on a machine that has never run either CLI.
  visible: providers.length > 0
  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  onProviderIndexChanged: if (panelFlick) panelFlick.contentY = 0
  onOpenedChanged: if (opened) {
    cursorActive = false
    nowMs = Date.now()
    if (panelFlick) panelFlick.contentY = 0
    usage.refreshLimits()
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  Main {
    id: usage
    settings: root.settings
  }

  // Cheap enough to keep running: it only re-evaluates text bindings, and a
  // stale "resets in 2h" on a panel that is open is worse than a timer.
  Timer {
    interval: 30000
    running: root.opened
    repeat: true
    onTriggered: root.nowMs = Date.now()
  }

  IpcHandler {
    target: root.ipcTarget
    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function toggle(): void { root.toggle() }
    function refresh(): string { root.refreshNow(); return "ok" }
    function next(): string { root.selectProvider(root.providerIndex + 1); return "ok" }
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: "󱚣"
    active: root.alarming
    onPressed: function(buttonCode) {
      if (buttonCode === Qt.RightButton) root.launchAgent()
      else if (buttonCode === Qt.MiddleButton) root.selectProvider(root.providerIndex + 1)
      else root.toggle()
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(400))
    // Taller than the control panels on purpose: this one is a dashboard, and
    // the whole point is reading limits and history without scrolling.
    contentHeight: panel.fittedContentHeight(column.implicitHeight, Style.space(640))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent

      onMoveRequested: function(dx, dy) {
        if (dx !== 0) {
          root.cursorActive = true
          root.selectProvider(root.providerIndex + dx)
        }
        if (dy !== 0)
          panelFlick.contentY = root.clamp(panelFlick.contentY + dy * Style.space(56), 0,
                                           Math.max(0, panelFlick.contentHeight - panelFlick.height))
      }
      onActivateRequested: root.refreshNow()
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onTextKey: function(t) { if (t === "r" || t === "R") root.refreshNow() }

      Flickable {
        id: panelFlick
        anchors.fill: parent
        contentWidth: width
        contentHeight: column.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        flickableDirection: Flickable.VerticalFlick
        interactive: contentHeight > height
        ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

        Column {
          id: column
          width: panelFlick.width
          spacing: Style.space(12)

          // ---------- Agent tabs: mark · name · one-line state ----------
          Row {
            id: providerTabs
            visible: root.providers.length > 1
            width: parent.width
            spacing: Style.space(6)

            readonly property real cellWidth: root.providers.length > 0
              ? (width - spacing * (root.providers.length - 1)) / root.providers.length
              : 0

            Repeater {
              model: root.providers

              ProviderTab {
                required property var modelData
                required property int index
                width: providerTabs.cellWidth
                provider: modelData
                tabIndex: index
              }
            }
          }

          // ---------- Hero: provider mark · name · plan · gauge ----------
          PanelHero {
            id: hero
            visible: !!root.provider
            width: parent.width
            title: root.provider ? root.provider.providerName : ""
            meta: root.heroMeta(root.provider)
            foreground: root.foreground
            fontFamily: root.fontFamily

            iconComponent: Component {
              ProviderMark {
                provider: root.provider
                size: Style.font.display
              }
            }

            // The fullest limit (or the credit left) as a ring, so the answer to
            // "can I keep going?" is the first thing the panel shows.
            trailingControl: Component {
              RingGauge {
                visible: value >= 0
                value: root.headline ? root.headline.percent
                  : (root.balance && root.balance.funded > 0
                     ? root.clamp(root.balance.remaining / root.balance.funded, 0, 1) : -1)
                alarming: root.alarming
                label: root.headline ? Math.round(root.headline.percent * 100) + "%"
                  : (root.balance ? root.formatMoney(root.balance.remaining, root.balance.currency).replace(/\.\d+$/, "") : "")
                caption: root.ringCaption(root.headline)
              }
            }
          }

          Text {
            visible: root.providers.length === 0
            width: parent.width
            topPadding: Style.space(24)
            text: "No AI coding subscriptions found.\nAgents show up here once you've used them."
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
            horizontalAlignment: Text.AlignHCenter
            wrapMode: Text.WordWrap
          }

          // ---------- Status ----------
          BorderSurface {
            visible: !!root.provider && String(root.provider.usageStatusText || "") !== ""
            width: parent.width
            implicitHeight: statusText.implicitHeight + Style.spacing.xl * 2
            color: root.alpha(root.urgent, 0.10)
            borderSpec: Border.flat(root.alpha(root.urgent, 0.35), 1)
            radius: Style.cornerRadius

            Text {
              id: statusText
              textFormat: Text.PlainText
              anchors.left: parent.left
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              anchors.leftMargin: Style.space(12)
              anchors.rightMargin: Style.space(12)
              text: root.provider ? String(root.provider.authHelpText || "") : ""
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              wrapMode: Text.WordWrap
            }
          }

          // ---------- Today at a glance ----------
          Row {
            id: statRow
            readonly property var tiles: root.statTiles(root.provider)
            visible: tiles.length > 0 && !!root.provider && root.provider.hasLocalStats !== false
            width: parent.width
            spacing: Style.space(6)

            Repeater {
              model: statRow.tiles

              StatTile {
                required property var modelData
                width: (statRow.width - statRow.spacing * (statRow.tiles.length - 1)) / statRow.tiles.length
                label: modelData.label
                value: modelData.value
              }
            }
          }

          // ---------- Balance / limits ----------
          PanelSeparator {
            visible: balanceSection.visible || limitsSection.visible
            foreground: root.foreground
          }

          Column {
            id: balanceSection
            visible: !!root.balance
            width: parent.width
            spacing: Style.space(10)

            // The meter shows what is left, not what is used: a prepaid
            // account drains toward empty rather than filling toward a cap.
            readonly property real ratio: root.balance && root.balance.funded > 0
              ? root.clamp(root.balance.remaining / root.balance.funded, 0, 1)
              : -1

            PanelSectionHeader {
              width: parent.width
              text: "BALANCE"
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

            Item {
              width: parent.width
              implicitHeight: Math.max(balanceLabel.implicitHeight, balanceValue.implicitHeight)

              Text {
                id: balanceLabel
                text: "Prepaid credits"
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
              }

              Text {
                id: balanceValue
                textFormat: Text.PlainText
                text: root.balance ? root.formatMoney(root.balance.remaining, root.balance.currency) : ""
                color: root.balanceAlarming ? root.urgent : root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
              }
            }

            Meter {
              visible: balanceSection.ratio >= 0
              width: parent.width
              value: balanceSection.ratio
              alarming: root.balanceAlarming
            }

            Text {
              textFormat: Text.PlainText
              visible: text !== ""
              width: parent.width
              text: root.balanceDetailText(root.balance)
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
            }
          }

          Column {
            id: limitsSection
            visible: root.limits.length > 0
            width: parent.width
            spacing: Style.space(10)

            PanelSectionHeader {
              text: "LIMITS"
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

            Repeater {
              model: root.limits

              LimitRow {
                required property var modelData
                width: limitsSection.width
                window: modelData
              }
            }
          }

          // ---------- Usage ----------
          PanelSeparator {
            visible: usageSection.visible
            foreground: root.foreground
          }

          Column {
            id: usageSection
            visible: !!root.provider && root.provider.recentDays && root.provider.recentDays.length > 0
            width: parent.width
            spacing: Style.spacing.md

            Item {
              width: parent.width
              implicitHeight: usageHeader.implicitHeight

              PanelSectionHeader {
                id: usageHeader
                anchors.left: parent.left
                text: root.dayUnit.toUpperCase() + " · LAST 7 DAYS"
                foreground: root.foreground
                fontFamily: root.fontFamily
              }

              Text {
                textFormat: Text.PlainText
                anchors.right: parent.right
                anchors.bottom: usageHeader.bottom
                text: root.formatDayCount(root.weekTotal(root.provider)) + " total"
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                font.bold: true
              }
            }

            DayChart {
              width: parent.width
              days: root.provider ? (root.provider.recentDays || []) : []
              peak: Math.max(1, root.weekPeak(root.provider))
            }
          }

          // ---------- Models ----------
          PanelSeparator {
            visible: modelSection.visible
            foreground: root.foreground
          }

          Column {
            id: modelSection
            visible: root.models.length > 0
            width: parent.width
            spacing: Style.spacing.md

            PanelSectionHeader {
              width: parent.width
              text: "TOKENS BY MODEL"
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

            Repeater {
              model: root.models

              ModelRow {
                required property var modelData
                width: modelSection.width
                row: modelData
                // Scaled to the heaviest model, so the top row is always full —
                // the same scale-to-peak the weekly chart uses for its busiest day.
                share: modelData.total / Math.max(1, root.models[0].total)
              }
            }
          }

          Text {
            textFormat: Text.PlainText
            visible: text !== ""
            width: parent.width
            topPadding: Style.space(2)
            text: root.footerText()
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            horizontalAlignment: Text.AlignHCenter
            elide: Text.ElideRight
          }
        }
      }
    }
  }

  // A limit window: label and percentage, meter, and reset countdown.
  component LimitRow: Column {
    id: limitRow
    property var window: null

    readonly property bool alarming: window && window.percent >= 0.9

    spacing: Style.space(6)

    Item {
      width: parent.width
      implicitHeight: Math.max(limitLabel.implicitHeight, limitValue.implicitHeight)

      Text {
        id: limitLabel
        textFormat: Text.PlainText
        // A model-scoped window is titled after its model, and those names run
        // long enough to reach the percentage, so the title gives way first.
        text: limitRow.window ? limitRow.window.title : ""
        color: root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.body
        elide: Text.ElideRight
        anchors.left: parent.left
        anchors.right: limitValue.left
        anchors.rightMargin: Style.spacing.sm
        anchors.verticalCenter: parent.verticalCenter
      }

      Text {
        id: limitValue
        textFormat: Text.PlainText
        text: limitRow.window && limitRow.window.percent >= 0
          ? Math.round(limitRow.window.percent * 100) + "%"
          : "—"
        color: limitRow.alarming ? root.urgent : root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
      }
    }

    Meter {
      width: parent.width
      value: limitRow.window ? limitRow.window.percent : -1
      alarming: limitRow.alarming
      marker: root.paceMarker(limitRow.window)
    }

    Item {
      width: parent.width
      implicitHeight: Math.max(resetText.implicitHeight, paceLabel.implicitHeight)
      visible: resetText.text !== "" || paceLabel.text !== ""

      Text {
        id: resetText
        textFormat: Text.PlainText
        anchors.left: parent.left
        text: {
          var remainingMs = root.resetMsFor(limitRow.window)
          return remainingMs > 0 ? "Resets in " + root.formatDuration(remainingMs) : ""
        }
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
      }

      // Usage measured against the tick on the meter: how far the window has
      // run. Over pace is the early warning before the meter turns red.
      Text {
        id: paceLabel
        textFormat: Text.PlainText
        anchors.right: parent.right
        text: root.paceText(limitRow.window)
        color: text.indexOf("over") >= 0 ? root.urgent : root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
      }
    }
  }

  // Rounded track showing the percentage of the allowance used.
  component Meter: Item {
    id: meter
    property real value: -1
    property bool alarming: false
    property real marker: -1
    property real thickness: Math.max(Style.space(4), Math.round(Style.spacing.controlHeight * 0.14))

    implicitHeight: thickness

    Rectangle {
      id: meterTrack
      anchors.fill: parent
      radius: height / 2
      color: root.track
    }

    Rectangle {
      anchors.left: meterTrack.left
      anchors.verticalCenter: meterTrack.verticalCenter
      height: meterTrack.height
      radius: meterTrack.radius
      width: meterTrack.width * root.clamp(meter.value, 0, 1)
      color: meter.alarming ? root.urgent : root.foreground

      Behavior on width {
        NumberAnimation { duration: 160; easing.type: Easing.OutCubic }
      }
    }

    // Optional pace tick: where usage would sit if spread evenly over the window.
    Rectangle {
      visible: meter.marker >= 0
      x: Math.round(meterTrack.width * root.clamp(meter.marker, 0, 1) - width / 2)
      anchors.verticalCenter: meterTrack.verticalCenter
      width: Math.max(2, Math.round(meter.thickness * 0.45))
      height: meter.thickness + Style.space(6)
      radius: width / 2
      color: root.dim
    }
  }

  // The agent's mark: assets/<id>[-light].svg, then a PNG app icon, then the
  // bar glyph when the agent ships no art at all.
  component ProviderMark: Item {
    id: mark
    property var provider: null
    property real size: Style.font.display

    property var candidates: root.iconCandidatesForProvider(mark.provider, root.surface)
    // Provider objects are rebuilt on every refresh, which churns the
    // array's identity without changing its content. Restart the fallback
    // walk only when the URLs change: re-pointing source at a URL whose
    // load already failed emits no statusChanged, so an identity-only
    // reset would strand the walker on a missing -light twin.
    property string candidatesKey: candidates.join("\n")
    property int candidateIndex: 0
    onCandidatesKeyChanged: candidateIndex = 0

    implicitWidth: size
    implicitHeight: size

    Image {
      id: markImage
      anchors.fill: parent
      source: mark.candidateIndex < mark.candidates.length ? mark.candidates[mark.candidateIndex] : ""
      sourceSize.width: mark.size * 2
      sourceSize.height: mark.size * 2
      fillMode: Image.PreserveAspectFit
      smooth: true
      mipmap: true
      // Advancing source from inside its own status change trips the
      // binding-loop detector; defer the step one tick. Step only if the
      // failed URL is still current: a provider switch in that tick resets
      // the walk, and a stale step would skip the new provider's first mark.
      onStatusChanged: if (status === Image.Error && mark.candidateIndex < mark.candidates.length) {
        var failed = String(source)
        Qt.callLater(function() { if (String(markImage.source) === failed) mark.candidateIndex++ })
      }
    }

    Text {
      textFormat: Text.PlainText
      anchors.centerIn: parent
      visible: markImage.status !== Image.Ready
      text: button.text
      color: root.foreground
      font.family: root.fontFamily
      font.pixelSize: mark.size
    }
  }

  // One agent in the tab strip. The thin meter along the bottom is that
  // agent's fullest limit, so the whole fleet reads at a glance without
  // switching tabs.
  component ProviderTab: Item {
    id: tab
    property var provider: null
    property int tabIndex: 0

    readonly property bool selected: tabIndex === root.providerIndex
    readonly property bool hot: tabMouse.containsMouse || (root.cursorActive && selected)
    readonly property real ratio: root.providerRatio(provider)
    readonly property bool tabAlarming: root.providerAlarming(provider)

    implicitHeight: tabColumn.implicitHeight + Style.space(14)

    Rectangle {
      anchors.fill: parent
      radius: Style.cornerRadius
      color: tab.selected ? root.track
        : (tab.hot ? root.alpha(root.foreground, 0.06) : root.alpha(root.foreground, 0.025))
      border.width: 1
      border.color: tab.selected ? root.alpha(tab.tabAlarming ? root.urgent : root.foreground, 0.45)
        : root.alpha(root.foreground, tab.hot ? 0.18 : 0.08)

      Behavior on color { ColorAnimation { duration: 120 } }
    }

    Column {
      id: tabColumn
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      anchors.leftMargin: Style.space(8)
      anchors.rightMargin: Style.space(8)
      spacing: Style.space(5)

      Item {
        width: parent.width
        implicitHeight: Math.max(tabMark.implicitHeight, tabLabels.implicitHeight)

        ProviderMark {
          id: tabMark
          anchors.left: parent.left
          anchors.verticalCenter: parent.verticalCenter
          provider: tab.provider
          size: Style.font.title
          opacity: tab.selected || tab.hot ? 1 : 0.7
        }

        Column {
          id: tabLabels
          anchors.left: tabMark.right
          anchors.leftMargin: Style.space(6)
          anchors.right: parent.right
          anchors.verticalCenter: parent.verticalCenter
          spacing: 0

          Text {
            textFormat: Text.PlainText
            width: parent.width
            text: tab.provider ? tab.provider.providerName : ""
            color: tab.selected ? root.foreground : root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            font.bold: tab.selected
            elide: Text.ElideRight
          }

          Text {
            textFormat: Text.PlainText
            width: parent.width
            text: root.providerSummary(tab.provider)
            color: tab.tabAlarming ? root.urgent : root.dim
            opacity: tab.tabAlarming ? 1 : 0.8
            font.family: root.fontFamily
            font.pixelSize: Math.round(Style.font.caption * 0.9)
            elide: Text.ElideRight
          }
        }
      }

      Meter {
        width: parent.width
        thickness: Style.space(3)
        // A tab with nothing to measure keeps an empty track so the strip
        // stays aligned.
        value: Math.max(0, tab.ratio)
        alarming: tab.tabAlarming
      }
    }

    MouseArea {
      id: tabMouse
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onClicked: {
        root.cursorActive = true
        root.selectProvider(tab.tabIndex)
      }
    }
  }

  // Ring gauge for the hero: big number in the middle, what it measures under it.
  component RingGauge: Item {
    id: ring
    property real value: -1
    property bool alarming: false
    property string label: ""
    property string caption: ""

    implicitWidth: Style.space(54)
    implicitHeight: Style.space(54)

    Canvas {
      id: ringCanvas
      anchors.fill: parent
      antialiasing: true

      property real shown: root.clamp(ring.value, 0, 1)
      property color trackColor: root.track
      property color fillColor: ring.alarming ? root.urgent : root.foreground

      Behavior on shown { NumberAnimation { duration: 320; easing.type: Easing.OutCubic } }
      onShownChanged: requestPaint()
      onTrackColorChanged: requestPaint()
      onFillColorChanged: requestPaint()
      onWidthChanged: requestPaint()
      onHeightChanged: requestPaint()

      onPaint: {
        var ctx = getContext("2d")
        ctx.reset()
        var lineWidth = Math.max(3, Math.round(width * 0.085))
        var radius = (Math.min(width, height) - lineWidth) / 2
        var cx = width / 2
        var cy = height / 2
        var start = -Math.PI / 2
        ctx.lineWidth = lineWidth
        ctx.lineCap = "round"

        ctx.strokeStyle = root.cssColor(trackColor)
        ctx.beginPath()
        ctx.arc(cx, cy, radius, 0, Math.PI * 2)
        ctx.stroke()

        if (shown > 0.001) {
          ctx.strokeStyle = root.cssColor(fillColor)
          ctx.beginPath()
          ctx.arc(cx, cy, radius, start, start + Math.PI * 2 * shown)
          ctx.stroke()
        }
      }
    }

    Column {
      anchors.centerIn: parent
      spacing: 0

      Text {
        textFormat: Text.PlainText
        anchors.horizontalCenter: parent.horizontalCenter
        text: ring.label
        color: ring.alarming ? root.urgent : root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.bodySmall
        font.bold: true
      }

      Text {
        textFormat: Text.PlainText
        anchors.horizontalCenter: parent.horizontalCenter
        visible: text !== ""
        text: ring.caption
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Math.round(Style.font.caption * 0.85)
      }
    }
  }

  // A number with its label under it.
  component StatTile: Item {
    id: tile
    property string label: ""
    property string value: ""

    implicitHeight: tileColumn.implicitHeight + Style.space(10)

    Rectangle {
      anchors.fill: parent
      radius: Style.cornerRadius
      color: root.alpha(root.foreground, 0.04)
      border.width: 1
      border.color: root.alpha(root.foreground, 0.08)
    }

    Column {
      id: tileColumn
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      anchors.leftMargin: Style.space(10)
      anchors.rightMargin: Style.space(10)
      spacing: Style.space(1)

      Text {
        textFormat: Text.PlainText
        width: parent.width
        text: tile.value
        color: root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.title
        font.bold: true
        elide: Text.ElideRight
      }

      Text {
        textFormat: Text.PlainText
        width: parent.width
        text: tile.label
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        elide: Text.ElideRight
      }
    }
  }

  // The week as columns, oldest on the left, today at the right edge in full
  // foreground. Each column scales to the busiest day; hover for the number.
  component DayChart: Item {
    id: chart
    property var days: []
    property real peak: 1

    readonly property real gap: Style.space(6)
    readonly property real columnWidth: days.length > 0 ? (width - gap * (days.length - 1)) / days.length : 0

    implicitHeight: Style.space(78)

    Row {
      anchors.fill: parent
      spacing: chart.gap

      Repeater {
        model: chart.days

        Item {
          id: column
          required property var modelData
          required property int index

          readonly property real count: Number(modelData.messageCount || 0)
          readonly property bool today: String(modelData.date || "") === root.todayDate()
          readonly property real ratio: root.clamp(count / chart.peak, 0, 1)

          width: chart.columnWidth
          height: chart.height

          Text {
            id: columnLabel
            textFormat: Text.PlainText
            anchors.bottom: parent.bottom
            anchors.horizontalCenter: parent.horizontalCenter
            text: column.today ? "Today" : root.dayName(column.modelData.date)
            color: column.today ? root.foreground : root.dim
            font.family: root.fontFamily
            font.pixelSize: Math.round(Style.font.caption * 0.9)
            font.bold: column.today
          }

          Text {
            id: columnValue
            textFormat: Text.PlainText
            anchors.horizontalCenter: parent.horizontalCenter
            anchors.bottom: columnTrack.top
            anchors.bottomMargin: Style.space(2)
            // Only the hovered day and today carry a number, so the chart
            // stays a shape rather than a table.
            visible: column.today || columnHover.containsMouse
            text: root.formatDayCount(column.count)
            color: column.today ? root.foreground : root.dim
            font.family: root.fontFamily
            font.pixelSize: Math.round(Style.font.caption * 0.85)
            font.bold: true
          }

          Rectangle {
            id: columnTrack
            anchors.horizontalCenter: parent.horizontalCenter
            anchors.bottom: columnLabel.top
            anchors.bottomMargin: Style.space(5)
            width: Math.min(parent.width, Style.space(26))
            height: parent.height - columnLabel.implicitHeight - columnValue.implicitHeight - Style.space(9)
            radius: Math.min(width / 2, Style.space(5))
            color: root.alpha(root.foreground, columnHover.containsMouse ? 0.09 : 0.05)

            Rectangle {
              anchors.left: parent.left
              anchors.right: parent.right
              anchors.bottom: parent.bottom
              height: column.count > 0 ? Math.max(Style.space(3), parent.height * column.ratio) : 0
              radius: parent.radius
              color: column.today ? root.foreground
                : root.alpha(root.foreground, columnHover.containsMouse ? 0.7 : 0.42)

              Behavior on height {
                NumberAnimation { duration: 220; easing.type: Easing.OutCubic }
              }
            }
          }

          MouseArea {
            id: columnHover
            anchors.fill: parent
            hoverEnabled: true
            acceptedButtons: Qt.NoButton
          }

          PanelToolTip {
            visible: columnHover.containsMouse
            text: root.dayTooltip(column.modelData, column.today)
            fontFamily: root.fontFamily
          }
        }
      }
    }
  }

  // Model rows read as a table: the share bar fills the row behind the label
  // instead of stacking under it, which keeps the whole dashboard on one screen.
  component ModelRow: Item {
    id: modelRow
    property var row: null
    property real share: 0

    implicitHeight: modelName.implicitHeight + Style.spacing.lg

    Rectangle {
      anchors.fill: parent
      radius: Style.cornerRadius
      color: root.alpha(root.foreground, 0.05)
    }

    Rectangle {
      anchors.left: parent.left
      anchors.top: parent.top
      anchors.bottom: parent.bottom
      width: parent.width * root.clamp(modelRow.share, 0, 1)
      radius: Style.cornerRadius
      color: root.alpha(root.foreground, 0.14)

      Behavior on width {
        NumberAnimation { duration: 160; easing.type: Easing.OutCubic }
      }
    }

    Text {
      id: modelName
      textFormat: Text.PlainText
      text: modelRow.row ? modelRow.row.name : ""
      color: root.foreground
      font.family: root.fontFamily
      font.pixelSize: Style.font.bodySmall
      elide: Text.ElideRight
      anchors.left: parent.left
      anchors.leftMargin: Style.space(8)
      anchors.right: modelTokens.left
      anchors.rightMargin: Style.space(8)
      anchors.verticalCenter: parent.verticalCenter
    }

    Text {
      id: modelTokens
      textFormat: Text.PlainText
      text: modelRow.row ? usage.formatTokenCount(modelRow.row.total) : ""
      color: root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.bodySmall
      font.bold: true
      anchors.right: parent.right
      anchors.rightMargin: Style.space(8)
      anchors.verticalCenter: parent.verticalCenter
    }

    MouseArea {
      id: modelHover
      anchors.fill: parent
      hoverEnabled: true
      acceptedButtons: Qt.NoButton
    }

    PanelToolTip {
      visible: modelHover.containsMouse
      text: root.modelTooltip(modelRow.row)
      fontFamily: root.fontFamily
    }
  }
}
