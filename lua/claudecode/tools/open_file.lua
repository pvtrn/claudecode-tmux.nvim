--- Tool implementation for opening a file.

local schema = {
  description = "Open a file in the editor and optionally select a range of text",
  inputSchema = {
    type = "object",
    properties = {
      filePath = {
        type = "string",
        description = "Path to the file to open",
      },
      preview = {
        type = "boolean",
        description = "Whether to open the file in preview mode",
        default = false,
      },
      startLine = {
        type = "integer",
        description = "Optional: Line number to start selection",
      },
      endLine = {
        type = "integer",
        description = "Optional: Line number to end selection",
      },
      startText = {
        type = "string",
        description = "Text pattern to find the start of the selection range. Selects from the beginning of this match.",
      },
      endText = {
        type = "string",
        description = "Text pattern to find the end of the selection range. Selects up to the end of this match. If not provided, only the startText match will be selected.",
      },
      selectToEndOfLine = {
        type = "boolean",
        description = "If true, selection will extend to the end of the line containing the endText match.",
        default = false,
      },
      makeFrontmost = {
        type = "boolean",
        description = "Whether to make the file the active editor tab. If false, the file will be opened in the background without changing focus.",
        default = true,
      },
      split = {
        type = "string",
        enum = { "none", "vertical", "horizontal" },
        description = "How to split the window when opening the file. 'vertical' creates a vertical split (side by side), 'horizontal' creates a horizontal split (stacked). Default is 'horizontal'.",
        default = "horizontal",
      },
    },
    required = { "filePath" },
    additionalProperties = false,
    ["$schema"] = "http://json-schema.org/draft-07/schema#",
  },
}

---Checks if a window is a suitable editor window (not terminal, sidebar, floating, etc.)
---@param win integer Window ID to check
---@return boolean is_suitable True if window is suitable for editing
local function is_editor_window(win)
  local buf = vim.api.nvim_win_get_buf(win)
  local buftype = vim.api.nvim_buf_get_option(buf, "buftype")
  local filetype = vim.api.nvim_buf_get_option(buf, "filetype")
  local win_config = vim.api.nvim_win_get_config(win)

  -- Skip floating windows
  if win_config.relative and win_config.relative ~= "" then
    return false
  end

  -- Dashboard windows are suitable (can be replaced with files)
  local dashboard_filetypes = {
    "alpha", "dashboard", "starter", "snacks_dashboard",
    "ministarter", "lazy", "lazyterm"
  }
  for _, ft in ipairs(dashboard_filetypes) do
    if filetype == ft then
      return true
    end
  end

  -- Skip special buffer types (but not dashboards which we handled above)
  if buftype == "terminal" or buftype == "nofile" or buftype == "prompt" then
    return false
  end

  -- Skip known sidebar filetypes
  local sidebar_filetypes = {
    "neo-tree", "neo-tree-popup", "NvimTree", "oil",
    "minifiles", "netrw", "aerial", "tagbar"
  }
  for _, ft in ipairs(sidebar_filetypes) do
    if filetype == ft then
      return false
    end
  end

  return true
end

---Checks if a buffer is a dashboard/starter screen
---@param buf integer Buffer ID to check
---@return boolean is_dashboard True if buffer is a dashboard
local function is_dashboard_buffer(buf)
  local filetype = vim.api.nvim_buf_get_option(buf, "filetype")
  local dashboard_filetypes = {
    "alpha", "dashboard", "starter", "snacks_dashboard",
    "ministarter", "lazy", "lazyterm"
  }
  for _, ft in ipairs(dashboard_filetypes) do
    if filetype == ft then
      return true
    end
  end
  return false
end

---Checks if a buffer is empty (no name and no content) or a dashboard
---@param buf integer Buffer ID to check
---@return boolean is_empty True if buffer is empty or dashboard
local function is_buffer_empty(buf)
  -- Dashboard counts as empty - can be replaced with a file
  if is_dashboard_buffer(buf) then
    return true
  end

  local name = vim.api.nvim_buf_get_name(buf)
  if name ~= "" then
    return false
  end
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  return #lines == 1 and lines[1] == ""
end

