--- Tool implementation for opening a file with smart window placement.

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
        enum = { "none", "vertical", "horizontal", "auto" },
        description = "How to split the window when opening the file. 'auto' intelligently chooses based on screen dimensions and context. Default is 'auto'.",
        default = "auto",
      },
    },
    required = { "filePath" },
    additionalProperties = false,
    ["$schema"] = "http://json-schema.org/draft-07/schema#",
  },
}

-- Minimum window dimensions for comfortable editing
local MIN_WINDOW_WIDTH = 40
local MIN_WINDOW_HEIGHT = 8

-- Special buffer types that should be skipped
local DASHBOARD_FILETYPES = {
  "alpha", "dashboard", "starter", "snacks_dashboard",
  "ministarter", "lazy", "lazyterm"
}

local SIDEBAR_FILETYPES = {
  "neo-tree", "neo-tree-popup", "NvimTree", "oil",
  "minifiles", "netrw", "aerial", "tagbar", "Outline"
}

local TEMPORARY_FILETYPES = {
  "help", "qf", "quickfix", "loclist", "man", "fugitive",
  "gitcommit", "DiffviewFiles", "DiffviewFileHistory"
}

---Check if filetype is in a list
---@param ft string Filetype to check
---@param list table List of filetypes
---@return boolean
local function is_filetype_in_list(ft, list)
  for _, v in ipairs(list) do
    if ft == v then
      return true
    end
  end
  return false
end

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
  if is_filetype_in_list(filetype, DASHBOARD_FILETYPES) then
    return true
  end

  -- Skip special buffer types
  if buftype == "terminal" or buftype == "nofile" or buftype == "prompt" or buftype == "help" then
    return false
  end

  -- Skip known sidebar filetypes
  if is_filetype_in_list(filetype, SIDEBAR_FILETYPES) then
    return false
  end

  return true
end

---Check if a window is a terminal
---@param win integer Window ID
---@return boolean
local function is_terminal_window(win)
  local buf = vim.api.nvim_win_get_buf(win)
  local buftype = vim.api.nvim_buf_get_option(buf, "buftype")
  return buftype == "terminal"
end

---Check if a buffer is empty, dashboard, or temporary
---@param buf integer Buffer ID
---@return boolean is_replaceable True if buffer can be replaced
---@return string reason Why it's replaceable
local function is_buffer_replaceable(buf)
  local filetype = vim.api.nvim_buf_get_option(buf, "filetype")

  -- Dashboard is replaceable
  if is_filetype_in_list(filetype, DASHBOARD_FILETYPES) then
    return true, "dashboard"
  end

  -- Temporary buffers are replaceable
  if is_filetype_in_list(filetype, TEMPORARY_FILETYPES) then
    return true, "temporary"
  end

  -- Empty buffer is replaceable
  local name = vim.api.nvim_buf_get_name(buf)
  if name == "" then
    local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    if #lines == 1 and lines[1] == "" then
      return true, "empty"
    end
  end

  return false, ""
end

---Get directory from file path
---@param path string File path
---@return string directory
local function get_directory(path)
  return vim.fn.fnamemodify(path, ":h")
end

---Get file extension
---@param path string File path
---@return string extension
local function get_extension(path)
  return vim.fn.fnamemodify(path, ":e")
end

---Check if path is a test file
---@param path string File path
---@return boolean
local function is_test_file(path)
  local name = vim.fn.fnamemodify(path, ":t")
  return name:match("_test%.") ~= nil
    or name:match("%.test%.") ~= nil
    or name:match("_spec%.") ~= nil
    or name:match("%.spec%.") ~= nil
    or name:match("^test_") ~= nil
    or path:match("/tests?/") ~= nil
    or path:match("/spec/") ~= nil
    or path:match("/__tests__/") ~= nil
end

---Get detailed window information for smart placement
---@param win integer Window ID
---@return table info Window information
local function get_window_info(win)
  local buf = vim.api.nvim_win_get_buf(win)
  local buf_name = vim.api.nvim_buf_get_name(buf)
  local width = vim.api.nvim_win_get_width(win)
  local height = vim.api.nvim_win_get_height(win)
  local modified = vim.api.nvim_buf_get_option(buf, "modified")
  local filetype = vim.api.nvim_buf_get_option(buf, "filetype")
  local is_replaceable, replace_reason = is_buffer_replaceable(buf)

  return {
    win = win,
    buf = buf,
    path = buf_name,
    directory = buf_name ~= "" and get_directory(buf_name) or "",
    extension = buf_name ~= "" and get_extension(buf_name) or "",
    is_test = buf_name ~= "" and is_test_file(buf_name) or false,
    width = width,
    height = height,
    modified = modified,
    filetype = filetype,
    is_replaceable = is_replaceable,
    replace_reason = replace_reason,
    is_current = win == vim.api.nvim_get_current_win(),
    is_large_enough = width >= MIN_WINDOW_WIDTH and height >= MIN_WINDOW_HEIGHT,
  }
