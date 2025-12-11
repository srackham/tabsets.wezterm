local wezterm = require("wezterm")
local act = wezterm.action
local M = {}
local os = wezterm.target_triple

-- Equivalent to POSIX basename(3)
-- Given "/foo/bar" returns "bar"
-- Given "c:\\foo\\bar" returns "bar"
local function basename(s)
  return string.gsub(s, "(.*[/\\])(.*)", "%2")
end

-- Return truthy if name only contains alphanumeric and +- ._ characters
local function is_valid_tabset_name(name)
  return name:match("^[%w%+%.%-_%s]+$")
end

local tabsets_dir

local function get_tabsets_dir()
  return tabsets_dir or wezterm.config_dir .. "/tabsets.wezterm"
end

local function set_tabsets_dir(dir)
  tabsets_dir = dir
end

local function tabset_file(name)
  return get_tabsets_dir() .. "/" .. name .. ".tabset.json"
end

-- Returns true if at shell prompt.
local function is_shell(file_path)
  local shells = { "sh", "bash", "zsh", "fish", "nu", "dash", "csh", "ksh" }
  for _, shell in ipairs(shells) do
    if basename(file_path) == shell then return true end
  end
  return false
end

--- Displays a notification in WezTerm.
local function display_notification(window, message)
  wezterm.log_info(message)
  -- FIXME: toast_notification does not time out, workaround by running `notify-send` CLI instead
  -- window:toast_notification("WezTerm Session Manager", message, nil, 4000)
  wezterm.run_child_process { "bash", "-c", "notify-send -a 'Wezterm Session Manager' -t 4000 -u normal '" .. message:gsub("'", "'\"'\"'") .. "'" }
end

--- Retrieves the current workspace data from the active window.
local function retrieve_workspace_data(window)
  local workspace_name = window:active_workspace()
  local dims = window:get_dimensions()
  local cfg = window:effective_config()

  local workspace_data = {
    name = workspace_name,
    pixel_width = dims.pixel_width,       -- the width of the window in pixels
    pixel_height = dims.pixel_height,     -- the height of the window in pixels
    is_full_screen = dims.is_full_screen, -- whether the window is in full screen mode
    colors = cfg.colors,
    tabs = {}
  }

  -- Iterate over tabs in the current window
  for _, tab in ipairs(window:mux_window():tabs()) do
    local tab_data = {
      tab_id = tostring(tab:tab_id()),
      title = tab:get_title(),
      panes = {}
    }

    -- Iterate over panes in the current tab
    for _, pane_info in ipairs(tab:panes_with_info()) do
      -- Collect pane details, including layout and process information
      table.insert(tab_data.panes, {
        pane_id = tostring(pane_info.pane:pane_id()),
        index = pane_info.index,
        is_active = pane_info.is_active,
        is_zoomed = pane_info.is_zoomed,
        left = pane_info.left,
        top = pane_info.top,
        width = pane_info.width,
        height = pane_info.height,
        pixel_width = pane_info.pixel_width,
        pixel_height = pane_info.pixel_height,
        cwd = tostring(pane_info.pane:get_current_working_dir()),
        tty = tostring(pane_info.pane:get_foreground_process_name())
      })
    end

    table.insert(workspace_data.tabs, tab_data)
  end

  return workspace_data
end

--- Saves data to a JSON file.
-- @param data table: The workspace data to be saved.
-- @param file_path string: The file path where the JSON file will be saved.
-- @return boolean: true if saving was successful, false otherwise.
local function save_to_json_file(data, file_path)
  if not data then
    wezterm.log_info("No workspace data to log.")
    return false
  end

  local file = io.open(file_path, "w")
  if file then
    file:write(wezterm.json_encode(data))
    file:close()
    return true
  else
    return false
  end
end

