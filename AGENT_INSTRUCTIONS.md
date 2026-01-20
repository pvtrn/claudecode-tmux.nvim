# Agent Instructions for Neovim Control

This document describes how to control Neovim through the MCP (Model Context Protocol) tools.

## Available Tools

### 1. `openFile` - Open files with split support

Opens a file in Neovim with optional line selection and split control.

**Parameters:**
- `filePath` (required): Path to the file
- `startLine`: Line number to jump to
- `endLine`: End line for selection range
- `startText`: Text pattern to find and select
- `endText`: End text pattern for selection
- `split`: How to open the file
  - `"vertical"` (default) - Open in vertical split (side by side)
  - `"horizontal"` - Open in horizontal split (stacked)
  - `"none"` - Open in current window
- `preview`: Open in preview mode (boolean)
- `makeFrontmost`: Focus the window after opening (default: true)

**Examples:**
```json
// Open file in vertical split (default)
{"filePath": "/path/to/file.lua"}

// Open file and jump to line 42
{"filePath": "/path/to/file.lua", "startLine": 42}

// Open in horizontal split
{"filePath": "/path/to/file.lua", "split": "horizontal"}

// Open in same window without split
{"filePath": "/path/to/file.lua", "split": "none"}

// Open two files side by side
// First call:
{"filePath": "/path/to/left.lua", "split": "none"}
// Second call:
{"filePath": "/path/to/right.lua", "split": "vertical"}
```

### 2. `executeCommand` - Execute Neovim commands

Execute arbitrary Neovim Ex commands or Lua code.

**Parameters:**
- `command`: Neovim Ex command (e.g., `vsplit`, `tabnew`, `set number`)
- `lua`: Lua code to execute

**Examples:**
```json
// Create a new tab
{"command": "tabnew"}

// Create vertical split
{"command": "vsplit"}

// Create horizontal split
{"command": "split"}

// Go to specific line
{"command": "42"}

// Search for pattern
{"command": "/function"}

// Run Lua code
{"lua": "vim.api.nvim_buf_line_count(0)"}

// Set editor option
{"lua": "vim.opt.number = true"}

// Get current file path
{"lua": "return vim.fn.expand('%:p')"}

// Navigate between windows
{"command": "wincmd h"}  // Move to left window
{"command": "wincmd l"}  // Move to right window
{"command": "wincmd j"}  // Move to window below
{"command": "wincmd k"}  // Move to window above
```

### 3. `getCurrentSelection` - Get selected text

Returns the currently selected text in the active editor.

```json
{}
```

### 4. `getLatestSelection` - Get most recent selection

Returns the most recent text selection, even from inactive editors.

```json
{}
```

### 5. `getOpenEditors` - List open files

Returns a list of currently open files/tabs.

```json
{}
```

### 6. `getDiagnostics` - Get LSP diagnostics

Get language diagnostics (errors, warnings) from the editor.

**Parameters:**
- `uri` (optional): File URI to get diagnostics for

```json
// Get all diagnostics
{}

// Get diagnostics for specific file
{"uri": "file:///path/to/file.lua"}
```

### 7. `saveDocument` - Save a file

Save a document with unsaved changes.

**Parameters:**
- `filePath` (required): Path to the file to save

```json
{"filePath": "/path/to/file.lua"}
```

### 8. `checkDocumentDirty` - Check for unsaved changes

Check if a document has unsaved changes.

**Parameters:**
- `filePath` (required): Path to the file to check

```json
{"filePath": "/path/to/file.lua"}
```

### 9. `openDiff` - Open diff view

Opens a native Neovim diff view comparing two files or contents.

**Parameters:**
- `oldFilePath`: Path to original file
- `newFilePath`: Path to new file
- `oldContent`: Original content (string)
- `newContent`: New content (string)
- `tabLabel`: Label for the diff tab

### 10. `closeAllDiffTabs` - Close all diff views

Closes all diff-related tabs and windows.

```json
{}
```

### 11. `getWorkspaceFolders` - Get workspace folders

Returns information about workspace folders.

```json
{}
```

## Common Workflows

### Open multiple files for comparison

```json
// Step 1: Open first file in current window
{"tool": "openFile", "params": {"filePath": "/path/to/file1.lua", "split": "none"}}

// Step 2: Open second file in vertical split
{"tool": "openFile", "params": {"filePath": "/path/to/file2.lua", "split": "vertical"}}
```

### Navigate to specific code location

```json
// Open file at specific line
{"tool": "openFile", "params": {"filePath": "/path/to/file.lua", "startLine": 100}}

// Or find specific text
{"tool": "openFile", "params": {"filePath": "/path/to/file.lua", "startText": "function myFunction"}}
```

### Create a layout with multiple files

```json
// Create layout: [file1 | file2]
//                [  file3   ]

// Step 1: Open file1
{"tool": "openFile", "params": {"filePath": "/file1.lua", "split": "none"}}

// Step 2: Open file2 in vertical split
{"tool": "openFile", "params": {"filePath": "/file2.lua", "split": "vertical"}}

// Step 3: Go back to file1 window and open file3 below
{"tool": "executeCommand", "params": {"command": "wincmd h"}}
{"tool": "openFile", "params": {"filePath": "/file3.lua", "split": "horizontal"}}
```

### Check and save files

```json
// Check if file has unsaved changes
{"tool": "checkDocumentDirty", "params": {"filePath": "/path/to/file.lua"}}

// Save the file
{"tool": "saveDocument", "params": {"filePath": "/path/to/file.lua"}}
```

### Get editor context

```json
// Get current selection
{"tool": "getCurrentSelection", "params": {}}

// Get list of open files
{"tool": "getOpenEditors", "params": {}}

// Get LSP diagnostics
{"tool": "getDiagnostics", "params": {}}
```

## Window Navigation Commands

Use `executeCommand` with these common window commands:

| Command | Description |
|---------|-------------|
| `wincmd h` | Move to left window |
| `wincmd l` | Move to right window |
| `wincmd j` | Move to window below |
| `wincmd k` | Move to window above |
| `wincmd w` | Cycle through windows |
| `wincmd o` | Close all other windows |
| `wincmd =` | Make all windows equal size |
| `wincmd _` | Maximize current window height |
| `wincmd \|` | Maximize current window width |
| `close` | Close current window |
| `only` | Close all other windows |

## Tab Commands

| Command | Description |
|---------|-------------|
| `tabnew` | Create new tab |
| `tabnext` | Go to next tab |
| `tabprev` | Go to previous tab |
| `tabclose` | Close current tab |
| `tabonly` | Close all other tabs |

## Tips

1. **Default split is vertical** - Files open in vertical splits by default for side-by-side comparison
2. **Use `split: "none"`** - When you want to replace the current buffer instead of creating a split
3. **Combine tools** - Use `executeCommand` for navigation, then `openFile` for opening files
4. **Check before save** - Use `checkDocumentDirty` before `saveDocument` to avoid unnecessary writes
