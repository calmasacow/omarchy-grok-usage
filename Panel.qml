import QtQuick
import QtQuick.Controls
import QtQuick.Effects
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

Panel {
  id: root
  moduleName: "calmasacow.grok-usage"
  ipcTarget: "calmasacow.grok-usage"
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
    var want = selectedProviderId
    if (want === "") want = usage.defaultAgentId
    for (var i = 0; i < providers.length; i++)
      if (providers[i].providerId === want) return i
    return 0
  }
  readonly property var provider: providers.length > 0 ? providers[providerIndex] : null

  property bool cursorActive: false

  // Countdowns and "updated" read this instead of Date.now() so the
  // panel keeps telling the truth while it sits open.
  property double nowMs: Date.now()

  readonly property bool grokSelected: !!provider && provider.providerId === "grok"
  readonly property var grokPool: grokPoolWindow(provider)
  readonly property var grokProducts: grokProductWindows(provider)
  readonly property var limits: grokSelected ? leftoverLimitWindows(provider) : limitWindows(provider)
  readonly property var models: modelRows(provider)
  readonly property var headline: grokSelected && grokPool ? grokPool : bindingWindow(provider)
  readonly property var balance: provider ? (provider.balance || null) : null
  // A prepaid account runs low the way a subscription window fills up: the
  // last 10% of the funded credits lights the same alarm.
  readonly property bool balanceAlarming: !!balance && balance.funded > 0
    && balance.remaining / balance.funded <= 0.1
  readonly property bool alarming: (!!headline && headline.percent >= 0.9) || balanceAlarming
  readonly property color grokBuildColor: "#4C8DFF"
  readonly property color grokChatColor: "#2563EB"

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

  function openLink(url) {
    var href = String(url || "")
    if (href === "") return
    if (root.bar && typeof root.bar.run === "function")
      root.bar.run("xdg-open " + Util.shellQuote(href))
    else
      Qt.openUrlExternally(href)
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
  function limitWindow(label, percent, resetAt, title) {
    return {
      title: String(title || "") !== "" ? String(title) : windowTitle(label),
      percent: Number(percent),
      resetAt: String(resetAt || "")
    }
  }

  function limitWindows(p) {
    if (!p) return []
    var out = []
    var list = p.limits || []
    for (var i = 0; i < list.length; i++) {
      var entry = list[i] || {}
      var percent = Number(entry.percent)
      if (percent >= 0) out.push(limitWindow(entry.label, percent, entry.resetsAt, entry.title))
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

  function isProductLimit(entry) {
    if (!entry) return false
    if (String(entry.kind || "") === "product") return true
    var title = String(entry.title || entry.label || "").toLowerCase()
    return title.indexOf("build") >= 0 || title === "chat" || title.indexOf("grok chat") >= 0
      || title.indexOf("imagine") >= 0 || title.indexOf("voice") >= 0
  }

  function isPoolLimit(entry) {
    if (!entry) return false
    if (String(entry.kind || "") === "pool") return true
    if (isProductLimit(entry)) return false
    return windowIsLong(String(entry.title || entry.label || ""))
  }

  function grokPoolWindow(p) {
    if (!p) return null
    var list = p.limits || []
    for (var i = 0; i < list.length; i++) {
      if (isPoolLimit(list[i]))
        return limitWindow(list[i].label, list[i].percent, list[i].resetsAt, list[i].title)
    }
    return null
  }

  function grokProductWindows(p) {
    if (!p) return []
    var list = p.limits || []
    var out = []
    for (var i = 0; i < list.length; i++) {
      if (!isProductLimit(list[i])) continue
      out.push({
        title: String(list[i].title || list[i].label || "Product"),
        percent: Number(list[i].percent),
        resetAt: String(list[i].resetsAt || "")
      })
    }
    return out
  }

  function leftoverLimitWindows(p) {
    if (!p) return []
    var out = []
    var list = p.limits || []
    for (var i = 0; i < list.length; i++) {
      var entry = list[i] || {}
      if (isPoolLimit(entry) || isProductLimit(entry)) continue
      var percent = Number(entry.percent)
      if (percent >= 0) out.push(limitWindow(entry.label, percent, entry.resetsAt, entry.title))
    }
    return out
  }

  function grokSegmentColor(title, index) {
    var text = String(title || "").toLowerCase()
    if (text.indexOf("build") >= 0) return root.grokBuildColor
    if (text.indexOf("chat") >= 0) return root.grokChatColor
    if (index === 0) return root.grokBuildColor
    return Qt.darker(root.grokBuildColor, 1.25 + index * 0.15)
  }

  function formatResetAt(iso) {
    var parsed = new Date(String(iso || ""))
    if (isNaN(parsed.getTime())) return ""
    var months = ["January", "February", "March", "April", "May", "June",
                  "July", "August", "September", "October", "November", "December"]
    var hours = parsed.getHours()
    var ampm = hours >= 12 ? "PM" : "AM"
    var hour = hours % 12
    if (hour === 0) hour = 12
    var mins = String(parsed.getMinutes()).padStart(2, "0")
    return "Resets " + months[parsed.getMonth()] + " " + parsed.getDate()
      + ", " + parsed.getFullYear() + " at " + hour + ":" + mins + " " + ampm
  }

  function remainingPercent(window) {
    if (!window || !(window.percent >= 0)) return -1
    return root.clamp(1 - window.percent, 0, 1)
  }

  function remainingLabel(window) {
    var left = remainingPercent(window)
    if (left < 0) return ""
    return Math.round(left * 100) + "%"
  }

  function cacheHitRate(p) {
    var usageByModel = p ? (p.modelUsage || {}) : {}
    var read = 0
    var total = 0
    for (var id in usageByModel) {
      var bucket = usageByModel[id] || {}
      var cacheRead = Number(bucket.cacheReadInputTokens || 0)
      read += cacheRead
      total += Number(bucket.inputTokens || 0) + Number(bucket.outputTokens || 0)
        + cacheRead + Number(bucket.cacheCreationInputTokens || 0)
    }
    return total > 0 ? read / total : 0
  }

  function formatCacheHit(n) {
    var rate = Number(n || 0)
    if (!(rate >= 0)) rate = 0
    return (rate * 100).toFixed(1) + "%"
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
    var text = label + " · " + usage.formatTokenCount(Number(day.messageCount || 0)) + " tokens"
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
    contentWidth: panel.fittedContentWidth(Style.space(380))
    // Taller than the control panels on purpose: this one is a dashboard, and
    // the whole point is reading limits and history without scrolling.
    contentHeight: panel.fittedContentHeight(column.implicitHeight, Style.space(900))

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
      onTextKey: function(t) {
        if (t === "r" || t === "R") root.refreshNow()
      }

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

          // ---------- Hero: provider mark · name · plan · remaining ----------
          Item {
            id: header
            visible: !!root.provider
            width: parent.width
            implicitHeight: hero.implicitHeight
            readonly property string amountText: root.remainingLabel(root.headline)
            readonly property color amountColor: root.alarming ? root.urgent : root.foreground
            readonly property color dimColor: root.dim
            readonly property string family: root.fontFamily

            PanelHero {
              id: hero
              width: parent.width
              title: root.provider ? root.provider.providerName : ""
              meta: root.heroMeta(root.provider)
              foreground: root.foreground
              fontFamily: root.fontFamily
              trailingControl: Component {
                Column {
                  visible: header.amountText !== ""
                  spacing: Style.space(2)
                  width: Math.max(heroAmount.implicitWidth, heroRemaining.implicitWidth)

                  Text {
                    id: heroAmount
                    width: parent.width
                    text: header.amountText
                    color: header.amountColor
                    font.family: header.family
                    font.pixelSize: Style.font.title
                    font.bold: true
                    horizontalAlignment: Text.AlignRight
                  }

                  Text {
                    id: heroRemaining
                    width: parent.width
                    text: "REMAINING"
                    color: header.dimColor
                    font.family: header.family
                    font.pixelSize: Style.font.caption
                    font.bold: true
                    font.letterSpacing: 1.2
                    horizontalAlignment: Text.AlignRight
                  }
                }
              }

              iconComponent: Component {
                Item {
                  id: heroMark
                  property var candidates: root.iconCandidatesForProvider(root.provider, root.surface)
                  // Provider objects are rebuilt on every refresh, which churns the
                  // array's identity without changing its content. Restart the fallback
                  // walk only when the URLs change: re-pointing source at a URL whose
                  // load already failed emits no statusChanged, so an identity-only
                  // reset would strand the walker on a missing -light twin.
                  property string candidatesKey: candidates.join("\n")
                  property int candidateIndex: 0
                  onCandidatesKeyChanged: candidateIndex = 0
                  readonly property bool colorize: root.grokSelected

                  width: Style.font.display
                  height: Style.font.display

                  Image {
                    id: heroMarkImage
                    anchors.fill: parent
                    source: heroMark.candidateIndex < heroMark.candidates.length ? heroMark.candidates[heroMark.candidateIndex] : ""
                    sourceSize.width: Style.font.display * 2
                    sourceSize.height: Style.font.display * 2
                    fillMode: Image.PreserveAspectFit
                    visible: status === Image.Ready && !heroMark.colorize
                    layer.enabled: heroMark.colorize
                    // Advancing source from inside its own status change trips the
                    // binding-loop detector; defer the step one tick.
                    onStatusChanged: if (status === Image.Error && heroMark.candidateIndex < heroMark.candidates.length)
                      Qt.callLater(function() { heroMark.candidateIndex++ })
                  }

                  MultiEffect {
                    anchors.fill: heroMarkImage
                    source: heroMarkImage
                    visible: heroMark.colorize && heroMarkImage.status === Image.Ready
                    colorization: 1.0
                    colorizationColor: root.foreground
                  }

                  Text {
                    anchors.centerIn: parent
                    visible: heroMarkImage.status !== Image.Ready
                    text: button.text
                    color: root.foreground
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.display
                  }
                }
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

          // ---------- Provider switch ----------
          Row {
            id: providerSwitch
            visible: root.providers.length > 1
            width: parent.width
            spacing: Style.spacing.md

            readonly property real cellWidth: root.providers.length > 0
              ? (width - spacing * (root.providers.length - 1)) / root.providers.length
              : 0

            Repeater {
              model: root.providers

              Button {
                required property var modelData
                required property int index

                width: providerSwitch.cellWidth
                text: modelData.providerName
                selected: index === root.providerIndex
                hasCursor: root.cursorActive && index === root.providerIndex
                bordered: true
                foreground: root.foreground
                fontFamily: root.fontFamily
                fontSize: Style.font.bodySmall
                verticalPadding: Style.spacing.controlPaddingY
                onClicked: {
                  root.cursorActive = true
                  root.selectProvider(index)
                }
                onHovered: function(isHovered) { if (isHovered) root.cursorActive = true }
              }
            }
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

          // ---------- Weekly SuperGrok meter (grok.com layout) ----------
          PanelSeparator {
            visible: grokMeterSection.visible
            foreground: root.foreground
          }

          Column {
            id: grokMeterSection
            visible: root.grokSelected && !!root.grokPool
            width: parent.width
            spacing: Style.space(10)

            PanelSectionHeader {
              width: parent.width
              text: "WEEKLY SUPERGROK LIMIT"
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

            Item {
              width: parent.width
              implicitHeight: Math.max(usedLabel.implicitHeight, resetLabel.implicitHeight)

              Text {
                id: usedLabel
                text: root.grokPool ? Math.round(root.grokPool.percent * 100) + "% used" : ""
                color: (root.grokPool && root.grokPool.percent >= 0.9) ? root.urgent : root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
                font.bold: true
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
              }

              Text {
                id: resetLabel
                text: root.grokPool ? root.formatResetAt(root.grokPool.resetAt) : ""
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                elide: Text.ElideRight
                horizontalAlignment: Text.AlignRight
                anchors.right: parent.right
                anchors.left: usedLabel.right
                anchors.leftMargin: Style.space(8)
                anchors.verticalCenter: parent.verticalCenter
              }
            }

            SegmentedMeter {
              width: parent.width
              pool: root.grokPool
              segments: root.grokProducts
            }

            Flow {
              id: grokLegend
              width: parent.width
              spacing: Style.space(12)
              visible: root.grokProducts.length > 0

              Repeater {
                model: root.grokProducts

                Row {
                  required property var modelData
                  required property int index
                  spacing: Style.space(6)

                  Rectangle {
                    width: Style.space(8)
                    height: Style.space(8)
                    radius: width / 2
                    color: root.grokSegmentColor(modelData.title, index)
                    anchors.verticalCenter: parent.verticalCenter
                  }

                  Text {
                    text: modelData.title + " " + Math.round(Number(modelData.percent || 0) * 100) + "%"
                    color: root.dim
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                    anchors.verticalCenter: parent.verticalCenter
                  }
                }
              }
            }
          }

          // ---------- Balance / leftover limits ----------
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

          // ---------- Today ----------
          PanelSeparator {
            visible: todaySection.visible
            foreground: root.foreground
          }

          Column {
            id: todaySection
            visible: !!root.provider
            width: parent.width
            spacing: Style.space(10)

            PanelSectionHeader {
              width: parent.width
              text: "TODAY"
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

            Grid {
              id: todayGrid
              width: parent.width
              columns: 2
              columnSpacing: Style.space(8)
              rowSpacing: Style.space(8)

              StatCard {
                width: (todayGrid.width - todayGrid.columnSpacing) / 2
                label: "Tokens"
                value: root.provider ? usage.formatTokenCount(Number(root.provider.todayTotalTokens || 0)) : "—"
              }
              StatCard {
                width: (todayGrid.width - todayGrid.columnSpacing) / 2
                label: "Prompts"
                value: root.provider && root.provider.hasPromptStats !== false
                  ? String(Number(root.provider.todayPrompts || 0))
                  : "—"
              }
            }
          }

          // ---------- Details (always open) ----------
          PanelSeparator {
            visible: detailsSection.visible
            foreground: root.foreground
          }

          Column {
            id: detailsSection
            visible: !!root.provider
            width: parent.width
            spacing: Style.space(10)

            PanelSectionHeader {
              width: parent.width
              text: "DETAILS"
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

            Grid {
              id: detailsGrid
              width: parent.width
              columns: 2
              columnSpacing: Style.space(8)
              rowSpacing: Style.space(8)

              StatCard {
                width: (detailsGrid.width - detailsGrid.columnSpacing) / 2
                label: "Sessions"
                value: root.provider ? String(Number(root.provider.todaySessions || 0)) : "—"
              }
              StatCard {
                width: (detailsGrid.width - detailsGrid.columnSpacing) / 2
                label: "Cache hit"
                value: root.formatCacheHit(root.cacheHitRate(root.provider))
              }
              StatCard {
                width: (detailsGrid.width - detailsGrid.columnSpacing) / 2
                label: "All-time prompts"
                value: root.provider && root.provider.hasPromptStats !== false
                  ? String(Number(root.provider.totalPrompts || 0))
                  : "—"
              }
              StatCard {
                width: (detailsGrid.width - detailsGrid.columnSpacing) / 2
                label: "Active days"
                value: root.provider ? String(Number(root.provider.activeDays || 0)) : "—"
              }
            }

            Column {
              id: modelsList
              visible: root.models.length > 0
              width: parent.width
              spacing: Style.spacing.md

              PanelSectionHeader {
                width: parent.width
                text: "TOP MODELS"
                foreground: root.foreground
                fontFamily: root.fontFamily
              }

              Repeater {
                model: root.models

                ModelRow {
                  required property var modelData
                  width: modelsList.width
                  row: modelData
                  share: modelData.total / Math.max(1, root.models[0].total)
                }
              }
            }
          }

          // ---------- Account links (Grok tab) ----------
          PanelSeparator {
            visible: grokLinksSection.visible
            foreground: root.foreground
          }

          Column {
            id: grokLinksSection
            visible: root.grokSelected
            width: parent.width
            spacing: Style.space(10)

            Row {
              id: linksRow
              width: parent.width
              spacing: Style.space(6)

              readonly property real cellWidth: (width - spacing * 2) / 3

              LinkTile {
                width: linksRow.cellWidth
                icon: "󰐕"
                label: "Add Credits"
                url: "https://grok.com"
              }
              LinkTile {
                width: linksRow.cellWidth
                icon: "󰆍"
                label: "API Console"
                url: "https://console.x.ai"
              }
              LinkTile {
                width: linksRow.cellWidth
                icon: "󰈙"
                label: "Docs"
                url: "https://docs.x.ai"
              }
            }
          }

          Text {
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

  component LinkTile: Item {
    id: linkTile
    property string icon: ""
    property string label: ""
    property string url: ""

    implicitHeight: linkIcon.implicitHeight + linkCaption.implicitHeight + Style.space(10)

    MouseArea {
      id: linkMa
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onClicked: root.openLink(linkTile.url)
    }

    Column {
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      spacing: Style.space(4)

      Text {
        id: linkIcon
        anchors.horizontalCenter: parent.horizontalCenter
        text: linkTile.icon
        color: linkMa.containsMouse ? root.foreground : root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.display
      }

      Text {
        id: linkCaption
        width: parent.width
        text: linkTile.label
        color: linkMa.containsMouse ? root.foreground : root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        horizontalAlignment: Text.AlignHCenter
        wrapMode: Text.WordWrap
      }
    }
  }

  // grok.com weekly meter: unused track, then product segments as adjacent
  // pills (Build bright blue, Chat darker). Falls back to a single fill when
  // the collector has not split the pool yet.
  component SegmentedMeter: Item {
    id: grokMeter
    property var pool: null
    property var segments: []
    property real thickness: Math.max(Style.space(8), Math.round(Style.spacing.controlHeight * 0.22))
    property real gap: Style.space(3)

    implicitHeight: thickness
    readonly property real used: pool ? root.clamp(Number(pool.percent || 0), 0, 1) : 0
    readonly property bool alarming: used >= 0.9

    Rectangle {
      id: grokTrack
      anchors.fill: parent
      radius: height / 2
      color: root.track
    }

    Repeater {
      model: grokMeter.segments.length > 0 ? grokMeter.segments : [{ title: "Weekly", percent: grokMeter.used }]

      Rectangle {
        required property var modelData
        required property int index

        readonly property real start: {
          var x = 0
          for (var i = 0; i < index; i++)
            x += root.clamp(Number(grokMeter.segments.length > 0 ? grokMeter.segments[i].percent : 0), 0, 1)
          return x
        }

        height: grokTrack.height
        radius: height / 2
        y: grokTrack.y
        x: grokTrack.x + start * grokTrack.width + (index > 0 ? grokMeter.gap : 0)
        width: Math.max(0, root.clamp(Number(modelData.percent || 0), 0, 1) * grokTrack.width - (index > 0 ? grokMeter.gap : 0))
        color: grokMeter.alarming ? root.urgent : root.grokSegmentColor(modelData.title, index)

        Behavior on width {
          NumberAnimation { duration: 160; easing.type: Easing.OutCubic }
        }
        Behavior on x {
          NumberAnimation { duration: 160; easing.type: Easing.OutCubic }
        }
      }
    }
  }

  component StatCard: Rectangle {
    id: statCard
    property string label: ""
    property string value: ""

    implicitHeight: statLabel.implicitHeight + statValue.implicitHeight + Style.space(16)
    radius: Style.cornerRadius
    color: root.alpha(root.foreground, 0.05)

    Column {
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      anchors.leftMargin: Style.space(10)
      anchors.rightMargin: Style.space(10)
      spacing: Style.space(2)

      Text {
        id: statLabel
        width: parent.width
        text: statCard.label
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        elide: Text.ElideRight
      }

      Text {
        id: statValue
        width: parent.width
        text: statCard.value
        color: root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.body
        font.bold: true
        elide: Text.ElideRight
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
    }

    Text {
      id: resetText
      width: parent.width
      text: {
        var remainingMs = root.resetMsFor(limitRow.window)
        return remainingMs > 0 ? "Resets in " + root.formatDuration(remainingMs) : ""
      }
      color: root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
    }
  }

  // Rounded track showing the percentage of the allowance used.
  component Meter: Item {
    id: meter
    property real value: -1
    property bool alarming: false
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

  }

  // One row per day: label, bar, tokens. Today is picked out in full
  // foreground so the week reads as a run-up to right now.
  component DayRow: Item {
    id: dayRow
    property var day: null
    property real ratio: 0
    property bool today: false

    implicitHeight: Math.max(dayLabel.implicitHeight, dayValue.implicitHeight) + Style.spacing.sm

    Text {
      id: dayLabel
      text: root.dayLabel(dayRow.day ? dayRow.day.date : "", dayRow.today)
      color: dayRow.today ? root.foreground : root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      font.bold: dayRow.today
      anchors.left: parent.left
      anchors.verticalCenter: parent.verticalCenter
      width: Style.space(52)
    }

    Rectangle {
      id: dayTrack
      anchors.left: dayLabel.right
      anchors.right: dayValue.left
      anchors.leftMargin: Style.space(8)
      anchors.rightMargin: Style.space(10)
      anchors.verticalCenter: parent.verticalCenter
      height: Math.max(Style.space(4), Math.round(Style.spacing.controlHeight * 0.14))
      radius: height / 2
      color: root.track

      Rectangle {
        anchors.left: parent.left
        anchors.verticalCenter: parent.verticalCenter
        height: parent.height
        radius: parent.radius
        width: parent.width * root.clamp(dayRow.ratio, 0, 1)
        color: dayRow.today ? root.foreground : root.alpha(root.foreground, 0.55)

        Behavior on width {
          NumberAnimation { duration: 160; easing.type: Easing.OutCubic }
        }
      }
    }

    Text {
      id: dayValue
      text: usage.formatTokenCount(dayRow.day ? Number(dayRow.day.messageCount || 0) : 0)
      color: dayRow.today ? root.foreground : root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      font.bold: true
      horizontalAlignment: Text.AlignRight
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      width: Style.space(52)
    }

    MouseArea {
      id: dayHover
      anchors.fill: parent
      hoverEnabled: true
      acceptedButtons: Qt.NoButton
    }

    PanelToolTip {
      visible: dayHover.containsMouse
      text: root.dayTooltip(dayRow.day, dayRow.today)
      fontFamily: root.fontFamily
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
