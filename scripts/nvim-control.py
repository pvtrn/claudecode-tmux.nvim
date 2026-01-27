#!/usr/bin/env python3
"""
CLI tool for controlling Neovim via claudecode.nvim WebSocket.

Usage:
    nvim-control.py open <file> [--line N] [--split vertical|horizontal|none]
    nvim-control.py exec <command>
    nvim-control.py lua <code>
    nvim-control.py list-tools
    nvim-control.py mcp-server   # Run as STDIO MCP server (for Codex integration)

Examples:
    nvim-control.py open /path/to/file.lua --line 42
    nvim-control.py open /path/to/file.lua --split horizontal
    nvim-control.py exec "vsplit"
    nvim-control.py exec "wincmd h"
    nvim-control.py lua "return vim.fn.expand('%:p')"

    # For OpenAI Codex integration, add to ~/.codex/config.toml:
    # [mcp_servers.neovim]
    # command = "nvim-control"
    # args = ["mcp-server"]
"""

import asyncio
import json
import os
import sys
import glob
import argparse

try:
    import websockets
except ImportError:
    print("Error: websockets module not installed. Run: pip3 install websockets --break-system-packages")
    sys.exit(1)


def get_lock_file():
    """Find the correct lock file for the Neovim instance that launched this agent.

    Priority:
    1. CLAUDE_CODE_SSE_PORT env var (set by the Neovim that launched Claude CLI)
    2. NVIM_CONTROL_PORT env var (manual override)
    3. Most recent lock file (fallback)
    """
    lock_dir = os.path.expanduser("~/.claude/ide")

    # Check for port from environment (set by the launching Neovim)
    env_port = os.environ.get('CLAUDE_CODE_SSE_PORT') or os.environ.get('NVIM_CONTROL_PORT')

    if env_port:
        lock_path = os.path.join(lock_dir, f"{env_port}.lock")
        if os.path.exists(lock_path):
            with open(lock_path, 'r') as f:
                data = json.load(f)
            return env_port, data.get('authToken')

    # Fallback: find most recent lock file
    lock_files = glob.glob(os.path.join(lock_dir, "*.lock"))

    if not lock_files:
        return None, None

    # Get most recent lock file
    latest = max(lock_files, key=os.path.getmtime)

    with open(latest, 'r') as f:
        data = json.load(f)

    port = os.path.basename(latest).replace('.lock', '')
    auth_token = data.get('authToken')

    return port, auth_token


async def call_tool(port, auth_token, tool_name, arguments):
    """Call an MCP tool via WebSocket"""
    uri = f"ws://127.0.0.1:{port}"
    headers = {"x-claude-code-ide-authorization": auth_token}

    async with websockets.connect(uri, additional_headers=headers) as ws:
        # Initialize
        init_msg = {
            "jsonrpc": "2.0",
            "id": 1,
            "method": "initialize",
            "params": {
                "protocolVersion": "2024-11-05",
                "capabilities": {},
                "clientInfo": {"name": "nvim-control", "version": "1.0"}
            }
        }
        await ws.send(json.dumps(init_msg))
        await ws.recv()

        # Call tool
        call_msg = {
            "jsonrpc": "2.0",
            "id": 2,
            "method": "tools/call",
            "params": {
                "name": tool_name,
                "arguments": arguments
            }
        }
        await ws.send(json.dumps(call_msg))
        response = await ws.recv()
        return json.loads(response)


async def list_tools(port, auth_token):
    """List available MCP tools"""
    uri = f"ws://127.0.0.1:{port}"
    headers = {"x-claude-code-ide-authorization": auth_token}

    async with websockets.connect(uri, additional_headers=headers) as ws:
        # Initialize
        init_msg = {
            "jsonrpc": "2.0",
            "id": 1,
            "method": "initialize",
            "params": {
                "protocolVersion": "2024-11-05",
                "capabilities": {},
                "clientInfo": {"name": "nvim-control", "version": "1.0"}
            }
        }
        await ws.send(json.dumps(init_msg))
        await ws.recv()

        # Get tools list
        tools_msg = {
            "jsonrpc": "2.0",
            "id": 2,
            "method": "tools/list",
            "params": {}
        }
        await ws.send(json.dumps(tools_msg))
        response = await ws.recv()
        return json.loads(response)


