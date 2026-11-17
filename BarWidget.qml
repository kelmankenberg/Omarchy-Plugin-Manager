import QtQuick
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

  Component.onCompleted: readSection()

  readonly property int disabledCount: plugins.filter(function(plugin) { return !plugin.enabled }).length
  readonly property var selectedPlugins: plugins.filter(function(plugin) {
    return selectedIds.indexOf(plugin.id) !== -1
  })
  readonly property var filteredPlugins: plugins.filter(function(plugin) {
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
    refresh()
  }

  function close() {
    popupOpen = false
    settingsOpen = false
    pendingUninstallIds = []
  }

  function toggle() {
    if (popupOpen) close()
    else open()
  }

  function refresh(showLoading) {
    if (helper.running || actionQueue.length) return
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
    if (helper.running || actionQueue.length) return
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
    if (!ids.length || helper.running || actionQueue.length) return
    queueActions(ids.map(function(id) {
      return ["plugin", "remove", id, "--yes"]
    }))
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
    if (helper.running || actionQueue.length || section === currentSection) return
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
    function close() { root.close() }
    function toggle() { root.toggle() }
    function status(): string {
      return JSON.stringify({
        opened: root.opened,
        busy: helper.running,
        error: root.statusText,
        plugins: root.plugins.length,
        scrollbarVisible: listScrollBar.visible,
        listHeight: pluginList.height,
        listContentHeight: pluginList.contentHeight,
        panel: { x: popup.cardOrigin.x, y: popup.cardOrigin.y, width: popup.contentWidth, height: popup.contentHeight }
      })
    }
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: "\uf1e6"
    fontFamily: "JetBrainsMono Nerd Font"
    foreground: root.disabledCount > 0 ? Commons.Color.accent : "#ffffff"
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
            color: root.disabledCount > 0 ? Commons.Color.accent : Commons.Color.popups.text
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
            enabled: !helper.running && actionQueue.length === 0
            onClicked: root.refresh()
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
              enabled: !helper.running && actionQueue.length === 0 && root.selectableIds.length > 0
              onClicked: root.toggleSelectAll()
            }
          }

          RowLayout {
            width: parent.width
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
            height: Math.min(Math.max(Style.space(50), root.filteredPlugins.length * Style.space(40)), Style.space(360))
            clip: true
            spacing: Style.space(2)
            boundsBehavior: Flickable.StopAtBounds
            model: root.filteredPlugins
            Controls.ScrollBar.vertical: Controls.ScrollBar {
              id: listScrollBar
              policy: Controls.ScrollBar.AsNeeded
              interactive: true
              implicitWidth: Style.space(10)
              LayoutMirroring.enabled: false
              anchors.right: parent.right
              contentItem: Rectangle {
                implicitWidth: Style.space(6)
                implicitHeight: Style.space(32)
                radius: width / 2
                color: listScrollBar.pressed || listScrollBar.hovered
                  ? Commons.Color.accent : Util.alpha(Commons.Color.popups.text, 0.55)
              }
              background: Rectangle {
                radius: width / 2
                color: Util.alpha(Commons.Color.popups.text, 0.1)
              }
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
              enabled: modelData.id !== root.moduleName
              onClicked: root.toggleSelected(modelData.id)
            }
          }

          Text {
            visible: root.filteredPlugins.length === 0
            textFormat: Text.PlainText
            text: strings.t(root.showDisabledOnly ? "noDisabled" : "empty")
            color: Commons.Color.popups.text
            font.family: Style.font.family
            font.pixelSize: Style.font.bodySmall
          }

          RowLayout {
            width: parent.width
            Button {
              Layout.fillWidth: true
              text: strings.t("enableSelected")
              focusable: true
              enabled: !helper.running && actionQueue.length === 0 && root.enableCount > 0
              onClicked: root.startBatch("enable")
            }
            Button {
              Layout.fillWidth: true
              text: strings.t("disableSelected")
              focusable: true
              enabled: !helper.running && actionQueue.length === 0 && root.disableCount > 0
              onClicked: root.startBatch("disable")
            }
            Button {
              Layout.fillWidth: true
              text: strings.t("uninstallSelected")
              focusable: true
              enabled: !helper.running && actionQueue.length === 0 && root.removableCount > 0
              onClicked: root.startBatch("remove")
            }
          }

          RowLayout {
            width: parent.width
            visible: root.pendingUninstallIds.length > 0
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
              onClicked: root.confirmUninstall()
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
          anchors.fill: parent
          anchors.margins: Style.space(14)
          contentWidth: width
          contentHeight: settingsContent.implicitHeight
          clip: true

          Column {
            id: settingsContent
            width: parent.width
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
                  enabled: !helper.running && actionQueue.length === 0
                  onClicked: root.moveTo(modelData)
                }
              }
            }
          }
        }
      }
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
