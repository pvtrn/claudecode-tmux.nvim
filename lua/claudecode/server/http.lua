---@brief HTTP server implementation for MCP Streamable HTTP transport
--- Implements the MCP Streamable HTTP protocol specification (2025-03-26)
--- Provides an alternative transport for clients that don't support WebSocket

local logger = require("claudecode.logger")
local utils = require("claudecode.server.utils")

local M = {}

-- MCP Protocol version for Streamable HTTP
local MCP_PROTOCOL_VERSION = "2025-03-26"

---@class HTTPServer
---@field server table The vim.loop TCP server handle
---@field port number The port the server is listening on
---@field auth_token string|nil The authentication token for validating connections
---@field sessions table<string, HTTPSession> Active sessions
---@field message_handler function Handler for JSON-RPC messages
---@field on_error fun(err_msg: string) Callback for errors

---@class HTTPSession
---@field id string Session ID (UUID)
---@field created_at number Timestamp when session was created
---@field last_activity number Timestamp of last activity
---@field initialized boolean Whether the session has been initialized

---Generate a UUID v4 for session ID
---@return string uuid The generated UUID
local function generate_session_id()
  -- Use the same UUID generation as auth tokens
  return utils.generate_uuid_v4()
end

---Parse HTTP request from raw data
---@param data string Raw HTTP request data
---@return table|nil request Parsed request or nil on error
---@return string|nil error Error message if parsing failed
local function parse_http_request(data)
  -- Find the end of headers
  local header_end = data:find("\r\n\r\n")
  if not header_end then
    return nil, "Incomplete HTTP request"
  end

  local header_section = data:sub(1, header_end - 1)
  local body = data:sub(header_end + 4)

  -- Parse request line
  local request_line = header_section:match("^([^\r\n]+)")
  if not request_line then
    return nil, "Missing request line"
  end

  local method, path, version = request_line:match("^(%S+)%s+(%S+)%s+(%S+)$")
  if not method or not path or not version then
    return nil, "Invalid request line"
  end

  -- Parse headers
  local headers = {}
  for line in header_section:gmatch("\r\n([^\r\n]+)") do
    local key, value = line:match("^([^:]+):%s*(.+)$")
    if key and value then
      -- Normalize header names to lowercase for easier lookup
      headers[key:lower()] = value
    end
  end

  return {
    method = method,
    path = path,
    version = version,
    headers = headers,
    body = body,
  }
end

