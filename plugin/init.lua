---@module 'tabsets'
---@brief A WezTerm plugin to save and load named tab sets

--- @diagnostic disable -- Disable LuaCATS annotations diagnostics

local wezterm = require 'wezterm'
local act = wezterm.action
local fs = require 'tabsets.fs'

local M = {}

--- @class TabsetOptions
--- @field tabsets_dir? string Path to the directory containing tabset JSON files
--- @field restore_colors? boolean Whether to restore window colors on reload
--- @field restore_dimensions? boolean Whether to restore window dimensions on reload

--- @type TabsetOptions
local options = {} -- Setup() configuration options.

--- Extract the final path component from a filesystem path.
--- Given "/foo/bar" returns "bar".
--- Given "c:\\foo\\bar" returns "bar".
--- @param s string Full path string
--- @return string #Basename component
local function basename(s)
  return (string.gsub(s, "(.*[/\\])(.*)", "%2"))
end

--- Check whether a tabset name only contains allowed characters.
--- Allowed characters are alphanumeric plus "+- ._" and space.
--- @param name string Tabset name to validate
--- @return boolean #True if the name is valid, false otherwise
local function is_valid_tabset_name(name)
  if name:match("^[%w%+%.%-_%s]+$") then return true else return false end
end

--- Build the full path to a tabset file from its name.
--- The resulting file has a ".tabset.json" suffix.
--- @param name string Logical tabset name
--- @return string #Full filesystem path to the tabset file
local function tabset_file(name)
  return options.tabsets_dir .. "/" .. name .. ".tabset.json"
end

--- Determine whether the given executable path refers to a shell.
--- The check is performed against a small set of common shell names.
--- @param file_path string Executable path or program name
--- @return boolean #True if the executable is considered a shell
local function is_shell(file_path)
  local shells = { "sh", "bash", "zsh", "fish", "nu", "dash", "csh", "ksh" }
  for _, shell in ipairs(shells) do
    if basename(file_path) == shell then return true end
  end
  return false
end

--- Strip a "file://" URI prefix and return a plain path.
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
  wezterm.log_error("Failed to resolve executable '" .. path .. "'.")
  return nil
end

--- Log a message and display it as a desktop notification.
--- Uses `notify-send` as a workaround for non-expiring toast notifications.
--- @param window wezterm.window Current wezterm window
--- @param message string Message text to display
local function display_notification(window, message)
  wezterm.log_info(message)
  -- FIXME: toast_notification does not time out, workaround by running `notify-send` CLI instead
  -- window:toast_notification("tabsets.wezterm", message, nil, 4000)
  wezterm.run_child_process {
    "bash", "-c",
    "notify-send -a 'tabsets.wezterm' -t 4000 -u normal '" ..
    message:gsub("'", "'\"'\"'") .. "'",
  }
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

  local tabset_data = {
    window_width = dims.pixel_width,   -- the width of the window in pixels
    window_height = dims.pixel_height, -- the height of the window in pixels
    colors = cfg.colors,
    tabs = {}
  }

  -- Iterate over tabs in the current window
  for _, tab in ipairs(window:mux_window():tabs()) do
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
    wezterm.log_error("No tabset data to save.")
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
    wezterm.log_error("Invalid or empty tabset data.")
    return false
  end

  local tabs = window:mux_window():tabs()

  local window_is_empty = false
  if #tabs == 1 and #tabs[1]:panes() == 1 then
    local initial_pane = window:active_pane()
    local foreground_process = initial_pane:get_foreground_process_name()
    if is_shell(foreground_process) then
      initial_pane:send_text("exit\r")
      wezterm.log_info("Existing single empty tab closed.")
      window_is_empty = true
    end
  end

  -- Restore window size and colors
  if window_is_empty then
    if options.restore_colors then
      window:set_config_overrides({ colors = tabset_data.colors or {} })
    end
    if options.restore_dimensions then
      window:set_inner_size(tabset_data.window_width, tabset_data.window_height)
    end
  end

  -- Recreate tabs and panes from the saved state
  for _, tab_data in ipairs(tabset_data.tabs) do
    local cwd_uri = tab_data.panes[1].cwd
    local cwd_path = extract_path_from_uri(cwd_uri)

    local new_tab = window:mux_window():spawn_tab({ cwd = cwd_path })
    if not new_tab then
      wezterm.log_error("Failed to create a new tab.")
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

        new_pane = new_tab:active_pane():split({
          direction = direction,
          cwd = extract_path_from_uri(pane_data.cwd),
        })
      end

      if not new_pane then
        wezterm.log_error("Failed to create a new pane.")
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

  wezterm.log_info("Tabset recreated.")
  return true
end

