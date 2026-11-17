import QtQuick
import QtCore as Core
import QtQuick.Controls as Controls
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Commons as Commons
import qs.Ui

BarWidget {
  id: root
  moduleName: "kel.plugin-manager"

  Commons.Translations {
    id: strings
    directory: Qt.resolvedUrl("i18n")
  }

  // Stored outside the plugin folder so saving preferences doesn't hot-reload the plugin.
  Core.Settings {
    id: preferences
    location: "file://" + (Quickshell.env("XDG_CONFIG_HOME") || (Quickshell.env("HOME") + "/.config"))
      + "/omarchy/plugin-manager/settings.ini"
    property bool defaultDisabledOnly: false
    property bool defaultUserInstalledOnly: false
    property bool hideNative: false
    property string iconColorRule: "any"
    property bool showBarCount: false
    property int retentionDays: 0
    property bool skipUninstallConfirm: false
    onRetentionDaysChanged: root.nextRetentionCheck = 0
  }

  property double nextRetentionCheck: 0
  property bool historyLoaded: false
  property bool pendingDeleteAll: false
  property real backupSize: 0
  readonly property var visiblePlugins: preferences.hideNative
    ? plugins.filter(function(plugin) { return !plugin.firstParty }) : plugins
  readonly property int iconDisabledCount: plugins.filter(function(plugin) {
    return !plugin.enabled && (preferences.iconColorRule !== "user" || !plugin.firstParty)
  }).length
  readonly property bool iconHighlighted: preferences.iconColorRule !== "never" && iconDisabledCount > 0
  readonly property bool barCountVisible: preferences.showBarCount && iconDisabledCount > 0 && !root.vertical

  function formatBytes(bytes) {
    var units = ["B", "KB", "MB", "GB", "TB"]
    var index = 0
    while (bytes >= 1024 && index < units.length - 1) {
      bytes /= 1024
      index++
    }
    return Commons.I18n.formatNumber(bytes, index === 0 ? 0 : 1) + " " + units[index]
  }

  property bool popupOpen: false
  readonly property bool opened: popupOpen
  property bool settingsOpen: false
  property var plugins: []
  property var selectedIds: []
  property string filterText: ""
  property bool showDisabledOnly: false
  property bool showUserInstalledOnly: false
  property string statusText: ""
  property string requestType: ""
  property string commandProgram: "omarchy"
  property var commandArgs: []
  property var actionQueue: []
  property int actionIndex: 0
  property var pendingUninstallIds: []
  property string pendingSection: ""
  property string currentSection: "right"
  property bool showHistory: false
  property var uninstallHistory: []
  property var pendingHistoryDelete: null
  property bool historyBusy: false
  property bool historyReading: false
  property string historyMode: "list"
  property var historyRequest: ({})
  property string lastHistoryToken: ""
  property string omarchyVersion: ""
  readonly property string repositoryUrl: "https://github.com/kelmankenberg/Omarchy-Plugin-Manager"
  readonly property string pluginVersion: {
    try {
      var version = String(JSON.parse(manifestFile.text()).version || "")
      return /^[0-9A-Za-z.+-]{1,32}$/.test(version) ? version : ""
    } catch (error) {
      return ""
    }
  }
  readonly property bool busy: helper.running || actionQueue.length > 0
    || historyBusy || historyReading

  Component.onCompleted: {
    readSection()
    refreshHistory()
    versionReader.running = true
  }

  function openIssue(template) {
    var url = repositoryUrl + "/issues/new?template=" + template
      + "&version=" + encodeURIComponent(pluginVersion)
      + "&omarchy-version=" + encodeURIComponent(omarchyVersion)
    Util.execArgv(["xdg-open", url])
    close()
  }

  readonly property int disabledCount: visiblePlugins.filter(function(plugin) { return !plugin.enabled }).length
  readonly property var selectedPlugins: visiblePlugins.filter(function(plugin) {
    return selectedIds.indexOf(plugin.id) !== -1
  })
  readonly property var filteredPlugins: visiblePlugins.filter(function(plugin) {
    var needle = filterText.trim().toLowerCase()
    var matchesText = !needle || (plugin.name + " " + plugin.id).toLowerCase().indexOf(needle) !== -1
    return matchesText && (!showDisabledOnly || !plugin.enabled)
      && (!showUserInstalledOnly || !plugin.firstParty)
  })
  readonly property int selectedCount: selectedPlugins.length
  readonly property int enableCount: selectedPlugins.filter(function(plugin) {
    return plugin.id !== root.moduleName && plugin.canDisable && !plugin.enabled
  }).length
  readonly property int disableCount: selectedPlugins.filter(function(plugin) {
    return plugin.id !== root.moduleName && plugin.canDisable && plugin.enabled
  }).length
  readonly property int removableCount: selectedPlugins.filter(function(plugin) {
    return plugin.id !== root.moduleName && !plugin.firstParty && plugin.kinds.indexOf("bar") === -1
  }).length
  readonly property var selectableIds: filteredPlugins.filter(function(plugin) {
    return plugin.id !== root.moduleName && plugin.canDisable
  }).map(function(plugin) { return plugin.id })

  function countText(key, count) {
    return strings.tn(key, count).arg(Commons.I18n.formatNumber(count))
  }

  function selected(id) {
    return selectedIds.indexOf(id) !== -1
  }

  function toggleSelected(id) {
    if (id === moduleName) return
    var next = selectedIds.slice()
    var index = next.indexOf(id)
    if (index === -1) next.push(id)
    else next.splice(index, 1)
    selectedIds = next
  }

  function toggleSelectAll() {
    var next = selectedIds.slice()
    var allSelected = selectableIds.length > 0
      && selectableIds.every(function(id) { return next.indexOf(id) !== -1 })
    if (allSelected) {
      next = next.filter(function(id) { return selectableIds.indexOf(id) === -1 })
    } else {
      selectableIds.forEach(function(id) {
        if (next.indexOf(id) === -1) next.push(id)
      })
    }
    selectedIds = next
  }

  function open() {
    popupOpen = true
    showDisabledOnly = preferences.defaultDisabledOnly
    showUserInstalledOnly = preferences.defaultUserInstalledOnly
    nextRetentionCheck = 0
    refresh()
    refreshHistory()
  }

  function close() {
    popupOpen = false
    settingsOpen = false
    pendingUninstallIds = []
    pendingHistoryDelete = null
    pendingDeleteAll = false
  }

  function toggle() {
    if (popupOpen) close()
    else open()
  }

  function refresh(showLoading) {
    if (helper.running || actionQueue.length || historyBusy) return
    if (showLoading !== false) statusText = strings.t("loading")
    requestType = "list"
    commandProgram = "omarchy"
    commandArgs = ["plugin", "list", "--json"]
    helper.running = true
  }

  function readSection() {
    requestType = "section"
    commandProgram = "jq"
    commandArgs = [
      "-r",
      "--arg", "id", moduleName,
      "first(.bar.layout | to_entries[] | select(any(.value[]?; (.id // .) == $id)) | .key) // empty",
      Quickshell.env("HOME") + "/.config/omarchy/shell.json"
    ]
    helper.running = true
  }

  function startBatch(action) {
    if (busy) return
    var targets = []
    if (action === "enable") {
      targets = selectedPlugins.filter(function(plugin) {
        return plugin.id !== root.moduleName && plugin.canDisable && !plugin.enabled
      })
    } else if (action === "disable") {
      targets = selectedPlugins.filter(function(plugin) {
        return plugin.id !== root.moduleName && plugin.canDisable && plugin.enabled
      })
    } else if (action === "remove") {
      targets = selectedPlugins.filter(function(plugin) {
        return plugin.id !== root.moduleName && !plugin.firstParty && plugin.kinds.indexOf("bar") === -1
      })
      if (targets.length) {
        if (preferences.skipUninstallConfirm) {
          startHistoryAction({ action: "uninstall", ids: targets.map(function(plugin) { return plugin.id }) })
          return
        }
        pendingUninstallIds = targets.map(function(plugin) { return plugin.id })
        return
      }
    }
    if (!targets.length) {
      statusText = strings.t("noActions")
      return
    }
    var args = targets.map(function(plugin) {
      return ["plugin", action, plugin.id]
    })
    queueActions(args)
  }

  function confirmUninstall() {
    var ids = pendingUninstallIds.slice()
    pendingUninstallIds = []
    if (!ids.length || busy) return
    startHistoryAction({ action: "uninstall", ids: ids })
  }

  function refreshHistory() {
    if (historyReading) return
    historyMode = "list"
    historyRequest = {}
    historyReading = true
    historyHelper.running = true
  }

  function startHistoryAction(request) {
    if (busy) return
    historyMode = "start"
    historyRequest = request
    historyBusy = true
    historyReading = true
    statusText = strings.t("historyWorking")
    pendingHistoryDelete = null
    pendingDeleteAll = false
    historyHelper.running = true
  }

  function finishHistory(exitCode, output, errorOutput) {
    historyReading = false
    var result
    try {
      if (output.length > 1048576) throw new Error("History response exceeded its size limit")
      result = JSON.parse(output)
      if (!result || typeof result.ok !== "boolean") throw new Error("Invalid history response")
      if (exitCode !== 0 || !result.ok) {
        throw new Error(String(result.error || errorOutput || strings.t("historyFailed")))
      }
      if (typeof result.busy !== "boolean") throw new Error("Invalid history operation state")
      if (historyMode === "list") {
        if (result.entries !== null) {
          if (!Array.isArray(result.entries) || result.entries.length > 1000
              || result.entries.some(function(row) {
                return !row || typeof row.key !== "string" || !/^[a-f0-9]{32}$/.test(row.key)
                  || typeof row.id !== "string" || row.id.length > 128
                  || !/^[A-Za-z0-9][A-Za-z0-9._-]*$/.test(row.id)
                  || typeof row.name !== "string" || row.name.length > 160
                  || typeof row.removedAt !== "string" || row.removedAt.length > 64
                  || !isFinite(new Date(row.removedAt).getTime())
                  || typeof row.available !== "boolean" || typeof row.installed !== "boolean"
                  || typeof row.linked !== "boolean"
                  || typeof row.size !== "number" || !(row.size >= 0)
              })) throw new Error("Invalid uninstall history entries")
          uninstallHistory = result.entries
          if (typeof result.totalSize !== "number" || !isFinite(result.totalSize)
              || result.totalSize < 0) throw new Error("Invalid backup size")
          backupSize = result.totalSize
          historyLoaded = true
        } else if (!result.busy) {
          throw new Error("Missing uninstall history entries")
        }
        historyBusy = result.busy
        var operation = result.operation
        if (!historyBusy && operation && operation.token !== lastHistoryToken) {
          if (typeof operation.token !== "string" || !/^[a-f0-9]{32}$/.test(operation.token)
              || typeof operation.ok !== "boolean"
              || ["uninstall", "restore", "delete", "prune", "delete-all"].indexOf(operation.action) === -1) {
            throw new Error("Invalid history operation result")
          }
          lastHistoryToken = operation.token
          if (!operation.ok) {
            statusText = String(operation.error || strings.t("historyFailed")).slice(0, 2000)
            console.warn("Plugin Manager: " + statusText)
          } else {
            statusText = strings.t("historyDone_" + operation.action)
          }
          refresh(false)
        }
      } else {
        historyBusy = true
        if (historyRequest.action === "uninstall") showHistory = true
        Qt.callLater(root.refreshHistory)
      }
    } catch (error) {
      historyBusy = false
      statusText = String(error.message || strings.t("historyFailed")).slice(0, 2000)
      console.warn("Plugin Manager: " + statusText)
    }
  }

  function queueActions(args) {
    actionQueue = args
    actionIndex = 0
    runNextAction()
  }

  function runNextAction() {
    if (actionIndex >= actionQueue.length) {
      var completed = actionQueue.length
      actionQueue = []
      statusText = countText("batchDone", completed)
      refresh(false)
      return
    }
    requestType = "action"
    commandProgram = "omarchy"
    commandArgs = actionQueue[actionIndex]
    helper.running = true
  }

  function moveTo(section) {
    if (busy || section === currentSection) return
    pendingSection = section
    requestType = "move"
    commandProgram = "omarchy"
    commandArgs = ["bar", "move", moduleName, "--section", section]
    helper.running = true
  }

  function finishCommand(exitCode, output, errorOutput) {
    if (requestType === "list") {
      if (exitCode !== 0) {
        statusText = String(errorOutput || strings.t("loadFailed")).trim().slice(0, 1200)
        console.warn("Plugin Manager: " + statusText)
        return
      }
      if (output.length > 200000) {
        statusText = strings.t("invalidList")
        console.warn("Plugin Manager: plugin list exceeded its size limit")
        return
      }
      var parsed
      try {
        parsed = JSON.parse(output)
      } catch (error) {
        statusText = strings.t("invalidList")
        console.warn("Plugin Manager: invalid plugin list JSON")
        return
      }
      if (!Array.isArray(parsed) || parsed.length > 250) {
        statusText = strings.t("invalidList")
        console.warn("Plugin Manager: plugin list had an invalid shape")
        return
      }
      var validated = []
      var seen = {}
      for (var i = 0; i < parsed.length; i++) {
        var plugin = parsed[i]
        if (!plugin || typeof plugin.id !== "string" || plugin.id.length > 128
            || !/^[A-Za-z0-9][A-Za-z0-9._-]*$/.test(plugin.id)
            || typeof plugin.name !== "string" || plugin.name.length > 160
            || typeof plugin.enabled !== "boolean" || typeof plugin.canDisable !== "boolean"
            || typeof plugin.firstParty !== "boolean" || !Array.isArray(plugin.kinds)
            || plugin.kinds.length > 16 || plugin.kinds.some(function(kind) {
              return typeof kind !== "string" || kind.length > 40
            }) || seen[plugin.id]) {
          statusText = strings.t("invalidList")
          console.warn("Plugin Manager: plugin list contained an invalid entry")
          return
        }
        seen[plugin.id] = true
        validated.push({
          id: plugin.id,
          name: plugin.name,
          enabled: plugin.enabled,
          canDisable: plugin.canDisable,
          firstParty: plugin.firstParty,
          kinds: plugin.kinds.slice()
        })
      }
      plugins = validated
      selectedIds = selectedIds.filter(function(id) { return !!seen[id] })
      if (statusText === strings.t("loading")) statusText = ""
      return
    }

    if (requestType === "section") {
      var section = String(output || "").trim()
      if (exitCode === 0 && ["left", "center", "right"].indexOf(section) !== -1) {
        currentSection = section
      } else {
        statusText = exitCode === 0 ? strings.t("positionFailed")
          : String(errorOutput || strings.t("loadFailed")).trim().slice(0, 1200)
        console.warn("Plugin Manager: could not read its bar position")
      }
      Qt.callLater(function() { root.refresh(false) })
      return
    }

    if (exitCode !== 0) {
      var failure = String(errorOutput || output || strings.t("commandFailed")).trim().slice(0, 1200)
      statusText = failure
      console.warn("Plugin Manager: " + failure)
      if (requestType === "action") {
        actionQueue = []
        Qt.callLater(function() { root.refresh(false) })
      }
      return
    }

    if (requestType === "move") {
      currentSection = pendingSection
      statusText = strings.t("moveDone").arg(strings.t(pendingSection))
      return
    }

    if (requestType === "action") {
      actionIndex++
      Qt.callLater(root.runNextAction)
    }
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  ShellIpc {
    target: root.moduleName
    function open() { root.open() }
    function settings() {
      root.showHistory = false
      root.open()
      root.settingsOpen = true
      Qt.callLater(function() { settingsClose.forceActiveFocus() })
    }
    function history() {
      root.showHistory = true
      root.settingsOpen = false
      root.open()
    }
    function close() { root.close() }
    function toggle() { root.toggle() }
    function status(): string {
      return JSON.stringify({
        opened: root.opened,
        busy: root.busy,
        historyBusy: root.historyBusy,
        historyView: root.showHistory,
        historyEntries: root.uninstallHistory.length,
        backupBytes: root.backupSize,
        settingsOpen: root.settingsOpen,
        settingsScrollHeight: settingsFlickable.contentHeight,
        settingsScrollPosition: settingsFlickable.contentY,
        visiblePlugins: root.visiblePlugins.length,
        filteredPlugins: root.filteredPlugins.length,
        iconHighlighted: root.iconHighlighted,
        barLabel: button.labelText,
        preferences: {
          defaultDisabledOnly: preferences.defaultDisabledOnly,
          defaultUserInstalledOnly: preferences.defaultUserInstalledOnly,
          hideNative: preferences.hideNative,
          iconColorRule: preferences.iconColorRule,
          showBarCount: preferences.showBarCount,
          retentionDays: preferences.retentionDays,
          skipUninstallConfirm: preferences.skipUninstallConfirm
        },
        error: root.statusText,
        plugins: root.plugins.length,
        scrollbarVisible: listScrollBar.visible,
        listHeight: pluginList.height,
        listContentHeight: pluginList.contentHeight,
        panel: { x: popup.cardOrigin.x, y: popup.cardOrigin.y, width: popup.contentWidth, height: popup.contentHeight }
      })
    }
  }

  component ManagerScrollBar: Controls.ScrollBar {
    id: scrollControl
    policy: Controls.ScrollBar.AsNeeded
    visible: size < 1
    interactive: true
    implicitWidth: Style.space(10)
    LayoutMirroring.enabled: false
    anchors.right: parent.right
    contentItem: Rectangle {
      implicitWidth: Style.space(6)
      implicitHeight: Style.space(32)
      radius: width / 2
      color: scrollControl.pressed || scrollControl.hovered
        ? Commons.Color.accent : Util.alpha(Commons.Color.popups.text, 0.55)
    }
    background: Rectangle {
      radius: width / 2
      color: Util.alpha(Commons.Color.popups.text, 0.1)
    }
  }

  component SettingsHeading: Text {
    textFormat: Text.PlainText
    color: Commons.Color.accent
    font.family: Style.font.family
    font.pixelSize: Style.font.bodySmall
    font.bold: true
  }

  component SettingsToggle: Toggle {
    width: parent.width
    foreground: Commons.Color.popups.text
    titleSize: Style.font.bodySmall
    descriptionSize: Style.font.caption
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: "\uf1e6"
    fontFamily: "JetBrainsMono Nerd Font"
    foreground: root.iconHighlighted ? Commons.Color.accent : "#ffffff"
    labelText: root.barCountVisible ? Commons.I18n.formatNumber(root.iconDisabledCount) : ""
    slotSize: Style.bar.iconSlot * (root.barCountVisible ? 2 : 1)
    tooltipText: strings.t("tooltip")
    onPressed: root.toggle()
  }

  KeyboardPanel {
    id: popup
    anchorItem: button
    bar: root.bar
    owner: root
    open: root.popupOpen
    focusTarget: content
    contentWidth: popup.fittedContentWidth(Style.space(680), 900)
    contentHeight: popup.fittedContentHeight(content.implicitHeight, 760)

    Item {
      id: content
      width: parent.width
      height: parent.height
      implicitHeight: mainContent.implicitHeight
      clip: true
      focus: true
      Keys.onEscapePressed: {
        if (root.settingsOpen) {
          root.settingsOpen = false
          settingsButton.forceActiveFocus()
        } else {
          root.close()
        }
      }

      Column {
        id: mainContent
        width: parent.width
        spacing: Style.space(10)

        RowLayout {
          id: heading
          width: parent.width
          Text {
            textFormat: Text.PlainText
            text: "\uf1e6"
            color: root.iconHighlighted ? Commons.Color.accent : Commons.Color.popups.text
            font.family: "JetBrainsMono Nerd Font"
            font.pixelSize: Style.font.subtitle
          }
          Text {
            Layout.fillWidth: true
            textFormat: Text.PlainText
            text: strings.t("title")
            color: Commons.Color.popups.text
            font.family: Style.font.family
            font.pixelSize: Style.font.subtitle
            font.bold: true
          }
          Button {
            text: strings.t("refresh")
            focusable: true
            enabled: !root.busy
            onClicked: {
              root.refresh()
              root.refreshHistory()
            }
          }
          Button {
            id: settingsButton
            iconText: "\uf013"
            fontFamily: "JetBrainsMono Nerd Font"
            tooltipText: strings.t("settings")
            Accessible.name: strings.t("settings")
            active: root.settingsOpen
            focusable: true
            onClicked: {
              root.settingsOpen = !root.settingsOpen
              if (root.settingsOpen) settingsClose.forceActiveFocus()
            }
          }
        }

        Column {
          id: pluginContent
          width: parent.width
          spacing: mainContent.spacing
          enabled: !root.settingsOpen

          RowLayout {
            width: parent.width
            Button {
              text: strings.t("installedView")
              active: !root.showHistory
              focusable: true
              onClicked: {
                root.showHistory = false
                root.pendingHistoryDelete = null
              }
            }
            Button {
              text: strings.t("historyView")
              active: root.showHistory
              focusable: true
              onClicked: {
                root.showHistory = true
                root.pendingUninstallIds = []
                root.refreshHistory()
              }
            }
          }

          RowLayout {
            width: parent.width
            visible: !root.showHistory
            TextField {
              Layout.fillWidth: true
              placeholderText: strings.t("search")
              text: root.filterText
              onTextChanged: root.filterText = text
            }
            Button {
              text: root.selectableIds.length && root.selectableIds.every(function(id) { return root.selected(id) })
                ? strings.t("clearSelection") : strings.t("selectAll")
              focusable: true
              enabled: !root.busy && root.selectableIds.length > 0
              onClicked: root.toggleSelectAll()
            }
          }

          RowLayout {
            width: parent.width
            visible: !root.showHistory
            Text {
              Layout.fillWidth: true
              textFormat: Text.PlainText
              text: root.countText("selectionCount", root.selectedCount)
              color: Commons.Color.popups.text
              font.family: Style.font.family
              font.pixelSize: Style.font.bodySmall
            }
            Text {
              textFormat: Text.PlainText
              text: root.countText("disabledCount", root.disabledCount)
              color: root.disabledCount > 0 ? Commons.Color.accent : Commons.Color.popups.text
              font.family: Style.font.family
              font.pixelSize: Style.font.bodySmall
            }
            Button {
              text: root.showDisabledOnly ? strings.t("showAll") : strings.t("disabledOnly")
              active: root.showDisabledOnly
              focusable: true
              onClicked: root.showDisabledOnly = !root.showDisabledOnly
            }
            Button {
              text: strings.t("userInstalledOnly")
              active: root.showUserInstalledOnly
              focusable: true
              onClicked: root.showUserInstalledOnly = !root.showUserInstalledOnly
            }
          }

          ListView {
            id: pluginList
            width: parent.width
            visible: !root.showHistory
            height: Math.min(Math.max(Style.space(50), root.filteredPlugins.length * Style.space(40)), Style.space(360))
            clip: true
            spacing: Style.space(2)
            boundsBehavior: Flickable.StopAtBounds
            model: root.filteredPlugins
            Controls.ScrollBar.vertical: ManagerScrollBar {
              id: listScrollBar
            }
            delegate: Button {
              required property var modelData
              width: pluginList.width - (listScrollBar.visible ? listScrollBar.width + Style.space(6) : 0)
              height: Style.space(38)
              text: strings.t("pluginRow")
                .arg(strings.t(modelData.firstParty ? "native" : "userInstalled"))
                .arg(modelData.name)
                .arg(strings.t(modelData.enabled ? "enabled" : "disabled"))
                .arg(modelData.id)
              iconText: root.selected(modelData.id) ? "☑" : "□"
              tooltipText: modelData.id
              foreground: modelData.enabled ? Commons.Color.popups.text : Commons.Color.accent
              leftAlign: true
              active: root.selected(modelData.id)
              focusable: true
              enabled: !root.busy && modelData.id !== root.moduleName
              onClicked: root.toggleSelected(modelData.id)
            }
          }

          Text {
            visible: !root.showHistory && root.filteredPlugins.length === 0
            textFormat: Text.PlainText
            text: strings.t(root.showDisabledOnly ? "noDisabled" : "empty")
            color: Commons.Color.popups.text
            font.family: Style.font.family
            font.pixelSize: Style.font.bodySmall
          }

          RowLayout {
            width: parent.width
            visible: !root.showHistory
            Button {
              Layout.fillWidth: true
              text: strings.t("enableSelected")
              focusable: true
              enabled: !root.busy && root.enableCount > 0
              onClicked: root.startBatch("enable")
            }
            Button {
              Layout.fillWidth: true
              text: strings.t("disableSelected")
              focusable: true
              enabled: !root.busy && root.disableCount > 0
              onClicked: root.startBatch("disable")
            }
            Button {
              Layout.fillWidth: true
              text: strings.t("uninstallSelected")
              focusable: true
              enabled: !root.busy && root.removableCount > 0
              onClicked: root.startBatch("remove")
            }
          }

          RowLayout {
            width: parent.width
            visible: !root.showHistory && root.pendingUninstallIds.length > 0
            Text {
              Layout.fillWidth: true
              textFormat: Text.PlainText
              text: strings.tn("confirmRemove", root.pendingUninstallIds.length)
                .arg(Commons.I18n.formatNumber(root.pendingUninstallIds.length))
              color: Commons.Color.urgent
              wrapMode: Text.WordWrap
              font.family: Style.font.family
              font.pixelSize: Style.font.bodySmall
            }
            Button {
              text: strings.t("cancel")
              focusable: true
              onClicked: root.pendingUninstallIds = []
            }
            Button {
              text: strings.t("confirmUninstall")
              focusable: true
              enabled: !root.busy
              onClicked: root.confirmUninstall()
            }
          }

          Column {
            width: parent.width
            spacing: Style.space(10)
            visible: root.showHistory

            Text {
              width: parent.width
              textFormat: Text.PlainText
              text: strings.t("historyHelp")
              color: Commons.Color.popups.text
              wrapMode: Text.WordWrap
              font.family: Style.font.family
              font.pixelSize: Style.font.bodySmall
            }

            ListView {
              id: historyList
              width: parent.width
              height: Math.min(contentHeight, Style.space(360))
              clip: true
              spacing: Style.space(8)
              boundsBehavior: Flickable.StopAtBounds
              model: root.uninstallHistory
              Controls.ScrollBar.vertical: ManagerScrollBar { id: historyScrollBar }
              delegate: Rectangle {
                required property var modelData
                width: historyList.width - (historyScrollBar.visible ? historyScrollBar.width + Style.space(6) : 0)
                height: historyRow.implicitHeight + Style.space(16)
                color: Util.alpha(Commons.Color.popups.text, 0.05)
                radius: Style.cornerRadius
                RowLayout {
                  id: historyRow
                  anchors.fill: parent
                  anchors.margins: Style.space(8)
                  spacing: Style.space(8)
                  Column {
                    Layout.fillWidth: true
                    spacing: Style.space(3)
                    Text {
                      width: parent.width
                      textFormat: Text.PlainText
                      text: modelData.name
                      elide: Text.ElideRight
                      color: Commons.Color.accent
                      font.family: Style.font.family
                      font.pixelSize: Style.font.body
                    }
                    Text {
                      width: parent.width
                      textFormat: Text.PlainText
                      text: modelData.id
                      elide: Text.ElideRight
                      color: Commons.Color.popups.text
                      font.family: Style.font.family
                      font.pixelSize: Style.font.bodySmall
                    }
                    Text {
                      width: parent.width
                      textFormat: Text.PlainText
                      text: strings.t("historyDate").arg(new Date(modelData.removedAt)
                        .toLocaleString(Qt.locale(Commons.I18n.formatLocale), Locale.ShortFormat))
                      elide: Text.ElideRight
                      color: Commons.Color.popups.text
                      font.family: Style.font.family
                      font.pixelSize: Style.font.bodySmall
                    }
                    Text {
                      width: parent.width
                      visible: modelData.linked || !modelData.available || modelData.installed
                      textFormat: Text.PlainText
                      text: strings.t(!modelData.available ? "historyMissing"
                        : modelData.installed ? "historyConflict" : "historyLinked")
                      color: Commons.Color.popups.text
                      wrapMode: Text.WordWrap
                      font.family: Style.font.family
                      font.pixelSize: Style.font.bodySmall
                    }
                  }
                  Button {
                    text: strings.t("restore")
                    focusable: true
                    enabled: !root.busy && modelData.available && !modelData.installed
                    onClicked: root.startHistoryAction({ action: "restore", key: modelData.key })
                  }
                  Button {
                    text: strings.t("deleteBackup")
                    focusable: true
                    enabled: !root.busy
                    onClicked: root.pendingHistoryDelete = modelData
                  }
                }
              }
            }

            Text {
              width: parent.width
              visible: root.uninstallHistory.length === 0 && !root.historyBusy
              textFormat: Text.PlainText
              text: strings.t("historyEmpty")
              color: Commons.Color.popups.text
              wrapMode: Text.WordWrap
              font.family: Style.font.family
              font.pixelSize: Style.font.bodySmall
            }

            RowLayout {
              width: parent.width
              visible: root.pendingHistoryDelete !== null
              Text {
                Layout.fillWidth: true
                textFormat: Text.PlainText
                text: strings.t("confirmDeleteBackup")
                  .arg(root.pendingHistoryDelete ? root.pendingHistoryDelete.name : "")
                color: Commons.Color.urgent
                wrapMode: Text.WordWrap
                font.family: Style.font.family
                font.pixelSize: Style.font.bodySmall
              }
              Button {
                text: strings.t("cancel")
                focusable: true
                onClicked: root.pendingHistoryDelete = null
              }
              Button {
                text: strings.t("deletePermanently")
                focusable: true
                enabled: !root.busy
                onClicked: root.startHistoryAction({
                  action: "delete", key: root.pendingHistoryDelete.key
                })
              }
            }
          }

          Text {
            visible: root.statusText !== ""
            width: parent.width
            textFormat: Text.PlainText
            text: root.statusText
            color: Commons.Color.popups.text
            wrapMode: Text.WordWrap
            font.family: Style.font.family
            font.pixelSize: Style.font.bodySmall
          }
        }
      }

      Rectangle {
        anchors.left: parent.left
        anchors.right: parent.right
        y: heading.height + mainContent.spacing
        height: parent.height - y
        visible: root.settingsOpen
        color: Qt.rgba(Commons.Color.popups.background.r, Commons.Color.popups.background.g,
          Commons.Color.popups.background.b, 0.6)
        MouseArea {
          anchors.fill: parent
          onClicked: {
            root.settingsOpen = false
            settingsButton.forceActiveFocus()
          }
        }
      }

      Rectangle {
        id: settingsDrawer
        width: Math.min(Style.space(340), parent.width)
        height: parent.height - y
        y: heading.height + mainContent.spacing
        x: root.settingsOpen ? parent.width - width : parent.width
        visible: root.settingsOpen || x < parent.width
        enabled: root.settingsOpen
        color: Commons.Color.popups.background
        border.color: Commons.Color.popups.border
        border.width: 1
        radius: Style.cornerRadius
        LayoutMirroring.enabled: false

        Behavior on x {
          NumberAnimation {
            duration: Style.duration(root.settingsOpen ? 180 : 120)
            easing.type: Easing.OutCubic
          }
        }

        MouseArea { anchors.fill: parent }

        Flickable {
          id: settingsFlickable
          anchors.fill: parent
          anchors.margins: Style.space(14)
          contentWidth: width
          contentHeight: settingsContent.implicitHeight
          clip: true
          boundsBehavior: Flickable.StopAtBounds
          Controls.ScrollBar.vertical: ManagerScrollBar { id: settingsScrollBar }

          Column {
            id: settingsContent
            width: parent.width - (settingsScrollBar.visible ? settingsScrollBar.width + Style.space(6) : 0)
            spacing: Style.space(14)
            LayoutMirroring.enabled: Commons.I18n.rightToLeft
            LayoutMirroring.childrenInherit: true

            RowLayout {
              width: parent.width
              Text {
                Layout.fillWidth: true
                textFormat: Text.PlainText
                text: strings.t("settings")
                color: Commons.Color.popups.text
                font.family: Style.font.family
                font.pixelSize: Style.font.subtitle
                font.bold: true
              }
              Button {
                id: settingsClose
                text: "\u00d7"
                tooltipText: strings.t("closeSettings")
                Accessible.name: strings.t("closeSettings")
                focusable: root.settingsOpen
                onClicked: {
                  root.settingsOpen = false
                  settingsButton.forceActiveFocus()
                }
              }
            }

            Text {
              textFormat: Text.PlainText
              text: strings.t("moveTo")
              color: Commons.Color.popups.text
              font.family: Style.font.family
              font.pixelSize: Style.font.bodySmall
            }
            RowLayout {
              width: parent.width
              Repeater {
                model: ["left", "center", "right"]
                Button {
                  required property string modelData
                  Layout.fillWidth: true
                  text: strings.t(modelData)
                  active: root.currentSection === modelData
                  focusable: root.settingsOpen
                  enabled: !root.busy
                  onClicked: root.moveTo(modelData)
                }
              }
            }

            SettingsHeading { text: strings.t("listSettings") }
            SettingsToggle {
              label: strings.t("defaultDisabledOnly")
              checked: preferences.defaultDisabledOnly
              onClicked: preferences.defaultDisabledOnly = !checked
            }
            SettingsToggle {
              label: strings.t("defaultUserInstalledOnly")
              checked: preferences.defaultUserInstalledOnly
              onClicked: preferences.defaultUserInstalledOnly = !checked
            }
            SettingsToggle {
              label: strings.t("hideNative")
              description: strings.t("hideNativeHelp")
              checked: preferences.hideNative
              onClicked: {
                preferences.hideNative = !checked
                root.selectedIds = root.selectedPlugins.map(function(plugin) { return plugin.id })
                root.pendingUninstallIds = []
              }
            }

            SettingsHeading { text: strings.t("barIconSettings") }
            Dropdown {
              width: parent.width
              label: strings.t("iconColorRule")
              value: preferences.iconColorRule
              options: [
                { value: "any", label: strings.t("iconRuleAny") },
                { value: "user", label: strings.t("iconRuleUser") },
                { value: "never", label: strings.t("iconRuleNever") }
              ]
              onChanged: function(value) { preferences.iconColorRule = value }
            }
            SettingsToggle {
              label: strings.t("showBarCount")
              description: strings.t("showBarCountHelp")
              checked: preferences.showBarCount
              onClicked: preferences.showBarCount = !checked
            }

            SettingsHeading { text: strings.t("backupSettings") }
            Dropdown {
              width: parent.width
              label: strings.t("backupRetention")
              value: String(preferences.retentionDays)
              options: [
                { value: "0", label: strings.t("retainForever") },
                { value: "7", label: strings.t("retainDays").arg(Commons.I18n.formatNumber(7)) },
                { value: "30", label: strings.t("retainDays").arg(Commons.I18n.formatNumber(30)) },
                { value: "90", label: strings.t("retainDays").arg(Commons.I18n.formatNumber(90)) },
                { value: "365", label: strings.t("retainDays").arg(Commons.I18n.formatNumber(365)) }
              ]
              onChanged: function(value) {
                preferences.retentionDays = Number(value)
              }
            }
            Text {
              width: parent.width
              textFormat: Text.PlainText
              text: strings.t("retentionHelp")
              color: Commons.Color.popups.text
              wrapMode: Text.WordWrap
              font.family: Style.font.family
              font.pixelSize: Style.font.caption
            }
            Text {
              width: parent.width
              textFormat: Text.PlainText
              text: strings.t("backupUsage").arg(root.formatBytes(root.backupSize))
                .arg(Commons.I18n.formatNumber(root.uninstallHistory.length))
              color: Commons.Color.popups.text
              wrapMode: Text.WordWrap
              font.family: Style.font.family
              font.pixelSize: Style.font.bodySmall
            }
            Button {
              width: parent.width
              text: strings.t("deleteAllBackups")
              focusable: root.settingsOpen
              enabled: !root.busy && root.uninstallHistory.length > 0
              onClicked: root.pendingDeleteAll = true
            }
            Column {
              width: parent.width
              spacing: Style.space(8)
              visible: root.pendingDeleteAll
              Text {
                width: parent.width
                textFormat: Text.PlainText
                text: strings.t("confirmDeleteAll")
                color: Commons.Color.urgent
                wrapMode: Text.WordWrap
                font.family: Style.font.family
                font.pixelSize: Style.font.bodySmall
              }
              RowLayout {
                width: parent.width
                Button {
                  text: strings.t("cancel")
                  focusable: root.settingsOpen
                  onClicked: root.pendingDeleteAll = false
                }
                Button {
                  text: strings.t("deletePermanently")
                  focusable: root.settingsOpen
                  enabled: !root.busy
                  onClicked: root.startHistoryAction({ action: "delete-all" })
                }
              }
              Text {
                width: parent.width
                visible: root.statusText !== ""
                textFormat: Text.PlainText
                text: root.statusText
                color: Commons.Color.popups.text
                wrapMode: Text.WordWrap
                font.family: Style.font.family
                font.pixelSize: Style.font.bodySmall
              }
            }
            SettingsToggle {
              label: strings.t("skipUninstallConfirm")
              description: strings.t("skipUninstallConfirmHelp")
              checked: preferences.skipUninstallConfirm
              onClicked: preferences.skipUninstallConfirm = !checked
            }

            SettingsHeading { text: strings.t("feedback") }
            Button {
              width: parent.width
              iconText: "\uf188"
              fontFamily: "JetBrainsMono Nerd Font"
              text: strings.t("reportBug")
              leftAlign: true
              focusable: root.settingsOpen
              onClicked: root.openIssue("bug_report.yml")
            }
            Button {
              width: parent.width
              iconText: "\uf0eb"
              fontFamily: "JetBrainsMono Nerd Font"
              text: strings.t("requestFeature")
              leftAlign: true
              focusable: root.settingsOpen
              onClicked: root.openIssue("feature_request.yml")
            }
            Text {
              width: parent.width
              textFormat: Text.PlainText
              text: strings.t("versionInfo").arg(root.pluginVersion || "?").arg(root.omarchyVersion || "?")
              color: Commons.Color.popups.text
              opacity: 0.7
              wrapMode: Text.WordWrap
              font.family: Style.font.family
              font.pixelSize: Style.font.bodySmall
            }
          }
        }
      }
    }
  }

  Timer {
    interval: 1000
    repeat: true
    running: preferences.retentionDays > 0 && root.historyLoaded && !root.busy
    onTriggered: {
      if (Date.now() < root.nextRetentionCheck) return
      root.nextRetentionCheck = Date.now() + 3600000
      var cutoff = Date.now() - preferences.retentionDays * 86400000
      if (root.uninstallHistory.some(function(row) { return new Date(row.removedAt).getTime() < cutoff })) {
        root.startHistoryAction({ action: "prune", days: preferences.retentionDays })
      }
    }
  }

  Timer {
    interval: 1000
    repeat: true
    running: root.historyBusy
    onTriggered: root.refreshHistory()
  }

  FileView {
    id: manifestFile
    path: decodeURIComponent(Qt.resolvedUrl("manifest.json").toString().replace(/^file:\/\//, ""))
    blockLoading: true
    printErrors: false
  }

  Process {
    id: versionReader
    command: ["omarchy", "version"]
    stdout: StdioCollector { id: versionOutput; waitForEnd: true }
    onExited: function(exitCode) {
      var version = String(versionOutput.text || "").trim()
      if (exitCode === 0 && /^[0-9A-Za-z.+_-]{1,64}$/.test(version)) root.omarchyVersion = version
    }
  }

  Process {
    id: historyHelper
    command: ["python3", decodeURIComponent(Qt.resolvedUrl("bin/history.py").toString()
      .replace(/^file:\/\//, "")), root.historyMode]
    stdinEnabled: true
    stdout: StdioCollector { id: historyOutput; waitForEnd: true }
    stderr: StdioCollector { id: historyErrors; waitForEnd: true }
    onStarted: {
      historyHelper.write(JSON.stringify(root.historyRequest))
      historyHelper.stdinEnabled = false
    }
    onExited: function(exitCode) {
      historyHelper.stdinEnabled = true
      Qt.callLater(function() {
        root.finishHistory(exitCode, historyOutput.text, historyErrors.text)
      })
    }
  }

  Process {
    id: helper
    command: [root.commandProgram].concat(root.commandArgs)
    stdout: StdioCollector { id: output; waitForEnd: true }
    stderr: StdioCollector { id: errors; waitForEnd: true }
    onExited: function(exitCode) {
      Qt.callLater(function() { root.finishCommand(exitCode, output.text, errors.text) })
    }
  }
}
