# tabsets.wezterm

A WezTerm plugin to save and load named tab sets.

## Features

- Commands to load, save, rename and delete named tab layouts.
- Saves current window layout (tabs, panes, tab names, working directories, foreground processes, window dimensions, custom colors) to named JSON files.

## Usage

- Use key bindings or palette commands to save, load and delete tabsets †.
- Tabs are appended to the current window.
- If the window is empty (only contains a single empty tab) then the empty tab is deleted and, optionally, window dimensions and custom colors are restored.
- Tabsets are stored as `.tabset.json` files in `~/.config/wezterm/tabsets.wezterm/` †.

† See _Installation and Configuration_.

## Prerequisites

- POSIX commands: `rm`, `test`, `which`, `mkdir`, `rmdir`, `mv`.
- Optional `notify-send` command for desktop notifications workaround.

## Limitations

- Tabsets are confined to a single window by design.
- Panes are recreated with splits; manually resized panes are restored to their default split size.

## Installation and Configuration

Install plugin by adding this to your `wezterm.lua` configuration file:

```

local tabsets = wezterm.plugin.require("https://github.com/srackham/tabsets.wezterm")
tabsets.setup({
  -- Optional configuration options showing the default values

  -- Restore custom colors when loading empty window
  restore_colors = false,

  -- Restore window dimensions when loading empty window
  restore_dimensions = false,

  -- Path to the directory containing tabset JSON files
  tabsets_dir = wezterm.config_dir .. "/tabsets.wezterm"

  -- Fuzzy-match tabset name selection
  fuzzy_selector = false,
})
```

Optional tabsets key bindings to `config` configuration builder:

```
wezterm.on("save_tabset", function(window) tabsets.save_tabset(window) end)
wezterm.on("load_tabset", function(window) tabsets.load_tabset(window) end)
wezterm.on("delete_tabset", function(window) tabsets.delete_tabset(window) end)
wezterm.on("rename_tabset", function(window) tabsets.rename_tabset(window) end)

for _, v in ipairs({
  { key = "S", mods = "LEADER", action = wezterm.action { EmitEvent = "save_tabset" } },
  { key = "L", mods = "LEADER", action = wezterm.action { EmitEvent = "load_tabset" } },
  { key = "D", mods = "LEADER", action = wezterm.action { EmitEvent = "delete_tabset" } },
  { key = "R", mods = "LEADER", action = wezterm.action { EmitEvent = "rename_tabset" } },
})
do table.insert(config.keys, v) end
```

Optional tabsets Palette bindings:

```
-- Add tabsets Palette bindings
for _, v in ipairs({
  {
    brief = "Tabset: Save",
    icon = "md_content_save",
    action = wezterm.action_callback(tabsets.save_tabset),
  },
  {
    brief = "Tabset: Load",
    icon = "cod_terminal_tmux",
    action = wezterm.action_callback(tabsets.load_tabset),
  },
  {
    brief = "Tabset: Delete",
    icon = "md_delete",
    action = wezterm.action_callback(tabsets.delete_tabset),
  },
  {
    brief = "Tabset: Rename",
    icon = "md_rename_box",
    action = wezterm.action_callback(tabsets.rename_tabset),
  },
})
do table.insert(palette_commands, v) end

-- Install Palette commands
wezterm.on("augment-command-palette", function() return palette_commands end)
```

## Credits

- `tabsets.wezterm` was inspired by, and began as, a fork of [danielcopper/wezterm-session-manager](https://github.com/danielcopper/wezterm-session-manager).
