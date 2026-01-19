--- Zellij terminal provider for Claude Code.
--- Launches Claude Code in a zellij split pane within the same zellij session.
---@module 'claudecode.terminal.zellij'

---@type ClaudeCodeTerminalProvider
local M = {}

local logger = require("claudecode.logger")

---@type boolean
local pane_created = false
---@type ClaudeCodeTerminalConfig
local config

-- Cached zellij version info
---@type string|nil
local zellij_version = nil

---Cleans up the internal state
local function cleanup_state()
  pane_created = false
end

---Executes a zellij command and returns the output
---@param args string[] The zellij command arguments
---@return string|nil output The command output, or nil on error
---@return string|nil error The error message, or nil on success
local function zellij_cmd(args)
  local cmd = { "zellij" }
  for _, arg in ipairs(args) do
    table.insert(cmd, arg)
  end

  local result = vim.fn.system(cmd)
  local exit_code = vim.v.shell_error

  if exit_code ~= 0 then
    return nil, "zellij command failed: " .. vim.inspect(cmd) .. " (exit code: " .. exit_code .. ")"
  end

  -- Trim trailing whitespace/newlines
  return result:gsub("%s+$", ""), nil
end

---Executes a zellij command as a shell string (for commands with complex arguments)
---@param cmd_str string The full command string
---@return string|nil output The command output, or nil on error
---@return string|nil error The error message, or nil on success
local function zellij_cmd_string(cmd_str)
  logger.debug("terminal", "executing zellij command: " .. cmd_str)
  local result = vim.fn.system(cmd_str)
  local exit_code = vim.v.shell_error

  if exit_code ~= 0 then
    return nil, "zellij command failed: " .. cmd_str .. " (exit code: " .. exit_code .. ")"
  end

  return result:gsub("%s+$", ""), nil
end

---Gets the zellij version (cached after first call)
---@return string version The zellij version string (e.g., "0.40.0") or "unknown"
local function get_zellij_version()
  if zellij_version ~= nil then
    return zellij_version
  end

  local output, _ = zellij_cmd({ "--version" })
  if output then
    -- Parse version from output like "zellij 0.40.0"
    zellij_version = output:match("zellij%s+([%d%.]+)") or "unknown"
  else
    zellij_version = "unknown"
  end

  logger.debug("terminal", "Detected zellij version: " .. zellij_version)
  return zellij_version
end

---@param term_config ClaudeCodeTerminalConfig
function M.setup(term_config)
  config = term_config or {}
end

