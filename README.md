# Omarchy Clipboard

A local clipboard-history overlay for [Omarchy](https://omarchy.org/). It is
opened with `Super+V` and lets you search, pin, copy, paste, or remove recent
clipboard entries.

## Install

```bash
omarchy plugin add https://github.com/htrnguyen-labs/omarchy-clipboard.git --enable --yes
```

Add this to `~/.config/hypr/bindings.lua`:

```lua
hl.unbind("SUPER + V")
o.bind("SUPER + V", "Clipboard manager", "omarchy-shell shell toggle nguyenn.clipboard")
o.bind("SUPER + SHIFT + V", "Clipboard manager", "omarchy-shell shell toggle nguyenn.clipboard")
```

Hyprland reloads the configuration when the file is saved. If the plugin does
not appear immediately, run:

```bash
omarchy-shell shell rescanPlugins
```

## Features

- Search clipboard history
- Pin entries so they remain at the top
- Paste, copy, open, or remove an entry
- Store text and image clipboard entries
- Ignore clipboard data marked sensitive by the source application

## Data and privacy

History and pinned entries stay on the local machine:

```text
~/.local/state/omarchy/clipboard-history.json
~/.local/state/omarchy/clipboard-pinned.json
~/.local/state/omarchy/clipboard-images/
```

The plugin does not send clipboard data over the network. Clear the history
from the overlay when it is no longer needed.

## Development

Validate the plugin after making a change:

```bash
omarchy plugin validate ~/.config/omarchy/plugins/nguyenn.clipboard
```

## Credits and license

Maintained by Ha Trong Nguyen. This plugin is based on Omarchy's clipboard
plugin and is distributed under the upstream MIT license.
