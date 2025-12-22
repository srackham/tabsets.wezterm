--- @module 'tabsets'
--- @brief A WezTerm plugin to save and load named tab sets

--- @diagnostic enable -- Enable/disable LuaCATS annotations diagnostics

local wezterm = require "wezterm"
local act = wezterm.action

local plugin_name = "tabsets.wezterm"

local function log_info(message)
  wezterm.log_info(plugin_name .. ": " .. message)
end
local function log_error(message)
  wezterm.log_error(plugin_name .. ": " .. message)
end

--- Updates Lua's `package.path` to include the `./plugin` directory of the specified WezTerm plugin.
--- See [Managing a Plugin with Multiple Lua Modules](https://wezterm.org/config/plugins.html#managing-a-plugin-with-multiple-lua-modules).
--- @function update_plugin_path
--- @param plugin_url string Partial or full plugin URL
--- @return boolean `true` if the plugin was found and the `package.path` updated successfully, `false` otherwise
local function update_plugin_path(plugin_url)
  for _, plugin in ipairs(wezterm.plugin.list()) do
    if string.find(plugin.url:lower(), plugin_url:lower(), 1, true) then
      -- Define the patterns for both standard files and init files
      local standard_pattern = plugin.plugin_dir .. "/plugin/?.lua"
      local init_pattern = plugin.plugin_dir .. "/plugin/?/init.lua"

      -- Avoid appending if the path is already registered
      if package.path:find(standard_pattern, 1, true) then
        log_info("Skipped updating existing package.path for plugin: " .. plugin.url)
        return true
      end

      local path_update = standard_pattern .. ";" .. init_pattern
      package.path = package.path .. ";" .. path_update
      log_info("Updated package.path for plugin: " .. path_update)
      return true
    end
  end
  log_error("No plugin found matching: " .. plugin_url)
  return false
end

if not update_plugin_path(plugin_name) then
  return {}
end

local fs = require "tabsets.fs"
local M = {}

--- @class InputSelectorChoice
--- @field id string
--- @field name string

--- @class TabsetOptions
--- @field tabsets_dir? string Path to the directory containing tabset JSON files
--- @field restore_colors? boolean Restore custom colors when loading empty window
--- @field restore_dimensions? boolean Restore window dimensions when loading empty window
--- @field fuzzy_selector? boolean Fuzzy match tabset name selection
M.options = {} -- Setup() configuration options.

--- Extract the final path component from a filesystem path.
--- Given `/foo/bar` returns `bar`.
--- Given `c:\\foo\\bar` returns `bar`.
--- @param s string Full path string
--- @return string #Basename component
local function basename(s)
  return (string.gsub(s, "(.*[/\\])(.*)", "%2"))
end

--- Check whether a tabset name only contains allowed characters.
--- Allowed characters are alphanumeric plus `+- ._` and space.
--- @param name string Tabset name to validate
--- @return boolean #True if the name is valid, false otherwise
local function is_valid_tabset_name(name)
  if name:match "^[%w%+%.%-_%s]+$" then
    return true
  else
    return false
  end
end

--- Build the full path to a tabset file from its name.
--- The resulting file has a `.tabset.json` suffix.
--- @param name string Logical tabset name
--- @return string #Full filesystem path to the tabset file
local function tabset_file(name)
  return M.options.tabsets_dir .. "/" .. name .. ".tabset.json"
end

--- Determine whether the given executable path refers to a shell.
--- The check is performed against a small set of common shell names.
--- @param file_path string Executable path or program name
--- @return boolean #True if the executable is considered a shell
local function is_shell(file_path)
  local shells = { "sh", "bash", "zsh", "fish", "nu", "dash", "csh", "ksh" }
  for _, shell in ipairs(shells) do
    if basename(file_path) == shell then
      return true
    end
  end
  return false
end

--- Strip a `file://` URI prefix and return a plain path.
--- @param uri string File URI
--- @return string #Local filesystem path
local function extract_path_from_uri(uri)
  return (uri:gsub("^file://", ""))
end

--- Resolve an executable name or path to an absolute executable path.
--- First checks if the provided path is directly executable, then falls back to `which`.
--- @param path string Executable name or path
--- @return string|nil #Resolved absolute path, or nil if resolution fails
local function resolve_executable(path)
  if fs.is_executable(path) then
    return path
  end
  local shell_path = fs.which(path)
  if shell_path then
    return shell_path
  end
  log_error("Failed to resolve executable '" .. path .. "'.")
  return nil
end

---@class LogAndNotifyOpts
---@field error? boolean  -- If true, log error and prefix toast message with "FAILED:"

--- Log a message and display it as a desktop notification.
--- If installed, uses `notify-send` as a workaround for non-expiring toast notifications.
--- @param window wezterm.window Current wezterm window
--- @param message string Message text to display
--- @param opts? LogAndNotifyOpts Optional notification options
local function log_and_notify(window, message, opts)
  opts = opts or {}
  if opts.error then
    log_error(message)
    message = "FAILED: " .. message
  else
    log_info(message)
  end
  if fs.which "notify-send" then
    -- WezTerm window:toast_notification does not time out, workaround by running `notify-send` CLI instead
    wezterm.run_child_process {
      "bash",
      "-c",
      "notify-send -a '" .. plugin_name .. "' -t 4000 -u normal '" .. message:gsub("'", "'\"'\"'") .. "'",
    }
  else
    window:toast_notification(plugin_name, message, nil, 4000)
  end
end

--- @class TabsetData
--- @field window_width number
--- @field window_height number
--- @field colors table
--- @field tabs TabsetTabData[]

--- @class TabsetTabData
--- @field title string
--- @field panes TabsetPaneData[]

--- @class TabsetPaneData
--- @field left number
--- @field cwd string
--- @field exe string

--- Capture the current window's tabset layout and metadata.
--- Includes window dimensions, colors, tab titles, pane cwd URIs and foreground executables.
--- @param window wezterm.window Active wezterm window
--- @return TabsetData #Tabset description suitable for serialization
local function retrieve_tabset_data(window)
  local dims = window:get_dimensions()
  local cfg = window:effective_config()

  --- @type TabsetData
  local tabset_data = {
    window_width = dims.pixel_width,   -- the width of the window in pixels
    window_height = dims.pixel_height, -- the height of the window in pixels
    colors = cfg.colors,
    tabs = {},
  }

  -- Iterate over tabs in the current window
  for _, tab in ipairs(window:mux_window():tabs()) do
    --- @type TabsetTabData
    local tab_data = {
      title = tab:get_title(),
      panes = {},
    }

    -- Iterate over panes in the current tab
    for _, pane_info in ipairs(tab:panes_with_info()) do
      -- Collect pane details, including layout and process information
      table.insert(tab_data.panes, {
        left = pane_info.left,
        cwd = tostring(pane_info.pane:get_current_working_dir()),
        exe = tostring(pane_info.pane:get_foreground_process_name()),
      })
    end

    table.insert(tabset_data.tabs, tab_data)
  end

  return tabset_data
end

--- Serialize a Lua table and save it to a JSON file.
--- Logs an error and returns false if writing fails.
--- @param data table Lua table to serialize
--- @param file_path string Destination JSON file path
--- @return boolean #True on success, false on failure
local function save_to_json_file(data, file_path)
  if not data then
    log_error "No tabset data to save."
    return false
  end

  local file = io.open(file_path, "w")
  if file then
    file:write(wezterm.json_encode(data))
    file:close()
    return true
  end
  return false
end

--- Recreate the window layout from a previously captured tabset.
--- Rebuilds tabs and panes, restores window size/colors and optionally re-executes non-shell foreground processes.
--- @param window wezterm.window Active wezterm window
--- @param tabset_data TabsetData Tabset data, as returned by @{retrieve_tabset_data}
--- @return boolean #True on successful recreation, false if validation fails
local function recreate_tabset(window, tabset_data)
  if not tabset_data or not tabset_data.tabs then
    log_error "Invalid or empty tabset data."
    return false
  end

  local tabs = window:mux_window():tabs()
  local window_is_empty = false
  if #tabs == 1 and #tabs[1]:panes() == 1 then
    local initial_pane = window:active_pane()
    local foreground_process = initial_pane:get_foreground_process_name()
    if is_shell(foreground_process) then
      initial_pane:send_text "exit\r"
      log_info "Existing single empty tab closed."
      window_is_empty = true
    end
  end

  -- Restore window size and colors
  if window_is_empty then
    if M.options.restore_colors then
      window:set_config_overrides { colors = tabset_data.colors or {} }
    end
    if M.options.restore_dimensions then
      window:set_inner_size(tabset_data.window_width, tabset_data.window_height)
    end
  end

  -- Recreate tabs and panes from the saved state
  for _, tab_data in ipairs(tabset_data.tabs) do
    local cwd_uri = tab_data.panes[1].cwd
    local cwd_path = extract_path_from_uri(cwd_uri)

    local new_tab = window:mux_window():spawn_tab { cwd = cwd_path }
    if not new_tab then
      log_error "Failed to create a new tab."
      break
    end
    new_tab:set_title(tab_data.title)

    -- Activate the new tab before creating panes
    new_tab:activate()

    -- Recreate panes within this tab
    local first_pane
    for j, pane_data in ipairs(tab_data.panes) do
      local new_pane
      if j == 1 then
        first_pane = new_tab:active_pane()
        new_pane = first_pane
      else
        local direction = "Right"
        if pane_data.left == tab_data.panes[j - 1].left then
          direction = "Bottom"
        end

        new_pane = new_tab:active_pane():split {
          direction = direction,
          cwd = extract_path_from_uri(pane_data.cwd),
        }
      end

      if not new_pane then
        log_error "Failed to create a new pane."
        goto continue
      end

      if not is_shell(pane_data.exe) then
        local exe = resolve_executable(pane_data.exe)
        if exe then
          new_pane:send_text(exe .. "\n")
        end
      end

      ::continue::
    end
    first_pane:activate()
  end

  log_info "Tabset recreated."
  return true
end

--- Load tabset data from a JSON file.
--- Parses the JSON content and returns the decoded Lua table or nil on error.
--- @param file_path string Path to the JSON file
--- @return TabsetData|nil #Decoded tabset data, or nil if the file cannot be opened or parsed
local function load_from_json_file(file_path)
  local file = io.open(file_path, "r")
  if not file then
    log_error("Failed to open file '" .. file_path .. "'.")
    return nil
  end

  local file_content = file:read "*a"
  file:close()

  local data = wezterm.json_parse(file_content)
  if not data then
    log_error("Failed to parse JSON data from tabset file '" .. file_path .. "'.")
  end
  --- @cast data TabsetData|nil
  return data
end

--- Load and restore a tabset by its logical name.
--- If loading or recreation fails, a notification is shown to the user.
--- @param window wezterm.window Active wezterm window
--- @param tabset_name string Tabset name (without extension), defaults to `default`
function M.load_tabset_by_name(window, tabset_name)
  local file_path = tabset_file(tabset_name)

  local tabset_data = load_from_json_file(file_path)
  if not tabset_data then
    log_and_notify(window, "Tabset file not found '" .. file_path .. "'.", { error = true })
    return
  end

  if recreate_tabset(window, tabset_data) then
    log_and_notify(window, "Tabset loaded '" .. tabset_name .. "'.")
  else
    log_and_notify(window, "Tabset loading failed '" .. tabset_name .. "'.", { error = true })
  end
end

--- Helper to collect tabset names and run a callback on selection.
--- Presents an input selector listing all discovered tabset files.
--- @param window wezterm.window Active wezterm window
--- @param callback fun(window: wezterm.window, pane: wezterm.pane, id: string) Callback invoked as callback(window, pane, id)
--- @param prompt string? Input selector prompt
local function tabset_action(window, callback, prompt)
  -- Collect tabset names
  --- @type InputSelectorChoice[]
  local choices = {}
  local ok, files = pcall(wezterm.read_dir, M.options.tabsets_dir)
  if not ok then
    log_and_notify(window, "Could not read tabsets directory '" .. M.options.tabsets_dir .. "'.", { error = true })
    return
  end
  for _, f in ipairs(files) do
    f = basename(f)
    if f:match "%.tabset%.json$" then
      local name = f:gsub("%.tabset%.json$", "")
      table.insert(choices, { id = name, label = name })
    end
  end

  if #choices == 0 then
    log_and_notify(window, "No saved tabset files found.")
    return
  end

  table.sort(choices, function(a, b)
    return a.id < b.id
  end)

  window:perform_action(
    act.InputSelector {
      description = prompt,
      fuzzy_description = prompt,
      choices = choices,
      action = wezterm.action_callback(callback),
      fuzzy = M.options.fuzzy_selector,
    },
    window:active_pane()
  )
end

--- Interactively load a saved tabset.
--- Shows a selector of available tabsets, then calls @{load_tabset_by_name} on the chosen entry.
--- @param window wezterm.window Active wezterm window
function M.load_tabset(window)
  tabset_action(window, function(_, _, tabset_name)
    if tabset_name then
      -- @type string
      M.load_tabset_by_name(window, tabset_name)
    end
  end, "Select tabset to load:")
end

--- Interactively delete a saved tabset.
--- Prompts for a tabset, deletes the corresponding JSON file and notifies the user.
--- @param window wezterm.window Active wezterm window
function M.delete_tabset(window)
  tabset_action(window, function(_, _, name)
    if name then
      local f = tabset_file(name)
      if fs.rm(f) then
        log_and_notify(window, "Deleted tabset '" .. name .. "'.")
      else
        log_and_notify(window, "Unable to delete tabsets file '" .. f .. "'.", { error = true })
      end
    end
  end, "Select tabset to delete:")
end

--- Interactively save the current window layout as a tabset.
--- Prompts for a tabset name, validates it and writes a JSON description to disk.
--- @param window wezterm.window Active wezterm window
function M.save_tabset(window)
  --- @type TabsetData
  local data = retrieve_tabset_data(window)

  window:perform_action(
    act.PromptInputLine {
      description = "Enter tabset name:",
      action = wezterm.action_callback(function(_, _, name)
        if not is_valid_tabset_name(name) then
          log_and_notify(window, "Invalid tabset name '" .. name .. "'.", { error = true })
          return
        end
        local data_file = tabset_file(name)
        if save_to_json_file(data, data_file) then
          log_and_notify(window, "Tabset '" .. name .. "' saved successfully.")
        else
          log_and_notify(window, "Unable to save '" .. data_file .. "'.", { error = true })
        end
      end),
    },
    window:active_pane()
  )
end

--- Rename a tabset.
--- @param window wezterm.window Active wezterm window
function M.rename_tabset(window)
  tabset_action(window, function(_, _, old_name)
    if old_name then
      window:perform_action(
        act.PromptInputLine {
          description = "Enter new tabset name",
          action = wezterm.action_callback(function(_, _, new_name)
            if not is_valid_tabset_name(new_name) then
              log_and_notify(window, "Invalid tabset name '" .. new_name .. "'.", { error = true })
              return
            end
            local old_file = tabset_file(old_name)
            local new_file = tabset_file(new_name)
            if fs.is_path(new_file) then
              log_and_notify(window, "Tabset '" .. new_name .. "' already exists.", { error = true })
              return
            end
            if fs.mv(old_file, new_file) then
              log_and_notify(window, "Tabset '" .. old_name .. "' successfully renamed to '" .. new_name .. "'.")
            else
              log_and_notify(window, "Unable to rename '" .. old_file .. "' to '" .. new_file .. "'.", { error = true })
            end
          end),
        },
        window:active_pane()
      )
    end
  end, "Select tabset to rename:")
end

--- Initialize plugin and set configuration options.
--- @param opts TabsetOptions|nil Options table
function M.setup(opts)
  opts = opts or {}
  -- Set default tabsets directory
  if not opts.tabsets_dir then
    opts.tabsets_dir = wezterm.config_dir .. "/" .. plugin_name
  end
  -- Create the tabsets directory if it does not exist
  --- @type string
  local dir = opts.tabsets_dir
  if not fs.is_directory(dir) then
    if fs.mkdir(dir) then
      log_info("Created tabsets directory '" .. dir .. "'.")
    else
      log_error("Failed to create tabsets directory '" .. dir .. "'.")
    end
  end
  opts.fuzzy_selector = opts.fuzzy_selector or false
  M.options = opts
end

return M