end

---Calculate a score for how suitable a window is for opening a file
---Higher score = better candidate
---@param win_info table Window information
---@param file_path string Path of file to open
---@param file_dir string Directory of file to open
---@param file_ext string Extension of file to open
---@param file_is_test boolean Whether file to open is a test
---@return number score Suitability score
local function calculate_window_score(win_info, file_path, file_dir, file_ext, file_is_test)
  local score = 0

  -- Strong preference for replaceable windows (empty, dashboard, temporary)
  if win_info.is_replaceable then
    score = score + 1000
    if win_info.replace_reason == "empty" then
      score = score + 100
    elseif win_info.replace_reason == "dashboard" then
      score = score + 90
    elseif win_info.replace_reason == "temporary" then
      score = score + 50
    end
  end

  -- Penalty for modified buffers (don't want to replace unsaved work)
  if win_info.modified then
    score = score - 500
  end

  -- Bonus for same directory (contextual relevance)
  if win_info.directory ~= "" and win_info.directory == file_dir then
    score = score + 200
  end

  -- Bonus for same file type
  if win_info.extension ~= "" and win_info.extension == file_ext then
    score = score + 100
  end

  -- Bonus for test files near test files
  if file_is_test and win_info.is_test then
    score = score + 150
  end

  -- Bonus for non-test files near non-test files
  if not file_is_test and not win_info.is_test and win_info.path ~= "" then
    score = score + 50
  end

  -- Penalty for windows that are too small
  if not win_info.is_large_enough then
    score = score - 300
  end

  -- Small bonus for larger windows (more comfortable editing)
  score = score + math.min(win_info.width / 10, 20)
  score = score + math.min(win_info.height / 2, 10)

  -- Slight penalty for current window (prefer not to replace what user is looking at)
  -- Unless it's replaceable
  if win_info.is_current and not win_info.is_replaceable then
    score = score - 50
  end

  return score
end

---Determine the best split direction based on available space
---@return string "vertical" or "horizontal"
local function determine_smart_split_direction()
  local total_width = vim.o.columns
  local total_height = vim.o.lines

  -- Account for status line, command line, etc.
  local usable_height = total_height - 3

  -- If screen is wide (aspect ratio > 2:1), prefer vertical split
  -- If screen is tall, prefer horizontal split
  local aspect_ratio = total_width / usable_height

  if aspect_ratio >= 2.0 then
    return "vertical"
  elseif aspect_ratio <= 1.2 then
    return "horizontal"
  else
    -- For medium aspect ratios, check if we have enough width for comfortable side-by-side
    if total_width >= 160 then
      return "vertical"
    elseif usable_height >= 40 then
      return "horizontal"
    else
      return "vertical" -- Default to vertical for small screens
    end
  end
end

---Find the best window for opening a file using smart heuristics
---@param file_path string The file path to open
---@param requested_split string "none", "vertical", "horizontal", or "auto"
---@return integer? target_win Window to open file in (nil if should create new)
---@return boolean should_split Whether to create a new split
---@return string split_direction "vertical" or "horizontal" (only used if should_split)
---@return string message Description of the decision made
local function find_smart_window(file_path, requested_split)
  local windows = vim.api.nvim_list_wins()
  local editor_windows = {}
  local terminal_present = false

  -- Gather information about all windows
  for _, win in ipairs(windows) do
    if is_editor_window(win) then
      local info = get_window_info(win)
      table.insert(editor_windows, info)
    elseif is_terminal_window(win) then
      terminal_present = true
    end
  end

  -- File metadata for scoring
  local file_dir = get_directory(file_path)
  local file_ext = get_extension(file_path)
  local file_is_test = is_test_file(file_path)

  -- Priority 1: Check if file is already open
  for _, info in ipairs(editor_windows) do
    if info.path == file_path then
      return info.win, false, "none", "File already open, focusing existing window"
    end
  end

  -- Priority 2: Find best existing window using scoring
  local best_window = nil
  local best_score = -math.huge

  for _, info in ipairs(editor_windows) do
    local score = calculate_window_score(info, file_path, file_dir, file_ext, file_is_test)
    if score > best_score then
      best_score = score
      best_window = info
    end
  end

  -- Determine if we should reuse the window or create a split
  local smart_split_dir = determine_smart_split_direction()

  -- Resolve "auto" split direction
  local effective_split = requested_split
  if requested_split == "auto" then
    effective_split = smart_split_dir
  end

  -- Decision logic
  if best_window then
    -- If the best window is replaceable (empty/dashboard/temporary), use it
    if best_window.is_replaceable then
      return best_window.win, false, "none", "Reusing " .. best_window.replace_reason .. " window"
    end

    -- If split is "none", use the best window even if not replaceable
    if requested_split == "none" then
      if best_window.modified then
        return best_window.win, false, "none", "Opening in modified buffer (split=none requested)"
      else
        return best_window.win, false, "none", "Opening in existing window"
      end
    end

    -- For auto/explicit split: check if we should split or reuse
    if #editor_windows == 1 then
      -- Only one editor window, create a split
      return best_window.win, true, effective_split, "Creating " .. effective_split .. " split (single window layout)"
    end

    -- Multiple windows exist
    if best_score >= 200 then
      -- Good candidate found (same directory, same type, etc.)
      if not best_window.modified then
        return best_window.win, false, "none", "Reusing contextually relevant window"
      end
    end

    -- Check if current layout has room for another split
    local current_win = vim.api.nvim_get_current_win()
    local current_width = vim.api.nvim_win_get_width(current_win)
    local current_height = vim.api.nvim_win_get_height(current_win)

    if effective_split == "vertical" and current_width < MIN_WINDOW_WIDTH * 2 then
      -- Not enough room for vertical split, try to reuse
      if best_window and not best_window.modified then
        return best_window.win, false, "none", "Reusing window (not enough room for vertical split)"
      end
    end

    if effective_split == "horizontal" and current_height < MIN_WINDOW_HEIGHT * 2 then
      -- Not enough room for horizontal split, try to reuse
      if best_window and not best_window.modified then
        return best_window.win, false, "none", "Reusing window (not enough room for horizontal split)"
      end
    end

    -- Default: create a split from the best window
    return best_window.win, true, effective_split, "Creating " .. effective_split .. " split"
  end

  -- No suitable editor windows found
  return nil, true, effective_split, "No editor windows found, creating new split"
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
    error({ code = -32000, message = "File operation error", data = "File not found: " .. file_path })
  end

  -- Set default values for optional parameters
  local preview = params.preview or false
  local make_frontmost = params.makeFrontmost ~= false -- default true
  local select_to_end_of_line = params.selectToEndOfLine or false
  local split = params.split or "auto" -- default to auto (smart placement)

  -- Find the best window using smart heuristics
  local target_win, should_split, split_direction, decision_reason = find_smart_window(file_path, split)

  -- Build message based on what we're doing
  local message = "Opened file: " .. file_path .. " (" .. decision_reason .. ")"

  ---Opens a file, optionally creating a split first
  ---@param do_split boolean whether to create a split
  ---@param split_type string "vertical" or "horizontal"
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
      open_file_smart(should_split, split_direction, preview, file_path)
    end)
    -- Focus the window after opening if makeFrontmost is true
    if make_frontmost then
      if should_split and not preview then
        -- The split command moved focus to the new window, get it
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
      if split_direction == "vertical" then
        vim.cmd("vsplit")
      else
        vim.cmd("split")
      end
    end

    open_file_smart(should_split, split_direction, preview, file_path)
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

    message = "Opened file and selected lines " .. start_line .. " to " .. end_line .. " (" .. decision_reason .. ")"
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
          local line = lines[line_idx]
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
          end_line_idx = start_line_idx
          end_col_idx = start_col_idx + string.len(params.startText) - 1
          message = 'Opened file and positioned at "'
            .. params.startText
            .. '" (end text "'
            .. params.endText
            .. '" not found)'
        end
      else
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
    return {
      content = {
        {
          type = "text",
          text = message,
        },
      },
    }
  else
    local buf = vim.api.nvim_get_current_buf()
    local detailed_info = {
      success = true,
      filePath = file_path,
      languageId = vim.api.nvim_buf_get_option(buf, "filetype"),
      lineCount = vim.api.nvim_buf_line_count(buf),
      placement = decision_reason,
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
