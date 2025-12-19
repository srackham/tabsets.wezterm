---@module 'fs'
---@brief WezTerm filesystem helpers using external commands (POSIX)

local wezterm = require 'wezterm'

---@class fs
local fs = {}

-- Internal helper
---@param cmd string[]
---@return boolean ok
---@return string? stdout
---@return string? stderr
local function run(cmd)
  local ok, stdout, stderr = wezterm.run_child_process(cmd)
  return ok, stdout, stderr
end

---Check whether a filesystem path exists.
---Uses `test -e`.
---@param path string
---@return boolean
function fs.is_path(path)
  local ok = run { 'test', '-e', path }
  return ok
end

---Check whether a filesystem path is a regular file.
---Uses `test -f`.
---@param path string
---@return boolean
function fs.is_file(path)
  local ok = run { 'test', '-f', path }
  return ok
end

---Check whether a path exists and is a directory.
---Uses `test -d`.
---@param path string
---@return boolean
function fs.is_directory(path)
  local ok = run { 'test', '-d', path }
  return ok
end

---Check whether a path exists and is executable.
---Uses `test -x`.
---@param path string
---@return boolean
function fs.is_executable(path)
  local ok = run { 'test', '-x', path }
  return ok
end

---Resolve a command using `which`.
---@param command string
---@return string|nil resolved_path Absolute path if found, otherwise nil
function fs.which(command)
  local ok, stdout = run { 'which', command }
  if not ok or not stdout then
    return nil
  end
  return (stdout:gsub('%s+$', '')) -- trim trailing newline(s)
end

---Remove a file.
---Uses `rm -f`.
---@param path string
---@return boolean success
function fs.rm(path)
  local ok, _, stderr = run { 'rm', '-f', path }
  if not ok then
    wezterm.log_error('rm failed: ' .. (stderr or 'unknown error'))
    return false
  end
  return true
end

---Remove a file or directory recursively.
---Uses `rm -rf`.
---@param path string
---@return boolean success
function fs.rm_rf(path)
  local ok, _, stderr = run { 'rm', '-rf', path }
  if not ok then
    wezterm.log_error('rm_rf failed: ' .. (stderr or 'unknown error'))
    return false
  end
  return true
end

---Remove an empty directory.
---Uses `rmdir`.
---@param path string
---@return boolean success
function fs.rmdir(path)
  local ok, _, stderr = run { 'rmdir', path }
  if not ok then
    wezterm.log_error('rmdir failed: ' .. (stderr or 'unknown error'))
    return false
  end
  return true
end

---Create a directory and any missing parent directories.
---Uses `mkdir -p`.
---@param path string
---@return boolean success
function fs.mkdir(path)
  local ok, _, stderr = run { 'mkdir', '-p', path }
  if not ok then
    wezterm.log_error('mkdir failed: ' .. (stderr or 'unknown error'))
    return false
  end
  return true
end

---Rename or move a file or directory.
---Uses `mv`.
---@param src_path string
---@param dst_path string
---@return boolean success
function fs.mv(src_path, dst_path)
  local ok, _, stderr = run { 'mv', src_path, dst_path }
  if not ok then
    wezterm.log_error('mv failed: ' .. (stderr or 'unknown error'))
    return false
  end
  return true
end

return fs