---Finds all suitable editor windows and categorizes them.
---@return table result Table with editor_windows, empty_windows, and total count
local function analyze_editor_windows()
  local windows = vim.api.nvim_list_wins()
  local editor_windows = {}
  local empty_windows = {}

  for _, win in ipairs(windows) do
    if is_editor_window(win) then
      table.insert(editor_windows, win)
      local buf = vim.api.nvim_win_get_buf(win)
      if is_buffer_empty(buf) then
        table.insert(empty_windows, win)
      end
    end
  end

  return {
    editor_windows = editor_windows,
    empty_windows = empty_windows,
    count = #editor_windows,
  }
end

---Finds the best window to open a file in, considering existing windows.
---When split is requested (vertical/horizontal), always creates a new split.
---Only reuses empty/dashboard windows.
---@param file_path string The file path to open (to check if already open)
---@param want_split string "none", "vertical", or "horizontal"
---@return integer? target_win Window to open file in
---@return boolean should_split Whether to create a new split
local function find_best_window_for_file(file_path, want_split)
  local analysis = analyze_editor_windows()

  -- Check if file is already open in a window
  for _, win in ipairs(analysis.editor_windows) do
    local buf = vim.api.nvim_win_get_buf(win)
    local buf_name = vim.api.nvim_buf_get_name(buf)
    if buf_name == file_path then
      -- File already open, just focus it
      return win, false
    end
  end

  -- If split is "none", just find any editor window (prefer empty ones)
  if want_split == "none" then
    if #analysis.empty_windows > 0 then
      return analysis.empty_windows[1], false
    end
    if #analysis.editor_windows > 0 then
      return analysis.editor_windows[1], false
    end
    return nil, false
  end

  -- For split requests (vertical/horizontal):
  -- Only reuse empty/dashboard windows, otherwise create new split
  if #analysis.empty_windows > 0 then
    -- Use empty window instead of creating split
    return analysis.empty_windows[1], false
  end

  -- Only one editor window exists, need to create a split
  if #analysis.editor_windows == 1 then
    return analysis.editor_windows[1], true
  end

  -- No suitable windows found
  return nil, true
end

---Finds a suitable main editor window to open files in.
---Excludes terminals, sidebars, and floating windows.
---@return integer? win_id Window ID of the main editor window, or nil if not found
local function find_main_editor_window()
  local windows = vim.api.nvim_list_wins()

  for _, win in ipairs(windows) do
    if is_editor_window(win) then
      return win
    end
  end

  return nil
end