---@return boolean
function M.is_available()
  -- Check if we're inside a zellij session
  -- ZELLIJ env var is set to "0" inside a zellij session
  local zellij_env = vim.env.ZELLIJ
  if not zellij_env then
    logger.debug("terminal", "zellij provider: not in a zellij session ($ZELLIJ not set)")
    return false
  end

  -- Check if zellij executable is available
  local zellij_exists = vim.fn.executable("zellij") == 1
  if not zellij_exists then
    logger.debug("terminal", "zellij provider: zellij executable not found")
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

  if pane_created then
    -- Pane already exists, just focus if needed
    if focus then
      zellij_cmd({ "action", "focus-next-pane" })
    end
    logger.debug("terminal", "zellij pane already created")
    return
  end

  -- Build environment prefix (inline env vars like we do for tmux)
  local env_parts = {}
  for key, value in pairs(env_table) do
    table.insert(env_parts, key .. "=" .. tostring(value))
  end
  local env_prefix = table.concat(env_parts, " ")
  local full_command = env_prefix .. " " .. cmd_string

  -- Determine split direction based on config
  local split_side = effective_config.split_side or config.split_side or "right"
  local direction = split_side == "left" and "left" or "right"

  -- Build zellij run command
  -- zellij run -d right -- sh -c "ENV=val claude --ide"
  local cmd_str = "zellij run -d " .. direction

  -- Add name for the pane
  cmd_str = cmd_str .. ' -n "Claude"'

  -- Working directory
  local cwd = effective_config.cwd
  if cwd and cwd ~= "" then
    cmd_str = cmd_str .. " --cwd '" .. cwd:gsub("'", "'\\''") .. "'"
  end

  -- Add the command (using sh -c to handle env vars properly)
  cmd_str = cmd_str .. ' -- sh -c "' .. full_command:gsub('"', '\\"') .. '"'

  logger.debug("terminal", "zellij full command: " .. cmd_str)

  local _, err = zellij_cmd_string(cmd_str)
  if err then
    vim.notify("Failed to create zellij pane: " .. err, vim.log.levels.ERROR)
    return
  end

  -- Zellij creates panes at 50% by default. We need to resize to match the configured width.
  -- The resize command is incremental, so we calculate how many steps needed.
  local width_pct = effective_config.split_width_percentage or config.split_width_percentage or 0.30
  local target_pct = width_pct * 100 -- e.g., 35
  local default_pct = 50
  local diff_pct = default_pct - target_pct -- e.g., 50 - 35 = 15 (need to shrink by 15%)

  if diff_pct > 0 then
    -- Need to shrink the Claude pane (it's currently focused after creation)
    -- Each resize step is roughly 5% of terminal width
    local resize_steps = math.floor(diff_pct / 5)
    local resize_direction = split_side == "left" and "right" or "left"

    for _ = 1, resize_steps do
      zellij_cmd({ "action", "resize", "decrease", resize_direction })
    end
    logger.debug("terminal", "Resized zellij pane by " .. resize_steps .. " steps")
  elseif diff_pct < 0 then
    -- Need to grow the Claude pane
    local resize_steps = math.floor(math.abs(diff_pct) / 5)
    local resize_direction = split_side == "left" and "right" or "left"

    for _ = 1, resize_steps do
      zellij_cmd({ "action", "resize", "increase", resize_direction })
    end
    logger.debug("terminal", "Resized zellij pane by " .. resize_steps .. " steps")
  end

  pane_created = true
  logger.debug("terminal", "Created zellij pane")
  logger.debug("terminal", "Environment variables passed: " .. vim.inspect(env_table))

  if not focus then
    -- Return focus to neovim pane
    zellij_cmd({ "action", "focus-previous-pane" })
  end
end

function M.close()
  if not pane_created then
    return
  end

  -- Focus the Claude pane first, then close it
  -- This is a bit tricky since zellij doesn't track pane IDs easily
  -- We'll close the "next" pane assuming it's the Claude pane
  zellij_cmd({ "action", "focus-next-pane" })
  local _, err = zellij_cmd({ "action", "close-pane" })
  if err then
    logger.warn("terminal", "Failed to close zellij pane: " .. err)
  else
    logger.debug("terminal", "Closed zellij pane")
  end

  cleanup_state()
end

---Simple toggle: open or close the Claude pane
---@param cmd_string string
---@param env_table table
---@param effective_config table
function M.simple_toggle(cmd_string, env_table, effective_config)
  if pane_created then
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
  if not pane_created then
    -- No Claude pane exists, create one
    M.open(cmd_string, env_table, effective_config, true)
    return
  end

  -- Toggle focus between panes
  -- Zellij doesn't easily tell us which pane is focused, so we just toggle
  zellij_cmd({ "action", "focus-next-pane" })
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
  -- Zellij terminals don't have associated Neovim buffers
  return nil
end

---Ensures the Claude pane is visible (creates if needed, no-op if exists since zellij panes are always visible)
function M.ensure_visible()
  -- In zellij, panes are always visible when they exist
  if pane_created then
    logger.debug("terminal", "zellij pane is visible")
  end
end

---@return table?
function M._get_terminal_for_test()
  if pane_created then
    return {
      pane_created = pane_created,
    }
  end
  return nil
end

---Returns debug information about the zellij provider state
---@return table debug_info Table containing version, capabilities, and state information
function M.debug_info()
  return {
    zellij_version = get_zellij_version(),
    pane_created = pane_created,
    is_available = M.is_available(),
    config = config,
  }
end

return M