async def run_mcp_stdio_server():
    """Run as STDIO MCP server - proxies requests to the WebSocket server"""
    port, auth_token = get_lock_file()
    if not port or not auth_token:
        # Send error response
        error_response = {
            "jsonrpc": "2.0",
            "id": None,
            "error": {
                "code": -32603,
                "message": "No Neovim instance found. Make sure claudecode.nvim is running (:ClaudeCodeStart)"
            }
        }
        print(json.dumps(error_response), flush=True)
        return

    uri = f"ws://127.0.0.1:{port}"
    headers = {"x-claude-code-ide-authorization": auth_token}

    try:
        async with websockets.connect(uri, additional_headers=headers) as ws:
            # Read from stdin and write to stdout
            async def stdin_to_ws():
                loop = asyncio.get_event_loop()
                while True:
                    try:
                        line = await loop.run_in_executor(None, sys.stdin.readline)
                        if not line:
                            break
                        line = line.strip()
                        if line:
                            await ws.send(line)
                    except Exception as e:
                        break

            async def ws_to_stdout():
                try:
                    async for message in ws:
                        print(message, flush=True)
                except websockets.exceptions.ConnectionClosed:
                    pass

            # Run both tasks concurrently
            await asyncio.gather(stdin_to_ws(), ws_to_stdout())
    except Exception as e:
        error_response = {
            "jsonrpc": "2.0",
            "id": None,
            "error": {
                "code": -32603,
                "message": f"Failed to connect to Neovim: {str(e)}"
            }
        }
        print(json.dumps(error_response), flush=True)


