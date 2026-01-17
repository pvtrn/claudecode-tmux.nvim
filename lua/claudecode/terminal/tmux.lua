--- Tmux terminal provider for Claude Code.
--- Launches Claude Code in a tmux split pane within the same tmux session.
---@module 'claudecode.terminal.tmux'

---@type ClaudeCodeTerminalProvider
local M = {}

local logger = require("claudecode.logger")

---@type string|nil
local pane_id = nil
---@type string|nil
local nvim_pane_id = nil
---@type ClaudeCodeTerminalConfig
local config

-- Cached tmux version info
---@type string|nil
local tmux_version = nil
---@type boolean|nil
local tmux_supports_env_flag = nil

---Cleans up the internal state
local function cleanup_state()
  pane_id = nil
end

---Executes a tmux command and returns the output
---@param args string[] The tmux command arguments
---@return string|nil output The command output, or nil on error
---@return string|nil error The error message, or nil on success
local function tmux_cmd(args)
  local cmd = { "tmux" }
  for _, arg in ipairs(args) do
    table.insert(cmd, arg)
  end

  local result = vim.fn.system(cmd)
  local exit_code = vim.v.shell_error

  if exit_code ~= 0 then
    return nil, "tmux command failed: " .. vim.inspect(cmd) .. " (exit code: " .. exit_code .. ")"
  end

  -- Trim trailing whitespace/newlines
  return result:gsub("%s+$", ""), nil
end

---Executes a tmux command as a shell string (for commands with complex arguments)
---@param cmd_str string The full command string
---@return string|nil output The command output, or nil on error
---@return string|nil error The error message, or nil on success
local function tmux_cmd_string(cmd_str)
  logger.debug("terminal", "executing tmux command: " .. cmd_str)
  local result = vim.fn.system(cmd_str)
  local exit_code = vim.v.shell_error

  if exit_code ~= 0 then
    return nil, "tmux command failed: " .. cmd_str .. " (exit code: " .. exit_code .. ")"
  end

  return result:gsub("%s+$", ""), nil
end

---Gets the tmux version (cached after first call)
---@return string version The tmux version string (e.g., "3.4") or "unknown"
local function get_tmux_version()
  if tmux_version ~= nil then
    return tmux_version
  end

  local output, _ = tmux_cmd({ "-V" })
  if output then
    -- Parse version from output like "tmux 3.4" or "tmux 3.0a"
    tmux_version = output:match("tmux%s+([%d%.]+)") or "unknown"
  else
    tmux_version = "unknown"
  end

  logger.debug("terminal", "Detected tmux version: " .. tmux_version)
  return tmux_version
end

---Checks if tmux supports the -e flag for environment variables (tmux >= 3.0)
---@return boolean supports True if -e flag is supported
local function supports_env_flag()
  if tmux_supports_env_flag ~= nil then
    return tmux_supports_env_flag
  end

  local version = get_tmux_version()
  local major = tonumber(version:match("^(%d+)"))
  tmux_supports_env_flag = major ~= nil and major >= 3

  logger.debug("terminal", "tmux supports -e flag: " .. tostring(tmux_supports_env_flag))
  return tmux_supports_env_flag
end

---Checks if the tracked pane still exists
---@return boolean valid True if pane exists
local function is_pane_valid()
  if not pane_id then
    return false
  end

  local output, err = tmux_cmd({ "list-panes", "-F", "#{pane_id}" })
  if err or not output then
    return false
  end

  -- Check if our pane_id is in the list
  for line in output:gmatch("[^\r\n]+") do
    if line == pane_id then
      return true
    end
  end

  -- Pane no longer exists
  cleanup_state()
  return false
end

---Gets the current tmux pane ID (the neovim pane)
---@return string|nil pane_id The current pane ID, or nil on error
local function get_current_pane_id()
  local output, err = tmux_cmd({ "display-message", "-p", "#{pane_id}" })
  if err then
    logger.warn("terminal", "Failed to get current tmux pane: " .. err)
    return nil
  end
  return output
end

---Checks if we are currently focused on the Claude pane
---@return boolean focused True if Claude pane is focused
local function is_claude_pane_focused()
  if not pane_id then
    return false
  end

  local current = get_current_pane_id()
  return current == pane_id
end

---@param term_config ClaudeCodeTerminalConfig
function M.setup(term_config)
  config = term_config or {}
end

---@return boolean
function M.is_available()
  -- Check if we're inside a tmux session
  local tmux_env = vim.env.TMUX
  if not tmux_env or tmux_env == "" then
    logger.debug("terminal", "tmux provider: not in a tmux session ($TMUX not set)")
    return false
  end

  -- Check if tmux executable is available
  local tmux_exists = vim.fn.executable("tmux") == 1
  if not tmux_exists then
    logger.debug("terminal", "tmux provider: tmux executable not found")
    return false
  end

  return true
end