--- Handles the openFile tool invocation.
--- Opens a file in the editor with optional selection.
---@param params table The input parameters for the tool
---@return table MCP-compliant response with content array
local function handler(params)
  if not params.filePath then
    error({ code = -32602, message = "Invalid params", data = "Missing filePath parameter" })
  end

  local file_path = vim.fn.expand(params.filePath)

  if vim.fn.filereadable(file_path) == 0 then
    -- Using a generic error code for tool-specific operational errors
    error({ code = -32000, message = "File operation error", data = "File not found: " .. file_path })
  end

  -- Set default values for optional parameters
  local preview = params.preview or false
  local make_frontmost = params.makeFrontmost ~= false -- default true
  local select_to_end_of_line = params.selectToEndOfLine or false
  local split = params.split or "horizontal" -- default to horizontal split

  -- Find the best window to use (smart reuse of existing windows)
  local target_win, should_split = find_best_window_for_file(file_path, split)

  -- Build message based on what we're doing
  local message
  if not should_split and split ~= "none" then
    message = "Opened file: " .. file_path .. " (reused existing window)"
  elseif split == "vertical" then
    message = "Opened file: " .. file_path .. " in vertical split"
  elseif split == "horizontal" then
    message = "Opened file: " .. file_path .. " in horizontal split"
  else
    message = "Opened file: " .. file_path
  end

  ---Opens a file, optionally creating a split first
  ---@param do_split boolean whether to create a split
  ---@param split_type string "vertical" or "horizontal" (only used if do_split is true)
  ---@param is_preview boolean whether to open in preview mode
  ---@param path string the file path to open
  local function open_file_smart(do_split, split_type, is_preview, path)
    local escaped_path = vim.fn.fnameescape(path)
    if is_preview then
      vim.cmd("pedit " .. escaped_path)
    elseif do_split and split_type == "vertical" then
      vim.cmd("vsplit " .. escaped_path)
    elseif do_split and split_type == "horizontal" then
      vim.cmd("split " .. escaped_path)
    else
      vim.cmd("edit " .. escaped_path)
    end
  end

  if target_win then
    -- Open file in the target window
    vim.api.nvim_win_call(target_win, function()
      open_file_smart(should_split, split, preview, file_path)
    end)
    -- Focus the window after opening if makeFrontmost is true
    if make_frontmost then
      if should_split and not preview then
        -- The split command moved focus to the new window
        vim.api.nvim_set_current_win(vim.api.nvim_get_current_win())
      else
        vim.api.nvim_set_current_win(target_win)
      end
    end
  else
    -- Fallback: No suitable window found, try to create one
    vim.cmd("wincmd t") -- Go to top-left
    vim.cmd("wincmd l") -- Move right

    -- If we're still in a special window, create a new split
    local buf = vim.api.nvim_win_get_buf(vim.api.nvim_get_current_win())
    local buftype = vim.api.nvim_buf_get_option(buf, "buftype")

    if buftype == "terminal" or buftype == "nofile" then
      vim.cmd("vsplit")
    end

    open_file_smart(should_split, split, preview, file_path)
  end

  -- Handle text selection by line numbers
  if params.startLine or params.endLine then
    local start_line = params.startLine or 1
    local end_line = params.endLine or start_line

    -- Convert to 0-based indexing for vim API
    local start_pos = { start_line - 1, 0 }
    local end_pos = { end_line - 1, -1 } -- -1 means end of line

    vim.api.nvim_buf_set_mark(0, "<", start_pos[1], start_pos[2], {})
    vim.api.nvim_buf_set_mark(0, ">", end_pos[1], end_pos[2], {})
    vim.cmd("normal! gv")

    message = "Opened file and selected lines " .. start_line .. " to " .. end_line
  end

  -- Handle text pattern selection
  if params.startText then
    local buf = vim.api.nvim_get_current_buf()
    local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    local start_line_idx, start_col_idx
    local end_line_idx, end_col_idx

    -- Find start text
    for line_idx, line in ipairs(lines) do
      local col_idx = string.find(line, params.startText, 1, true) -- plain text search
      if col_idx then
        start_line_idx = line_idx - 1 -- Convert to 0-based
        start_col_idx = col_idx - 1 -- Convert to 0-based
        break
      end
    end

    if start_line_idx then
      -- Find end text if provided
      if params.endText then
        for line_idx = start_line_idx + 1, #lines do
          local line = lines[line_idx] -- Access current line directly
          if line then
            local col_idx = string.find(line, params.endText, 1, true)
            if col_idx then
              end_line_idx = line_idx
              end_col_idx = col_idx + string.len(params.endText) - 1
              if select_to_end_of_line then
                end_col_idx = string.len(line)
              end
              break
            end
          end
        end

        if end_line_idx then
          message = 'Opened file and selected text from "' .. params.startText .. '" to "' .. params.endText .. '"'
        else
          -- End text not found, select only start text
          end_line_idx = start_line_idx
          end_col_idx = start_col_idx + string.len(params.startText) - 1
          message = 'Opened file and positioned at "'
            .. params.startText
            .. '" (end text "'
            .. params.endText
            .. '" not found)'
        end
      else
        -- Only start text provided
        end_line_idx = start_line_idx
        end_col_idx = start_col_idx + string.len(params.startText) - 1
        message = 'Opened file and selected text "' .. params.startText .. '"'
      end

      -- Apply the selection
      vim.api.nvim_win_set_cursor(0, { start_line_idx + 1, start_col_idx })
      vim.api.nvim_buf_set_mark(0, "<", start_line_idx, start_col_idx, {})
      vim.api.nvim_buf_set_mark(0, ">", end_line_idx, end_col_idx, {})
      vim.cmd("normal! gv")
      vim.cmd("normal! zz") -- Center the selection in the window
    else
      message = 'Opened file, but text "' .. params.startText .. '" not found'
    end
  end

  -- Return format based on makeFrontmost parameter
  if make_frontmost then
    -- Simple message format when makeFrontmost=true
    return {
      content = {
        {
          type = "text",
          text = message,
        },
      },
    }
  else
    -- Detailed JSON format when makeFrontmost=false
    local buf = vim.api.nvim_get_current_buf()
    local detailed_info = {
      success = true,
      filePath = file_path,
      languageId = vim.api.nvim_buf_get_option(buf, "filetype"),
      lineCount = vim.api.nvim_buf_line_count(buf),
    }

    return {
      content = {
        {
          type = "text",
          text = vim.json.encode(detailed_info, { indent = 2 }),
        },
      },
    }
  end
end

return {
  name = "openFile",
  schema = schema,
  handler = handler,
}