def main():
    parser = argparse.ArgumentParser(description='Control Neovim via claudecode.nvim WebSocket')
    subparsers = parser.add_subparsers(dest='command', help='Commands')

    # open command
    open_parser = subparsers.add_parser('open', help='Open a file')
    open_parser.add_argument('file', help='Path to file')
    open_parser.add_argument('--line', '-l', type=int, help='Line number to jump to')
    open_parser.add_argument('--end-line', type=int, help='End line for selection')
    open_parser.add_argument('--split', '-s', choices=['vertical', 'horizontal', 'none', 'auto'],
                            default='auto', help='Split type (default: auto - smart placement)')
    open_parser.add_argument('--window', '-w', type=int, help='Window number (1-based) to open file in')

    # exec command
    exec_parser = subparsers.add_parser('exec', help='Execute Neovim Ex command')
    exec_parser.add_argument('cmd', help='Command to execute')

    # lua command
    lua_parser = subparsers.add_parser('lua', help='Execute Lua code')
    lua_parser.add_argument('code', help='Lua code to execute')

    # list-tools command
    subparsers.add_parser('list-tools', help='List available tools')

    # raw command for any tool
    raw_parser = subparsers.add_parser('raw', help='Call any MCP tool directly')
    raw_parser.add_argument('tool', help='Tool name')
    raw_parser.add_argument('--args', '-a', help='JSON arguments', default='{}')

    # windows command - list windows
    subparsers.add_parser('windows', help='List editor windows')

    # focus command - focus specific window
    focus_parser = subparsers.add_parser('focus', help='Focus window by number')
    focus_parser.add_argument('window_num', type=int, help='Window number (1-based)')

    # close-window command
    close_win_parser = subparsers.add_parser('close-window', help='Close window by number')
    close_win_parser.add_argument('window_num', type=int, help='Window number (1-based)')

    # mcp-server command - STDIO MCP server for Codex integration
    subparsers.add_parser('mcp-server', help='Run as STDIO MCP server (for Codex integration)')

    args = parser.parse_args()

    if not args.command:
        parser.print_help()
        sys.exit(1)

    # Handle mcp-server command separately (handles its own connection)
    if args.command == 'mcp-server':
        asyncio.run(run_mcp_stdio_server())
        return

    # Get connection info for other commands
    port, auth_token = get_lock_file()
    if not port or not auth_token:
        print("Error: No Neovim instance found. Make sure claudecode.nvim is running (:ClaudeCodeStart)")
        sys.exit(1)

    try:
        if args.command == 'open':
            # If window number specified, open directly in that window
            if args.window:
                file_path = os.path.abspath(args.file)
                line_cmd = ""
                if args.line:
                    line_cmd = f"vim.api.nvim_win_set_cursor(win, {{{args.line}, 0}})"

                open_lua = f'''
                local wins = vim.tbl_filter(function(w)
                    local buf = vim.api.nvim_win_get_buf(w)
                    local bt = vim.bo[buf].buftype
                    local cfg = vim.api.nvim_win_get_config(w)
                    return bt ~= "terminal" and bt ~= "nofile" and (not cfg.relative or cfg.relative == "")
                end, vim.api.nvim_list_wins())
                if wins[{args.window}] then
                    local win = wins[{args.window}]
                    vim.api.nvim_win_call(win, function()
                        vim.cmd("edit " .. vim.fn.fnameescape("{file_path}"))
                    end)
                    {line_cmd}
                    vim.api.nvim_set_current_win(win)
                    return "Opened in window {args.window}"
                else
                    return "Window {args.window} not found, only " .. #wins .. " editor windows"
                end
                '''
                result = asyncio.run(call_tool(port, auth_token, "executeCommand", {"lua": open_lua}))
            else:
                arguments = {
                    "filePath": os.path.abspath(args.file),
                    "split": args.split
                }
                if args.line:
                    arguments["startLine"] = args.line
                if args.end_line:
                    arguments["endLine"] = args.end_line

                result = asyncio.run(call_tool(port, auth_token, "openFile", arguments))

        elif args.command == 'exec':
            result = asyncio.run(call_tool(port, auth_token, "executeCommand", {"command": args.cmd}))

        elif args.command == 'lua':
            result = asyncio.run(call_tool(port, auth_token, "executeCommand", {"lua": args.code}))

        elif args.command == 'list-tools':
            result = asyncio.run(list_tools(port, auth_token))
            if "result" in result and "tools" in result["result"]:
                print("Available tools:")
                for tool in result["result"]["tools"]:
                    print(f"  - {tool['name']}: {tool.get('description', 'No description')[:60]}")
                return

        elif args.command == 'raw':
            arguments = json.loads(args.args)
            result = asyncio.run(call_tool(port, auth_token, args.tool, arguments))

        elif args.command == 'windows':
            lua_code = '''
            local wins = vim.tbl_filter(function(w)
                local buf = vim.api.nvim_win_get_buf(w)
                local bt = vim.bo[buf].buftype
                local cfg = vim.api.nvim_win_get_config(w)
                return bt ~= "terminal" and bt ~= "nofile" and (not cfg.relative or cfg.relative == "")
            end, vim.api.nvim_list_wins())
            local result = {}
            for i, w in ipairs(wins) do
                local buf = vim.api.nvim_win_get_buf(w)
                local name = vim.api.nvim_buf_get_name(buf)
                local is_current = w == vim.api.nvim_get_current_win()
                table.insert(result, {
                    num = i,
                    file = name ~= "" and name or "[empty]",
                    current = is_current
                })
            end
            return vim.json.encode(result)
            '''
            result = asyncio.run(call_tool(port, auth_token, "executeCommand", {"lua": lua_code}))
            if "result" in result:
                content = result["result"].get("content", [])
                for item in content:
                    if item.get("type") == "text":
                        try:
                            data = json.loads(item["text"])
                            raw_result = data.get("results", [{}])[0].get("result", "[]")
                            # Remove surrounding quotes if present
                            if raw_result.startswith("'") and raw_result.endswith("'"):
                                raw_result = raw_result[1:-1]
                            inner = json.loads(raw_result)
                            print("Editor windows:")
                            for w in inner:
                                marker = " <-- current" if w.get("current") else ""
                                fname = os.path.basename(w['file']) if w['file'] != '[empty]' else '[empty]'
                                print(f"  {w['num']}: {fname}{marker}")
                        except Exception as e:
                            print(f"Parse error: {e}")
                            print(item["text"])
            return

        elif args.command == 'focus':
            lua_code = f'''
            local wins = vim.tbl_filter(function(w)
                local buf = vim.api.nvim_win_get_buf(w)
                local bt = vim.bo[buf].buftype
                local cfg = vim.api.nvim_win_get_config(w)
                return bt ~= "terminal" and bt ~= "nofile" and (not cfg.relative or cfg.relative == "")
            end, vim.api.nvim_list_wins())
            if wins[{args.window_num}] then
                vim.api.nvim_set_current_win(wins[{args.window_num}])
                return "Focused window {args.window_num}"
            else
                return "Window {args.window_num} not found, only " .. #wins .. " editor windows"
            end
            '''
            result = asyncio.run(call_tool(port, auth_token, "executeCommand", {"lua": lua_code}))

        elif args.command == 'close-window':
            lua_code = f'''
            local wins = vim.tbl_filter(function(w)
                local buf = vim.api.nvim_win_get_buf(w)
                local bt = vim.bo[buf].buftype
                local cfg = vim.api.nvim_win_get_config(w)
                return bt ~= "terminal" and bt ~= "nofile" and (not cfg.relative or cfg.relative == "")
            end, vim.api.nvim_list_wins())
            if wins[{args.window_num}] then
                vim.api.nvim_win_close(wins[{args.window_num}], false)
                return "Closed window {args.window_num}"
            else
                return "Window {args.window_num} not found, only " .. #wins .. " editor windows"
            end
            '''
            result = asyncio.run(call_tool(port, auth_token, "executeCommand", {"lua": lua_code}))

        # Print result
        if "result" in result:
            content = result["result"].get("content", [])
            for item in content:
                if item.get("type") == "text":
                    print(item.get("text", ""))
        elif "error" in result:
            print(f"Error: {result['error'].get('message', 'Unknown error')}")
            sys.exit(1)

    except Exception as e:
        print(f"Error: {e}")
        sys.exit(1)


if __name__ == "__main__":
    main()