--- Recreates the workspace based on the provided data.
-- @param workspace_data table: The data structure containing the saved workspace state.
local function recreate_workspace(window, workspace_data)
  local function extract_path_from_dir(working_directory)
    if os == "x86_64-pc-windows-msvc" then
      -- On Windows, transform 'file:///C:/path/to/dir' to 'C:/path/to/dir'
      return working_directory:gsub("file:///", "")
    elseif os == "x86_64-unknown-linux-gnu" then
      -- On Linux, transform 'file://{computer-name}/home/{user}/path/to/dir' to '/home/{user}/path/to/dir'
      return working_directory:gsub("^.*(/home/)", "/home/")
    else -- MacOS
      return working_directory:gsub("^.*(/Users/)", "/Users/")
    end
  end

  if not workspace_data or not workspace_data.tabs then
    wezterm.log_info("Invalid or empty workspace data provided.")
    return
  end

  local tabs = window:mux_window():tabs()

  local is_empty_window = false
  if #tabs == 1 and #tabs[1]:panes() == 1 then
    local initial_pane = window:active_pane()
    local foreground_process = initial_pane:get_foreground_process_name()
    if is_shell(foreground_process) then
      initial_pane:send_text("exit\r")
      wezterm.log_info("Initial lone tab closed.")
      is_empty_window = true
    else
      wezterm.log_info("Initial tab left open because a running program was detected.")
    end
  end

  if is_empty_window then
    -- Restore window size and colors
    window:set_inner_size(workspace_data.pixel_width, workspace_data.pixel_height)
    window:set_config_overrides({ colors = workspace_data.colors or {} })
  end

  -- Recreate tabs and panes from the saved state
  for _, tab_data in ipairs(workspace_data.tabs) do
    local cwd_uri = tab_data.panes[1].cwd
    local cwd_path = extract_path_from_dir(cwd_uri)

    local new_tab = window:mux_window():spawn_tab({ cwd = cwd_path })
    new_tab:set_title(tab_data.title)
    if not new_tab then
      wezterm.log_info("Failed to create a new tab.")
      break
    end

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
          cwd = extract_path_from_dir(pane_data.cwd)
        })
      end

      if not new_pane then
        wezterm.log_info("Failed to create a new pane.")
        break
      end

      if not is_shell(pane_data.tty) then
        new_pane:send_text(pane_data.tty .. "\n")
      end
    end
    first_pane:activate()
  end

  wezterm.log_info("Workspace recreated with new tabs and panes based on saved state.")
  return true
end

--- Loads data from a JSON file.
-- @param file_path string: The file path from which the JSON data will be loaded.
-- @return table or nil: The loaded data as a Lua table, or nil if loading failed.
local function load_from_json_file(file_path)
  local file = io.open(file_path, "r")
  if not file then
    wezterm.log_info("Failed to open file '" .. file_path .. "'")
    return nil
  end

  local file_content = file:read("*a")
  file:close()

  local data = wezterm.json_parse(file_content)
  if not data then
    wezterm.log_info("Failed to parse JSON data from file '" .. file_path .. "'")
  end
  return data
end

--- Loads the saved json file matching the current workspace.
function M.restore_state(window, name)
  name = name or "default"
  local file_path = tabset_file(name)

  local workspace_data = load_from_json_file(file_path)
  if not workspace_data then
    display_notification(window, "Workspace state file not found for workspace: '" .. name .. "'")
    return
  end

  if recreate_workspace(window, workspace_data) then
    display_notification(window, "Workspace state loaded for workspace '" .. name .. "'")
  else
    -- FIXME: report the actual logged error: devise a better logging + notification system
    display_notification(window, "Workspace state loading failed for workspace '" .. name .. "'")
  end
end

local function session_action(window, callback)
  -- Collect state names
  local choices = {}
  local ok, files = pcall(wezterm.read_dir, get_tabsets_dir())
  if not ok then
    display_notification(window, "Failed to read tabsets directory '" .. get_tabsets_dir() .. "'.")
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
    display_notification(window, "No saved session files found.")
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
    action = wezterm.action_callback(callback)
  }, window:active_pane())
end

--- Load selected session
function M.load_state(window)
  session_action(window,
    function(_, _, id)
      if id then
        M.restore_state(window, id)
      end
    end)
end

--- Delete selected session
function M.delete_state(window)
  session_action(window,
    function(_, _, id)
      if id then
        wezterm.run_child_process { "rm", "-f", tabset_file(id) }
        display_notification(window, "Deleted session '" .. id .. "'")
      end
    end)
end

--- Save the current workspace state.
function M.save_state(window)
  local data = retrieve_workspace_data(window)

  window:perform_action(act.PromptInputLine {
    description = "Enter session name",
    initial_value = "default",
    action = wezterm.action_callback(function(_, _, name)
      if not is_valid_tabset_name(name) then
        display_notification(window, "Invalid tabset name '" .. name .. "'")
        return
      end
      local data_file = tabset_file(name)
      if save_to_json_file(data, data_file) then
        display_notification(window, "Session '" .. name .. "' saved successfully")
      else
        display_notification(window, "Failed to save '" .. data_file .. "'")
      end
    end),
  }, window:active_pane())
end

function M.setup(opts)
  opts = opts or {}
  if opts.tabsets_dir then
    set_tabsets_dir(opts.tabsets_dir)
  elseif not tabsets_dir then
    -- Create default tabsets directory, makes intermediate directories and avoids errors if it already exists
    wezterm.run_child_process({ "mkdir", "-p", get_tabsets_dir() })
  end
end

return M