--- Load tabset data from a JSON file.
--- Parses the JSON content and returns the decoded Lua table or nil on error.
--- @param file_path string Path to the JSON file
--- @return TabsetData|nil #Decoded tabset data, or nil if the file cannot be opened or parsed
local function load_from_json_file(file_path)
  local file = io.open(file_path, "r")
  if not file then
    wezterm.log_error("Failed to open file '" .. file_path .. "'.")
    return nil
  end

  local file_content = file:read("*a")
  file:close()

  local data = wezterm.json_parse(file_content)
  if not data then
    wezterm.log_error("Failed to parse JSON data from tabset file '" .. file_path .. "'.")
  end
  --- @cast data TabsetData|nil
  return data
end

--- Load and restore a tabset by its logical name.
--- If loading or recreation fails, a notification is shown to the user.
--- @param window wezterm.window Active wezterm window
--- @param name string|nil Tabset name (without extension), defaults to "default"
function M.load_tabset_by_name(window, name)
  name = name or "default"
  local file_path = tabset_file(name)

  local tabset_data = load_from_json_file(file_path)
  if not tabset_data then
    display_notification(window, "Tabset file not found '" .. file_path .. "'.")
    return
  end

  if recreate_tabset(window, tabset_data) then
    display_notification(window, "Tabset loaded '" .. name .. "'.")
  else
    -- FIXME: report the actual logged error: devise a better logging + notification system
    display_notification(window, "Tabset loading failed '" .. name .. "'.")
  end
end

--- Helper to collect tabset names and run a callback on selection.
--- Presents an input selector listing all discovered tabset files.
--- @param window wezterm.window Active wezterm window
--- @param callback fun(window: wezterm.window, pane: wezterm.pane, id: string): void Callback invoked as callback(window, pane, id)
local function tabset_action(window, callback)
  -- Collect tabset names
  local choices = {}
  local ok, files = pcall(wezterm.read_dir, options.tabsets_dir)
  if not ok then
    display_notification(window, "Failed to read tabsets directory '" .. options.tabsets_dir .. "'.")
    return
  end
  for _, f in ipairs(files) do
    f = basename(f)
    if f:match("%.tabset%.json$") then
      local name = f:gsub("%.tabset%.json$", "")
      table.insert(choices, { id = name, label = name })
    end
  end

  if #choices == 0 then
    display_notification(window, "No saved tabset files found.")
    return
  end

  table.sort(choices, function(a, b)
    -- Ensure "default" is the first array item.
    if a.id == "default" and b.id ~= "default" then
      return true
    elseif b.id == "default" and a.id ~= "default" then
      return false
    else
      return a.id < b.id
    end
  end)

  window:perform_action(act.InputSelector {
    choices = choices,
    action = wezterm.action_callback(callback),
  }, window:active_pane())
end

--- Interactively load a saved tabset.
--- Shows a selector of available tabsets, then calls @{load_tabset_by_name} on the chosen entry.
--- @param window wezterm.window Active wezterm window
function M.load_tabset(window)
  tabset_action(window,
    function(_, _, id)
      if id then
        M.load_tabset_by_name(window, id)
      end
    end)
end

--- Interactively delete a saved tabset.
--- Prompts for a tabset, deletes the corresponding JSON file and notifies the user.
--- @param window wezterm.window Active wezterm window
function M.delete_tabset(window)
  tabset_action(window,
    function(_, _, id)
      if id then
        local f = tabset_file(id)
        if fs.rm(f) then
          display_notification(window, "Deleted tabset '" .. id .. "'.")
        else
          wezterm.log_error("Failed to delete tabsets file '" .. f .. "'.")
        end
      end
    end)
end

--- Interactively save the current window layout as a tabset.
--- Prompts for a tabset name, validates it and writes a JSON description to disk.
--- @param window wezterm.window Active wezterm window
function M.save_tabset(window)
  --- @type TabsetData
  local data = retrieve_tabset_data(window)

  window:perform_action(act.PromptInputLine {
    description = "Enter tabset name",
    initial_value = "default",
    action = wezterm.action_callback(function(_, _, name)
      if not is_valid_tabset_name(name) then
        display_notification(window, "Invalid tabset name '" .. name .. "'.")
        return
      end
      local data_file = tabset_file(name)
      if save_to_json_file(data, data_file) then
        display_notification(window, "Tabset '" .. name .. "' saved successfully.")
      else
        display_notification(window, "Failed to save '" .. data_file .. "'.")
      end
    end),
  }, window:active_pane())
end

--- Initialize plugin and set configuration options.
--- @param opts TabsetOptions|nil Options table
function M.setup(opts)
  if opts then
    --- @cast opts TabsetOptions
    options = opts
  end
  -- Set default tabsets directory
  if not options.tabsets_dir then
    options.tabsets_dir = wezterm.config_dir .. "/tabsets.wezterm"
  end
  -- Create the tabsets directory if it does not exist
  local dir = options.tabsets_dir
  if not fs.is_directory(dir) then
    if fs.mkdir(dir) then
      wezterm.log_info("Created tabsets directory '" .. dir .. "'.")
    else
      wezterm.log_error("Failed to create tabsets directory '" .. dir .. "'.")
    end
  end
end

return M
