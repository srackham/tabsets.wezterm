# tabsets.wezterm

A WezTerm plugin to save and load named tab sets.

## Features

- Save current window layout (tabs, panes, tab names, working directories, foreground processes, window dimensions, custom colors) to named JSON files
- Load named tabsets to recreate the saved tab layouts
- Tabsets are appended to the current window.

## Installation

Install plugin by adding this to your `wezterm.lua` configuration file:

```

local tabsets = wezterm.plugin.require("https://github.com/srackham/tabsets.wezterm")
tabsets.setup()
```

Add optional tabsets key bindings to the configuration file `config` configuration builder:

```
wezterm.on("save_tabset", function(window) tabsets.save_tabset(window) end)
wezterm.on("load_tabset", function(window) tabsets.load_tabset(window) end)
wezterm.on("delete_tabset", function(window) tabsets.delete_tabset(window) end)

for _, v in ipairs({
  { key = "S", mods = "LEADER", action = wezterm.action { EmitEvent = "save_tabset" } },
  { key = "L", mods = "LEADER", action = wezterm.action { EmitEvent = "load_tabset" } },
  { key = "D", mods = "LEADER", action = wezterm.action { EmitEvent = "delete_tabset" } },
})
do table.insert(config.keys, v) end
```

Add optional tabsets Palette bindings:

```
palette_commands = {}
for _, v in ipairs({
  {
    brief = "Tabset: Save",
    icon = "md_content_save",
    action = wezterm.action_callback(tabsets.save_tabset),
  },
  {
    brief = "Tabset: Load",
    icon = "md_reload",
    action = wezterm.action_callback(tabsets.load_tabset),
  },
  {
    brief = "Tabset: Delete",
    icon = "md_delete",
    action = wezterm.action_callback(tabsets.delete_tabset),
  },
})
do table.insert(palette_commands, v) end

-- Install Palette commands
wezterm.on("augment-command-palette", function() return palette_commands end)
```

## Usage

- Save, load and delete tabsets using key bindings, palette commands or from Lua code.
- Tabsets are stored as `.tabset.json` files in `~/.config/wezterm/tabsets.wezterm/` (customizable, set API).

## API

| Function                                      | Description                                   | Parameters                                       |
| --------------------------------------------- | --------------------------------------------- | ------------------------------------------------ |
| `tabsets.setup([opts])`                       | Initialize plugin. Creates default directory. | `opts.tabsets_dir`: custom storage path          |
| `tabsets.save_tabset(window)`                 | Interactively save current layout.            | `wezterm.Window window`                          |
| `tabsets.load_tabset(window)`                 | Show selector and load chosen tabset.         | `wezterm.Window window`                          |
| `tabsets.load_tabset_by_name(window, [name])` | Load specific tabset by name.                 | `wezterm.Window window`, `string name="default"` |
| `tabsets.delete_tabset(window)`               | Show selector and delete chosen tabset.       | `wezterm.Window window`                          |

### Setup options

TODO:

## Prerequisites

- Linux or MacOS with `notify-send`, `which`, and `bash` (for notifications and executable resolution)

## Limitations

- Single-window only by design; doesn't handle WezTerm workspaces
- Panes are recreated sequentially (Right/Bottom splits); complex nested layouts may differ slightly
- If enabled, window colors are restored via `set_config_overrides`; may conflict with global config
- `toast_notification` workaround uses CLI `notify-send` (no timeout on native toast)

## Credits

- `tabsets.wezterm` was inspired by, and began as, a fork of [danielcopper/wezterm-session-manager](https://github.com/danielcopper/wezterm-session-manager).
