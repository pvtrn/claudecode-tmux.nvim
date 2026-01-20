--- Agent instructions for Claude Code Neovim integration.
--- These instructions are sent to Claude when it connects via MCP.

local M = {}

--- Default instructions for the agent.
--- These describe the available Neovim control tools.
M.default_instructions = [[
# Neovim Control Instructions

You are connected to Neovim via MCP. You can control the editor using these tools:

## File Operations

### openFile
Opens files with split support. Default creates vertical split (side by side).

Parameters:
- filePath (required): Path to the file
- startLine: Line number to jump to
- endLine: End line for selection
- split: "vertical" (default), "horizontal", or "none"
- preview: Open in preview mode
- makeFrontmost: Focus window after opening (default: true)

Examples:
- Open file in vertical split: {"filePath": "/path/file.lua"}
- Jump to line 42: {"filePath": "/path/file.lua", "startLine": 42}
- Horizontal split: {"filePath": "/path/file.lua", "split": "horizontal"}
- Same window: {"filePath": "/path/file.lua", "split": "none"}

### executeCommand
Execute arbitrary Neovim commands or Lua code.

Parameters:
- command: Neovim Ex command (e.g., "vsplit", "wincmd h", "42")
- lua: Lua code to execute

Window navigation:
- {"command": "wincmd h"} - Move to left window
- {"command": "wincmd l"} - Move to right window
- {"command": "wincmd j"} - Move to window below
- {"command": "wincmd k"} - Move to window above

Tab commands:
- {"command": "tabnew"} - New tab
- {"command": "tabnext"} - Next tab
- {"command": "tabclose"} - Close tab

### Other Tools
- getCurrentSelection: Get selected text
- getLatestSelection: Get most recent selection
- getOpenEditors: List open files
- getDiagnostics: Get LSP errors/warnings
- saveDocument: Save file (params: filePath)
- checkDocumentDirty: Check unsaved changes (params: filePath)
- openDiff: Open diff view
- closeAllDiffTabs: Close all diffs
- getWorkspaceFolders: Get workspace info

## Tips
- Default split is vertical for side-by-side file comparison
- Use split: "none" to replace current buffer
- Combine executeCommand for navigation with openFile for opening
- Smart window reuse: openFile automatically reuses existing empty windows or existing splits instead of creating new ones. New splits are only created when needed.

## CLI Alternative (nvim-control)
If MCP tools are not available directly, use the nvim-control CLI via Bash:

```bash
# Open file in vertical split (default)
nvim-control open /path/to/file.lua

# Open file at specific line
nvim-control open /path/to/file.lua --line 42

# Open in horizontal split
nvim-control open /path/to/file.lua --split horizontal

# Open in same window (no split)
nvim-control open /path/to/file.lua --split none

# Open file in specific window (1-based number)
nvim-control open /path/to/file.lua --window 2

# List editor windows (shows window numbers)
nvim-control windows

# Focus specific window
nvim-control focus 1
nvim-control focus 2

# Close specific window
nvim-control close-window 2

# Execute Neovim command
nvim-control exec "vsplit"
nvim-control exec "wincmd h"
nvim-control exec "tabnew"

# Execute Lua code
nvim-control lua "return vim.fn.expand('%:p')"

# List available tools
nvim-control list-tools
```

## Window Management
- Use `nvim-control windows` to see numbered list of editor windows
- Use `--window N` to open file in specific window (1 = first, 2 = second, etc.)
- Use `nvim-control focus N` to switch to window N
- Use `nvim-control close-window N` to close window N
]]

--- Get the instructions to send to the agent.
--- Can be customized via config or by providing a file path.
---@param config table|nil Optional config with custom instructions
---@return string instructions The instructions text
function M.get_instructions(config)
  -- Check if user provided custom instructions
  if config and config.agent_instructions then
    local instructions = config.agent_instructions

    -- If it's a file path, read the file
    if type(instructions) == "string" and vim.fn.filereadable(instructions) == 1 then
      local file = io.open(instructions, "r")
      if file then
        local content = file:read("*all")
        file:close()
        return content
      end
    end

    -- Otherwise use it as-is
    if type(instructions) == "string" then
      return instructions
    end
  end

  -- Return default instructions
  return M.default_instructions
end

return M