---Build HTTP response
---@param status_code number HTTP status code
---@param status_text string HTTP status text
---@param headers table Response headers
---@param body string|nil Response body
---@return string response The formatted HTTP response
local function build_http_response(status_code, status_text, headers, body)
  local response = string.format("HTTP/1.1 %d %s\r\n", status_code, status_text)

  for key, value in pairs(headers) do
    response = response .. string.format("%s: %s\r\n", key, value)
  end

  if body then
    response = response .. string.format("Content-Length: %d\r\n", #body)
  else
    response = response .. "Content-Length: 0\r\n"
  end

  response = response .. "\r\n"

  if body then
    response = response .. body
  end

  return response
end

---Send HTTP response to client
---@param client_tcp table The TCP handle
---@param status_code number HTTP status code
---@param status_text string HTTP status text
---@param headers table Response headers
---@param body string|nil Response body
local function send_http_response(client_tcp, status_code, status_text, headers, body)
  local response = build_http_response(status_code, status_text, headers, body)
  if not client_tcp:is_closing() then
    client_tcp:write(response)
  end
end

---Send JSON response
---@param client_tcp table The TCP handle
---@param status_code number HTTP status code
---@param data table Data to encode as JSON
---@param extra_headers table|nil Additional headers
local function send_json_response(client_tcp, status_code, data, extra_headers)
  local headers = {
    ["Content-Type"] = "application/json",
    ["Access-Control-Allow-Origin"] = "*",
    ["Access-Control-Allow-Methods"] = "GET, POST, DELETE, OPTIONS",
    ["Access-Control-Allow-Headers"] = "Content-Type, Accept, MCP-Protocol-Version, MCP-Session-Id, Authorization",
  }

  if extra_headers then
    for k, v in pairs(extra_headers) do
      headers[k] = v
    end
  end

  local body = vim.json.encode(data)
  local status_text = status_code == 200 and "OK"
    or status_code == 202 and "Accepted"
    or status_code == 400 and "Bad Request"
    or status_code == 403 and "Forbidden"
    or status_code == 404 and "Not Found"
    or status_code == 405 and "Method Not Allowed"
    or "Error"

  send_http_response(client_tcp, status_code, status_text, headers, body)
end

---Validate Origin header for security
---@param headers table Request headers
---@return boolean valid Whether the origin is valid
local function validate_origin(headers)
  local origin = headers["origin"]

  -- No origin header is OK for non-browser clients
  if not origin then
    return true
  end

  -- Allow localhost origins
  if origin:match("^https?://localhost") or origin:match("^https?://127%.0%.0%.1") then
    return true
  end

  -- Reject other origins (DNS rebinding protection)
  return false
end

---Validate authentication
---@param headers table Request headers
---@param auth_token string|nil Expected auth token
---@return boolean valid Whether authentication is valid
local function validate_auth(headers, auth_token)
  -- If no auth token required, allow all
  if not auth_token then
    return true
  end

  -- Check Authorization header (Bearer token)
  local auth_header = headers["authorization"]
  if auth_header then
    local token = auth_header:match("^Bearer%s+(.+)$")
    if token and token == auth_token then
      return true
    end
  end

  -- Also check custom header for compatibility
  local custom_auth = headers["x-claude-code-ide-authorization"]
  if custom_auth and custom_auth == auth_token then
    return true
  end

  return false
end

---Handle OPTIONS request (CORS preflight)
---@param client_tcp table The TCP handle
local function handle_options(client_tcp)
  local headers = {
    ["Access-Control-Allow-Origin"] = "*",
    ["Access-Control-Allow-Methods"] = "GET, POST, DELETE, OPTIONS",
    ["Access-Control-Allow-Headers"] = "Content-Type, Accept, MCP-Protocol-Version, MCP-Session-Id, Authorization, x-claude-code-ide-authorization",
    ["Access-Control-Max-Age"] = "86400",
  }

  send_http_response(client_tcp, 204, "No Content", headers, nil)
end

---Create and start an HTTP server
---@param config ClaudeCodeConfig Server configuration
---@param message_handler function Handler for JSON-RPC messages
---@param auth_token string|nil Authentication token
---@return HTTPServer|nil server The server object, or nil on error
---@return string|nil error Error message if failed
function M.create_server(config, message_handler, auth_token)
  -- Find available port (use different range for HTTP)
  local port = nil
  local min_port = config.port_range.min
  local max_port = config.port_range.max

  -- Generate list of ports and shuffle
  local ports = {}
  for i = min_port, max_port do
    table.insert(ports, i)
  end
  utils.shuffle_array(ports)

  -- Try to bind to a port
  for _, p in ipairs(ports) do
    local test_server = vim.loop.new_tcp()
    if test_server then
      local success = test_server:bind("127.0.0.1", p)
      test_server:close()
      if success then
        port = p
        break
      end
    end
  end

  if not port then
    return nil, "No available ports for HTTP server"
  end

  local tcp_server = vim.loop.new_tcp()
  if not tcp_server then
    return nil, "Failed to create HTTP TCP server"
  end

  -- Create server object
  local server = {
    server = tcp_server,
    port = port,
    auth_token = auth_token,
    sessions = {},
    message_handler = message_handler,
    on_error = function(msg)
      logger.error("http", "HTTP server error: " .. msg)
    end,
  }

  local bind_success, bind_err = tcp_server:bind("127.0.0.1", port)
  if not bind_success then
    tcp_server:close()
    return nil, "Failed to bind HTTP server to port " .. port .. ": " .. (bind_err or "unknown error")
  end

  -- Start listening
  local listen_success, listen_err = tcp_server:listen(128, function(err)
    if err then
      server.on_error("Listen error: " .. err)
      return
    end

    M._handle_connection(server)
  end)

  if not listen_success then
    tcp_server:close()
    return nil, "Failed to listen on HTTP port " .. port .. ": " .. (listen_err or "unknown error")
  end

  logger.info("http", "HTTP server started on port " .. port)
  return server, nil
end

---Handle incoming HTTP connection
---@param server HTTPServer The server object
function M._handle_connection(server)
  local client_tcp = vim.loop.new_tcp()
  if not client_tcp then
    server.on_error("Failed to create client TCP handle")
    return
  end

  local accept_success, accept_err = server.server:accept(client_tcp)
  if not accept_success then
    server.on_error("Failed to accept HTTP connection: " .. (accept_err or "unknown error"))
    client_tcp:close()
    return
  end

  -- Buffer for accumulating request data
  local buffer = ""

  client_tcp:read_start(function(err, data)
    if err then
      server.on_error("HTTP client read error: " .. err)
      if not client_tcp:is_closing() then
        client_tcp:close()
      end
      return
    end

    if not data then
      -- EOF
      if not client_tcp:is_closing() then
        client_tcp:close()
      end
      return
    end

    buffer = buffer .. data

    -- Try to parse complete HTTP request
    local request, parse_err = parse_http_request(buffer)
    if request then
      -- Handle the request
      M._handle_request(server, client_tcp, request)

      -- Close connection after response (HTTP/1.0 style for simplicity)
      -- In production, you'd want to support keep-alive
      vim.defer_fn(function()
        if not client_tcp:is_closing() then
          client_tcp:close()
        end
      end, 100)
    elseif parse_err ~= "Incomplete HTTP request" then
      -- Parsing error
      send_json_response(client_tcp, 400, {
        jsonrpc = "2.0",
        error = {
          code = -32700,
          message = "Parse error",
          data = parse_err,
        },
      })
      if not client_tcp:is_closing() then
        client_tcp:close()
      end
    end
    -- If incomplete, wait for more data
  end)
end

---Handle HTTP request
---@param server HTTPServer The server object
---@param client_tcp table The TCP handle
---@param request table Parsed HTTP request
function M._handle_request(server, client_tcp, request)
  logger.debug("http", string.format("HTTP %s %s", request.method, request.path))

  -- Handle CORS preflight
  if request.method == "OPTIONS" then
    handle_options(client_tcp)
    return
  end

  -- Validate origin (security)
  if not validate_origin(request.headers) then
    send_json_response(client_tcp, 403, {
      jsonrpc = "2.0",
      error = {
        code = -32600,
        message = "Forbidden",
        data = "Invalid origin",
      },
    })
    return
  end

  -- Validate authentication
  if not validate_auth(request.headers, server.auth_token) then
    send_json_response(client_tcp, 403, {
      jsonrpc = "2.0",
      error = {
        code = -32600,
        message = "Unauthorized",
        data = "Invalid or missing authentication",
      },
    })
    return
  end

  -- Route based on path and method
  if request.path == "/mcp" or request.path == "/" then
    if request.method == "POST" then
      M._handle_post(server, client_tcp, request)
    elseif request.method == "GET" then
      M._handle_get(server, client_tcp, request)
    elseif request.method == "DELETE" then
      M._handle_delete(server, client_tcp, request)
    else
      send_json_response(client_tcp, 405, {
        jsonrpc = "2.0",
        error = {
          code = -32600,
          message = "Method Not Allowed",
        },
      })
    end
  else
    send_json_response(client_tcp, 404, {
      jsonrpc = "2.0",
      error = {
        code = -32600,
        message = "Not Found",
        data = "Unknown endpoint: " .. request.path,
      },
    })
  end
end

---Handle POST request (send JSON-RPC message)
---@param server HTTPServer The server object
---@param client_tcp table The TCP handle
---@param request table Parsed HTTP request
function M._handle_post(server, client_tcp, request)
  -- Parse JSON-RPC message from body
  local success, message = pcall(vim.json.decode, request.body)
  if not success or type(message) ~= "table" then
    send_json_response(client_tcp, 400, {
      jsonrpc = "2.0",
      error = {
        code = -32700,
        message = "Parse error",
        data = "Invalid JSON in request body",
      },
    })
    return
  end

  -- Validate JSON-RPC format
  if message.jsonrpc ~= "2.0" then
    send_json_response(client_tcp, 400, {
      jsonrpc = "2.0",
      error = {
        code = -32600,
        message = "Invalid Request",
        data = "Not a valid JSON-RPC 2.0 message",
      },
    })
    return
  end

  -- Get or create session
  local session_id = request.headers["mcp-session-id"]
  local session = nil
  local extra_headers = {}

  if message.method == "initialize" then
    -- Create new session for initialize request
    session_id = generate_session_id()
    session = {
      id = session_id,
      created_at = vim.loop.now(),
      last_activity = vim.loop.now(),
      initialized = false,
    }
    server.sessions[session_id] = session
    extra_headers["MCP-Session-Id"] = session_id
    logger.debug("http", "Created new session: " .. session_id)
  elseif session_id then
    session = server.sessions[session_id]
    if not session then
      -- Session not found
      send_json_response(client_tcp, 404, {
        jsonrpc = "2.0",
        id = message.id,
        error = {
          code = -32600,
          message = "Session not found",
          data = "Invalid or expired session ID",
        },
      })
      return
    end
    session.last_activity = vim.loop.now()
  end

  -- Create a virtual client for the message handler
  local virtual_client = {
    id = session_id or "http-" .. tostring(vim.loop.now()),
    transport = "http",
    session = session,
  }

  -- Process the message through the handler
  -- The handler expects (client, params) and we need to adapt
  if message.id then
    -- Request - needs response
    local result = server.message_handler(virtual_client, message)

    if result then
      if result.error then
        send_json_response(client_tcp, 200, {
          jsonrpc = "2.0",
          id = message.id,
          error = result.error,
        }, extra_headers)
      else
        send_json_response(client_tcp, 200, {
          jsonrpc = "2.0",
          id = message.id,
          result = result,
        }, extra_headers)
      end
    else
      send_json_response(client_tcp, 200, {
        jsonrpc = "2.0",
        id = message.id,
        result = {},
      }, extra_headers)
    end

    -- Mark session as initialized after successful initialize
    if message.method == "initialize" and session then
      session.initialized = true
    end
  else
    -- Notification - no response needed
    server.message_handler(virtual_client, message)
    send_http_response(client_tcp, 202, "Accepted", {
      ["Access-Control-Allow-Origin"] = "*",
    }, nil)
  end
end

---Handle GET request (SSE stream for server-to-client messages)
---@param server HTTPServer The server object
---@param client_tcp table The TCP handle
---@param request table Parsed HTTP request
function M._handle_get(server, client_tcp, request)
  -- Check Accept header
  local accept = request.headers["accept"] or ""
  if not accept:find("text/event%-stream") then
    send_json_response(client_tcp, 405, {
      jsonrpc = "2.0",
      error = {
        code = -32600,
        message = "Method Not Allowed",
        data = "GET requires Accept: text/event-stream",
      },
    })
    return
  end

  -- For now, we don't support SSE streaming (server-initiated messages)
  -- Most MCP use cases are request/response based
  send_json_response(client_tcp, 405, {
    jsonrpc = "2.0",
    error = {
      code = -32600,
      message = "Method Not Allowed",
      data = "SSE streaming not supported. Use POST for requests.",
    },
  })
end

---Handle DELETE request (terminate session)
---@param server HTTPServer The server object
---@param client_tcp table The TCP handle
---@param request table Parsed HTTP request
function M._handle_delete(server, client_tcp, request)
  local session_id = request.headers["mcp-session-id"]

  if not session_id then
    send_json_response(client_tcp, 400, {
      jsonrpc = "2.0",
      error = {
        code = -32600,
        message = "Bad Request",
        data = "Missing MCP-Session-Id header",
      },
    })
    return
  end

  local session = server.sessions[session_id]
  if not session then
    send_json_response(client_tcp, 404, {
      jsonrpc = "2.0",
      error = {
        code = -32600,
        message = "Not Found",
        data = "Session not found",
      },
    })
    return
  end

  -- Remove session
  server.sessions[session_id] = nil
  logger.debug("http", "Terminated session: " .. session_id)

  send_http_response(client_tcp, 202, "Accepted", {
    ["Access-Control-Allow-Origin"] = "*",
  }, nil)
end

---Stop the HTTP server
---@param server HTTPServer The server object
function M.stop_server(server)
  -- Clear sessions
  server.sessions = {}

  -- Close server
  if server.server and not server.server:is_closing() then
    server.server:close()
  end

  logger.info("http", "HTTP server stopped")
end

---Get server status
---@param server HTTPServer The server object
---@return table status Server status information
function M.get_status(server)
  local session_count = 0
  for _ in pairs(server.sessions) do
    session_count = session_count + 1
  end

  return {
    running = true,
    port = server.port,
    session_count = session_count,
  }
end

return M