---@param cmd_string string
---@param env_table table
---@param effective_config table
---@param focus boolean|nil
function M.open(cmd_string, env_table, effective_config, focus)
  -- Default focus to true for backward compatibility
  if focus == nil then
    focus = true
  end

  if is_pane_valid() then
    -- Pane already exists
    if focus then
      -- Focus existing pane
      tmux_cmd({ "select-pane", "-t", pane_id })
    end
    logger.debug("terminal", "tmux pane already open: " .. pane_id)
    return
  end

  -- Remember the nvim pane for focus toggling
  nvim_pane_id = get_current_pane_id()

  -- Build the command string exactly like user would type it manually:
  -- tmux split-window -h -l 30% -P -F '#{pane_id}' "env VAR=val claude --ide"

  -- Build environment prefix
  local env_parts = {}
  for key, value in pairs(env_table) do
    table.insert(env_parts, key .. "=" .. tostring(value))
  end
  local env_prefix = table.concat(env_parts, " ")
  local full_command = env_prefix .. " " .. cmd_string

  -- Build tmux command string
  local cmd_str = "tmux split-window -h"

  -- Width percentage
  local width_pct = effective_config.split_width_percentage or config.split_width_percentage or 0.30
  local width_str = tostring(math.floor(width_pct * 100)) .. "%"
  cmd_str = cmd_str .. " -l " .. width_str

  -- Split side: "left" means split before current pane (-b flag)
  local split_side = effective_config.split_side or config.split_side or "right"
  if split_side == "left" then
    cmd_str = cmd_str .. " -b"
  end

  -- Working directory
  local cwd = effective_config.cwd
  if cwd and cwd ~= "" then
    cmd_str = cmd_str .. " -c '" .. cwd:gsub("'", "'\\''") .. "'"
  end

  -- Print the pane ID after creation
  cmd_str = cmd_str .. " -P -F '#{pane_id}'"

  -- Add the command with double quotes (like user types it)
  cmd_str = cmd_str .. ' "' .. full_command:gsub('"', '\\"') .. '"'

  logger.debug("terminal", "tmux full command: " .. cmd_str)

  local output, err = tmux_cmd_string(cmd_str)
  if err then
    vim.notify("Failed to create tmux split: " .. err, vim.log.levels.ERROR)
    return
  end

  pane_id = output
  logger.debug("terminal", "Created tmux pane: " .. pane_id)
  logger.debug("terminal", "Environment variables passed: " .. vim.inspect(env_table))

  if not focus then
    -- Return focus to neovim pane
    if nvim_pane_id then
      tmux_cmd({ "select-pane", "-t", nvim_pane_id })
    else
      tmux_cmd({ "select-pane", "-l" })
    end
  end
end

function M.close()
  if not is_pane_valid() then
    return
  end

  local _, err = tmux_cmd({ "kill-pane", "-t", pane_id })
  if err then
    logger.warn("terminal", "Failed to kill tmux pane: " .. err)
  else
    logger.debug("terminal", "Killed tmux pane: " .. pane_id)
  end

  cleanup_state()
end

---Simple toggle: open or close the Claude pane
---@param cmd_string string
---@param env_table table
---@param effective_config table
function M.simple_toggle(cmd_string, env_table, effective_config)
  if is_pane_valid() then
    M.close()
  else
    M.open(cmd_string, env_table, effective_config, true)
  end
end

---Smart focus toggle: focus if not focused, return to nvim if focused, or create if doesn't exist
---@param cmd_string string
---@param env_table table
---@param effective_config table
function M.focus_toggle(cmd_string, env_table, effective_config)
  if not is_pane_valid() then
    -- No Claude pane exists, create one
    M.open(cmd_string, env_table, effective_config, true)
    return
  end

  if is_claude_pane_focused() then
    -- Currently in Claude pane, switch back to nvim
    if nvim_pane_id then
      tmux_cmd({ "select-pane", "-t", nvim_pane_id })
    else
      tmux_cmd({ "select-pane", "-l" })
    end
  else
    -- Not in Claude pane, focus it
    tmux_cmd({ "select-pane", "-t", pane_id })
  end
end

---Legacy toggle function for backward compatibility
---@param cmd_string string
---@param env_table table
---@param effective_config table
function M.toggle(cmd_string, env_table, effective_config)
  M.simple_toggle(cmd_string, env_table, effective_config)
end

---@return number?
function M.get_active_bufnr()
  -- Tmux terminals don't have associated Neovim buffers
  return nil
end

---Ensures the Claude pane is visible (creates if needed, no-op if exists since tmux panes are always visible)
function M.ensure_visible()
  -- In tmux, panes are always visible when they exist
  -- This is a no-op if pane exists, but we could create one if needed
  -- For now, just validate that pane exists
  if is_pane_valid() then
    logger.debug("terminal", "tmux pane is visible: " .. pane_id)
  end
end

---@return table?
function M._get_terminal_for_test()
  if is_pane_valid() then
    return {
      pane_id = pane_id,
      nvim_pane_id = nvim_pane_id,
    }
  end
  return nil
end

---Returns debug information about the tmux provider state
---@return table debug_info Table containing version, capabilities, and state information
function M.debug_info()
  return {
    tmux_version = get_tmux_version(),
    supports_env_flag = supports_env_flag(),
    pane_id = pane_id,
    nvim_pane_id = nvim_pane_id,
    pane_valid = is_pane_valid(),
    is_available = M.is_available(),
    config = config,
  }
end

return M
