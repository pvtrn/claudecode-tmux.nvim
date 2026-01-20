--- Tool implementation for executing arbitrary Neovim commands.

local schema = {
  description = "Execute a Neovim command or Lua code. Use this to control the editor: navigate, edit, run commands, etc.",
  inputSchema = {
    type = "object",
    properties = {
      command = {
        type = "string",
        description = "Neovim Ex command to execute (e.g., 'vsplit', 'tabnew', 'set number')",
      },
      lua = {
        type = "string",
        description = "Lua code to execute in Neovim (e.g., 'vim.api.nvim_set_option(\"number\", true)')",
      },
    },
    additionalProperties = false,
    ["$schema"] = "http://json-schema.org/draft-07/schema#",
  },
}

---Handles the executeCommand tool invocation.
---Executes a Neovim command or Lua code.
---@param params table The input parameters for the tool
---@return table MCP-compliant response with execution result
local function handler(params)
  if not params.command and not params.lua then
    error({
      code = -32602,
      message = "Invalid params",
      data = "Either 'command' or 'lua' parameter is required",
    })
  end

  local results = {}

  -- Execute Ex command if provided
  if params.command then
    local success, err = pcall(vim.cmd, params.command)
    if success then
      table.insert(results, {
        type = "command",
        command = params.command,
        success = true,
      })
    else
      table.insert(results, {
        type = "command",
        command = params.command,
        success = false,
        error = tostring(err),
      })
    end
  end

  -- Execute Lua code if provided
  if params.lua then
    local chunk, load_err = loadstring(params.lua)
    if not chunk then
      table.insert(results, {
        type = "lua",
        code = params.lua,
        success = false,
        error = "Failed to parse Lua: " .. tostring(load_err),
      })
    else
      local success, result = pcall(chunk)
      if success then
        table.insert(results, {
          type = "lua",
          code = params.lua,
          success = true,
          result = result ~= nil and vim.inspect(result) or nil,
        })
      else
        table.insert(results, {
          type = "lua",
          code = params.lua,
          success = false,
          error = tostring(result),
        })
      end
    end
  end

  -- Check overall success
  local all_success = true
  for _, r in ipairs(results) do
    if not r.success then
      all_success = false
      break
    end
  end

  return {
    content = {
      {
        type = "text",
        text = vim.json.encode({
          success = all_success,
          results = results,
        }, { indent = 2 }),
      },
    },
  }
end

return {
  name = "executeCommand",
  schema = schema,
  handler = handler,
}
