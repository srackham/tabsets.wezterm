local wezterm = require("wezterm")
local act = wezterm.action
local M = {}

-- Given "/foo/bar" returns "bar"
-- Given "c:\\foo\\bar" returns "bar"
local function basename(s)
  return string.gsub(s, "(.*[/\\])(.*)", "%2")
end

-- Returns true if name only contains alphanumeric and +- ._ characters
local function is_valid_tabset_name(name)
  if name:match("^[%w%+%.%-_%s]+$") then return true else return false end
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

-- Returns true if file_path is a shell
local function is_shell(file_path)
  local shells = { "sh", "bash", "zsh", "fish", "nu", "dash", "csh", "ksh" }
  for _, shell in ipairs(shells) do
    if basename(file_path) == shell then return true end
  end
  return false
end

local function extract_path_from_uri(uri)
  return uri:gsub("^file://", "")
end

local function resolve_executable(path)
  -- 1. Does the path exist and is it executable?
  local ok = wezterm.run_child_process { "test", "-x", path, }
  if ok then
    return path
  end
  -- 2. Try resolving via `which`
  local success, stdout, _ = wezterm.run_child_process { "which", path, }
  if success and stdout then
    -- trim trailing newline(s)
    local resolved = stdout:gsub("%s+$", "")
    if resolved ~= "" then
      return resolved
    end
  end
  -- 3. Not found
  wezterm.log_error("Failed to resolve executable '" .. path .. "'.")
  return nil
end

--- Logs a message and displays it with a desktop notification
local function display_notification(window, message)
  wezterm.log_info(message)
  -- FIXME: toast_notification does not time out, workaround by running `notify-send` CLI instead
  -- window:toast_notification("tabsets.wezterm", message, nil, 4000)
  wezterm.run_child_process { "bash", "-c", "notify-send -a 'tabsets.wezterm' -t 4000 -u normal '" .. message:gsub("'", "'\"'\"'") .. "'" }
end

--- Retrieves the current tabset data from the active window.
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
      panes = {}
    }

    -- Iterate over panes in the current tab
    for _, pane_info in ipairs(tab:panes_with_info()) do
      -- Collect pane details, including layout and process information
      table.insert(tab_data.panes, {
        left = pane_info.left,
        cwd = tostring(pane_info.pane:get_current_working_dir()),
        exe = tostring(pane_info.pane:get_foreground_process_name())
      })
    end

    table.insert(tabset_data.tabs, tab_data)
  end

  return tabset_data
end

-- Save data to a JSON file.
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
  else
    return false
  end
end

--- Recreate the tabset from tabset_data
local function recreate_tabset(window, tabset_data)
  if not tabset_data or not tabset_data.tabs then
    wezterm.log_error("Invalid or empty tabset data.")
    return
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
    window:set_inner_size(tabset_data.window_width, tabset_data.window_height)
    window:set_config_overrides({ colors = tabset_data.colors or {} })
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
          cwd = extract_path_from_uri(pane_data.cwd)
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

-- Loads tabset data from a JSON file.
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
  return data
end

--- Loads the saved json file corresponding to the tabset name.
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

local function tabset_action(window, callback)
  -- Collect tabset names
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
    action = wezterm.action_callback(callback)
  }, window:active_pane())
end

--- Load selected tabset
function M.load_tabset(window)
  tabset_action(window,
    function(_, _, id)
      if id then
        M.load_tabset_by_name(window, id)
      end
    end)
end

--- Delete selected tabset
function M.delete_tabset(window)
  tabset_action(window,
    function(_, _, id)
      if id then
        wezterm.run_child_process { "rm", "-f", tabset_file(id) }
        display_notification(window, "Deleted tabset '" .. id .. "'.")
      end
    end)
end

--- Save the current tabset state.
function M.save_tabset(window)
  local data = retrieve_tabset_data(window)

  window:perform_action(act.PromptInputLine {
    description = "Enter tabset name",
    initial_value = "default",
    action = wezterm.action_callback(function(_, _, name)
      if not is_valid_tabset_name(name) then
        display_notification(window, "Invalid tabset name '" .. name .. "'.")
        return
      end
      data.name = name
      local data_file = tabset_file(name)
      if save_to_json_file(data, data_file) then
        display_notification(window, "Tabset '" .. name .. "' saved successfully.")
      else
        display_notification(window, "Failed to save '" .. data_file .. "'.")
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
