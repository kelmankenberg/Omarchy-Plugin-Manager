# Omarchy Plugin Manager

A native Omarchy shell bar widget for reviewing installed plugins and enabling,
disabling, or uninstalling them in batches.

![Omarchy Plugin Manager showing plugin sources, states, filters, and batch actions](preview.png)

## Features

- Search installed plugins by name or ID.
- Distinguish **Native Omarchy** plugins from **User installed** plugins.
- Combine **Disabled only** and **User installed only** filters.
- Highlight disabled plugins in the current theme's primary accent color.
- Select individual plugins or select all visible, eligible plugins.
- Batch enable, disable, or uninstall selected plugins.
- Scroll long lists using the mouse wheel or the draggable right-side scrollbar.
- Open the gear menu for a settings drawer with left, center, and right bar placement.
- Follow the active Omarchy theme and language, with English translations included.

The plug icon is white when every plugin is enabled and uses the theme accent
when any plugin is disabled. The count includes native plugins, even when a
filter hides them.

## Requirements

- Omarchy Quattro with the Quickshell-based shell, `qs.Ui` components, and
  `Commons.Translations`.
- The standard `omarchy` CLI and `jq`.
- JetBrainsMono Nerd Font for the plug and gear icons (included with Omarchy).

No separate service, build step, network polling, or API credentials are required.

## Install

```bash
omarchy plugin add https://github.com/kelmankenberg/Omarchy-Plugin-Manager.git --enable
```

The widget defaults to the right section of the bar. Change its placement from
the gear menu, or use:

```bash
omarchy bar move kel.plugin-manager --section left
omarchy bar move kel.plugin-manager --section center
omarchy bar move kel.plugin-manager --section right
```

The center option joins the centered group and can shift the clock. To place it
beside the clock without shifting that group, use `--section centerEnd` or
`--section centerBegin` from the command line.

## Usage

Click the plug icon to open the manager. Select the plugins you want to manage,
then click **Enable selected**, **Disable selected**, or **Uninstall selected**.
Uninstall requires a separate confirmation.

**Select all** and **Clear selection** apply to the currently visible, eligible
plugins. Existing selections hidden by a filter are retained: the selected count
and batch actions include them. Review your selection before applying an action.

Use **Refresh** to reload plugin states after changing them elsewhere. The list
also refreshes when the popup opens and after a batch action.

Click the gear to open settings. Close the drawer with its close button, the
gear, Escape, or a click on the shaded list. Escape closes the popup when the
drawer is already closed.

## Safety and removal

The manager uses Omarchy's own plugin commands, one plugin at a time. Batch
operations are not atomic: if a command fails, the remaining operations stop,
the error is displayed, and completed changes remain applied.

- Native plugins cannot be uninstalled through this widget.
- The manager cannot disable or uninstall itself through its own list.
- Alternate full-bar plugins cannot be uninstalled through this widget. Enabling
  an alternate bar uses Omarchy's normal bar-switching behavior.
- Plugins Omarchy marks as non-disableable are excluded from batch enable/disable.
- Git-managed plugin checkouts are deleted by Omarchy's removal command, including
  local modifications. Non-Git plugin directories are moved to a hidden backup.
  Symlink installations are unlinked.

To disable or remove this widget:

```bash
omarchy plugin disable kel.plugin-manager
omarchy plugin remove kel.plugin-manager
```

The plugin stores no credentials or private data. Its placement and enabled
state live in Omarchy's `~/.config/omarchy/shell.json`; search, filters, and
selection are session-only.

## Development

Edit the installed plugin under `~/.config/omarchy/plugins/kel.plugin-manager/`.
Omarchy hot-reloads changes; do not edit the packaged shell under `/usr/share/omarchy/`.

```bash
omarchy plugin validate .
qmllint BarWidget.qml
```

The stable plugin ID is `kel.plugin-manager`, independent of its display name.

## License

[MIT](LICENSE)
