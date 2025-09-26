local M = {}
local config = require("tilt-view.config")
local uv = vim.loop

---@class TcpHandle
---@field read_stop fun(self: TcpHandle): boolean
---@field close fun(self: TcpHandle, callback?: function)
---@field write fun(self: TcpHandle, data: string, callback?: function)
---@field read_start fun(self: TcpHandle, callback: function)
---@field connect fun(self: TcpHandle, host: string, port: number, callback: function)

-- Initialize random seed
math.randomseed(os.time())

---@class TiltState
---@field connected boolean
---@field resources table[]
---@field buttons table<string, table>
---@field connection TcpHandle?
---@field tcp_handle TcpHandle?
---@field callbacks function[]
---@field message_buffer string
---@field expecting_continuation boolean
M.state = {
  connected = false,
  resources = {},
  buttons = {},  -- Track UIButtons for enable/disable
  connection = nil,
  tcp_handle = nil,  -- Track the TCP handle separately
  callbacks = {},
  message_buffer = "",  -- Buffer for reassembling fragmented messages
  expecting_continuation = false,  -- Track if we're waiting for continuation frames
}

---Parse a WebSocket frame from raw data
---@param data string Raw WebSocket frame data
---@return table? Parsed frame or nil if incomplete
local function parse_websocket_frame(data)
  if not data or #data < 2 then
    return nil
  end

  local byte1 = string.byte(data, 1)
  local byte2 = string.byte(data, 2)

  local fin = bit.band(byte1, 0x80) == 0x80
  local opcode = bit.band(byte1, 0x0F)
  local masked = bit.band(byte2, 0x80) == 0x80
  local payload_len = bit.band(byte2, 0x7F)

  local offset = 2
  if payload_len == 126 then
    if #data < 4 then return nil end
    payload_len = string.byte(data, 3) * 256 + string.byte(data, 4)
    offset = 4
  elseif payload_len == 127 then
    if #data < 10 then return nil end
    -- Read 8 bytes for 64-bit length
    -- We'll only use the last 4 bytes since Lua numbers can't handle full 64-bit
    local len = 0
    for i = 5, 8 do  -- Skip first 4 bytes, use last 4
      len = len * 256 + string.byte(data, 2 + i)
    end
    payload_len = len
    offset = 10
  end

  local mask_key = nil
  if masked then
    if #data < offset + 4 then return nil end
    mask_key = string.sub(data, offset + 1, offset + 4)
    offset = offset + 4
  end

  if #data < offset + payload_len then
    return nil
  end

  local payload = string.sub(data, offset + 1, offset + payload_len)
  if masked and mask_key then
    local unmasked = {}
    for i = 1, #payload do
      local j = (i - 1) % 4 + 1
      unmasked[i] = string.char(bit.bxor(string.byte(payload, i), string.byte(mask_key, j)))
    end
    payload = table.concat(unmasked)
  end

  return {
    fin = fin,
    opcode = opcode,
    payload = payload,
    total_length = offset + payload_len,
  }
end

---Create a WebSocket frame with given payload
---@param payload string Message payload
---@param opcode number? WebSocket opcode (default 0x01 for text)
---@return string Encoded WebSocket frame
local function create_websocket_frame(payload, opcode)
  opcode = opcode or 0x01
  local frame = string.char(0x80 + opcode)  -- FIN=1, opcode

  local len = #payload
  -- Set mask bit (0x80) in the length byte
  if len < 126 then
    frame = frame .. string.char(0x80 + len)  -- Masked + length
  elseif len < 65536 then
    frame = frame .. string.char(0x80 + 126)  -- Masked + 126
    frame = frame .. string.char(math.floor(len / 256))
    frame = frame .. string.char(len % 256)
  else
    frame = frame .. string.char(0x80 + 127)  -- Masked + 127
    for i = 7, 0, -1 do
      frame = frame .. string.char(math.floor(len / (256 ^ i)) % 256)
    end
  end

  -- Generate random 4-byte masking key
  local mask_key = ""
  for i = 1, 4 do
    mask_key = mask_key .. string.char(math.random(0, 255))
  end
  frame = frame .. mask_key

  -- Mask the payload
  local masked_payload = {}
  for i = 1, #payload do
    local j = (i - 1) % 4 + 1
    masked_payload[i] = string.char(bit.bxor(string.byte(payload, i), string.byte(mask_key, j)))
  end

  return frame .. table.concat(masked_payload)
end

---Connect to Tilt WebSocket server
---@param callback function? Callback function(success: boolean)
M.connect = function(callback)
  -- If truly connected with a valid connection, use it
  if M.state.connected and M.state.connection then
    vim.notify("Already connected to Tilt", vim.log.levels.INFO)
    if callback then callback(true) end
    return
  end

  -- Clean up any stale state silently
  if M.state.tcp_handle then
    -- Stop any existing TCP handle from reading
    pcall(function()
      M.state.tcp_handle:read_stop()
    end)
    pcall(function()
      M.state.tcp_handle:close()
    end)
    M.state.tcp_handle = nil
  end

  if M.state.connection or M.state.connected then
    -- Force silent disconnect to clean up
    M.state.connected = false  -- Prevent "Disconnected" message
    M.state.connection = nil
    M.state.resources = {}
    M.state.message_buffer = ""
    M.state.expecting_continuation = false
  end

  local host = config.get("host")
  local port = config.get("port")

  -- Generate a proper WebSocket key (16 random bytes, base64 encoded)
  local random_bytes = ""
  for i = 1, 16 do
    random_bytes = random_bytes .. string.char(math.random(0, 255))
  end
  local ws_key = vim.base64.encode(random_bytes)

  ---@type TcpHandle
  local tcp = uv.new_tcp()
  M.state.tcp_handle = tcp  -- Store TCP handle for cleanup

  -- Resolve hostname to IP
  local function connect_to_host()

    uv.getaddrinfo(host, nil, { family = "inet" }, function(err, res)
      if err then
        vim.schedule(function()
          vim.notify("Failed to resolve host: " .. err, vim.log.levels.ERROR)
          if callback then callback(false) end
        end)
        return
      end

      if not res or #res == 0 then
        vim.schedule(function()
          vim.notify("No address found for host: " .. host, vim.log.levels.ERROR)
          if callback then callback(false) end
        end)
        return
      end

      local addr = res[1].addr

      tcp:connect(addr, port, function(connect_err)
        if connect_err then
          vim.schedule(function()
            vim.notify("Failed to connect to Tilt: " .. connect_err, vim.log.levels.ERROR)
            if callback then callback(false) end
          end)
          return
        end

        -- Build proper HTTP request with correct headers
        local upgrade_request = string.format(
          "GET /ws/view HTTP/1.1\r\n" ..
          "Host: %s:%s\r\n" ..
          "Upgrade: websocket\r\n" ..
          "Connection: Upgrade\r\n" ..
          "Sec-WebSocket-Key: %s\r\n" ..
          "Sec-WebSocket-Version: 13\r\n" ..
          "\r\n",
          host, port, ws_key
        )

        tcp:write(upgrade_request)

        local buffer = ""
        tcp:read_start(function(read_err, chunk)
          if read_err then
            -- Only process if this is the current connection
            if tcp == M.state.tcp_handle then
              vim.schedule(function()
                vim.notify("WebSocket read error: " .. read_err, vim.log.levels.ERROR)
                M.disconnect()
              end)
            end
            return
          end

          if chunk then
            buffer = buffer .. chunk

            if not M.state.connected then
              -- Check if we have HTTP response first
              local http_end = buffer:find("\r\n\r\n")
              if http_end then
                local headers = buffer:sub(1, http_end)
                if headers:match("HTTP/1.1 101") then
                  M.state.connected = true
                  M.state.connection = tcp
                  vim.schedule(function()
                    if callback then callback(true) end
                  end)
                  buffer = buffer:sub(http_end + 4)
                elseif headers:match("HTTP/1.1") then
                  -- Got HTTP response but not 101
                  local status = headers:match("HTTP/1.1 (%d+)")
                  -- Only process if this is the current connection
                  if tcp == M.state.tcp_handle then
                    vim.schedule(function()
                      vim.notify("Got HTTP status: " .. (status or "unknown"), vim.log.levels.ERROR)
                      M.disconnect()
                      if callback then callback(false) end
                    end)
                  end
                  return
                end
              end
            end

            if M.state.connected and #buffer > 0 then
              while #buffer > 0 do
                local frame = parse_websocket_frame(buffer)
                if not frame then
                  break
                end

                if frame.opcode == 0x01 or frame.opcode == 0x02 then
                  if frame.fin then
                    vim.schedule(function()
                      M.handle_message(frame.payload)
                    end)
                  else
                    M.state.message_buffer = frame.payload
                    M.state.expecting_continuation = true
                  end
                elseif frame.opcode == 0x00 then
                  if M.state.expecting_continuation then
                    M.state.message_buffer = M.state.message_buffer .. frame.payload

                    if frame.fin then
                      local complete_message = M.state.message_buffer
                      M.state.message_buffer = ""
                      M.state.expecting_continuation = false

                      vim.schedule(function()
                        M.handle_message(complete_message)
                      end)
                    end
                  else
                    vim.schedule(function()
                      vim.notify("Unexpected continuation frame", vim.log.levels.WARN)
                    end)
                  end
                elseif frame.opcode == 0x09 then
                  pcall(function()
                    local pong = create_websocket_frame(frame.payload, 0x0A)
                    tcp:write(pong)
                  end)
                elseif frame.opcode == 0x0A then
                elseif frame.opcode == 0x08 then
                  if tcp == M.state.tcp_handle then
                    vim.schedule(function()
                      M.disconnect()
                    end)
                  end
                  return
                else
                end

                buffer = string.sub(buffer, frame.total_length + 1)
              end
            end
          end
        end)
      end)
    end)
  end

  connect_to_host()
end

---Disconnect from WebSocket server
M.disconnect = function()

  if M.state.connection then
    if M.state.connected then
      -- Try to send close frame, but don't fail if it doesn't work
      pcall(function()
        local close_frame = create_websocket_frame("", 0x08)
        M.state.connection:write(close_frame)
      end)
    end
    -- Stop reading before closing
    pcall(function()
      M.state.connection:read_stop()
    end)
    -- Close the connection
    pcall(function()
      M.state.connection:close()
    end)
    M.state.connection = nil
  end
  M.state.connected = false
  M.state.tcp_handle = nil  -- Clear TCP handle
  M.state.resources = {}
  M.state.message_buffer = ""
  M.state.expecting_continuation = false
  -- Don't show disconnect messages - removed per user request
end

---Subscribe to resource updates from Tilt
M.subscribe_to_resources = function()
  -- Subscribe to get all updates
  local subscribe_msg = vim.json.encode({
    type = "subscribe",
    manifest_names = nil,
  })
  M.send_message(subscribe_msg)
end

---Send a message through the WebSocket connection
---@param msg string Message to send (JSON string)
---@return boolean Success status
M.send_message = function(msg)
  if not M.state.connected or not M.state.connection then
    vim.notify("Not connected to Tilt", vim.log.levels.WARN)
    return false
  end

  local frame = create_websocket_frame(msg)
  M.state.connection:write(frame)
  return true
end

---Handle incoming WebSocket message
---@param msg string Raw message string
M.handle_message = function(msg)
  -- Trim any null bytes or whitespace
  msg = msg:gsub("%z", ""):match("^%s*(.-)%s*$")

  if msg == "" then
    return
  end

  local ok, data = pcall(vim.json.decode, msg)
  if not ok then
    -- Failed to parse, likely partial message
    return
  end

  -- Tilt sends different message formats
  -- Check for initial complete view (has isComplete flag)
  if data.isComplete then
    if data.view then
      M.update_resources(data.view, true)  -- Full update
      if data.view.uiButtons then
        M.update_buttons(data.view.uiButtons)
      end
    end
    -- Also check for direct properties
    if data.uiResources then
      M.update_resources({ uiResources = data.uiResources }, true)  -- Full update
    end
    if data.uiButtons then
      M.update_buttons(data.uiButtons)
    end
  elseif data.view then
    -- View update (partial)
    M.update_resources(data.view, false)  -- Partial update
    if data.view.uiButtons then
      M.update_buttons(data.view.uiButtons)
    end
  elseif data.uiResources then
    -- Direct resources update (partial)
    M.update_resources(data, false)  -- Partial update
    -- Check for buttons in the same message
    if data.uiButtons then
      M.update_buttons(data.uiButtons)
    end
  elseif data.uiButtons then
    -- Standalone buttons update
    M.update_buttons(data.uiButtons)
  elseif data.type == "view" and data.view then
    M.update_resources(data.view, false)  -- Partial update
  elseif data.type == "error" then
    vim.notify("Tilt error: " .. (data.error or "Unknown error"), vim.log.levels.ERROR)
  elseif data.logList then
    -- Log update, ignore for now
  else
    -- Unknown message format, ignore
  end
end

---Update the resources state from Tilt view data
---@param view table View data from Tilt
---@param is_full_update boolean Whether this is a full update (clear existing)
M.update_resources = function(view, is_full_update)
  -- Only clear resources if it's a full update (initial load)
  if is_full_update then
    M.state.resources = {}
  end

  if view.uiResources then
    -- Create a map of existing resources for partial updates
    local resource_map = {}
    for _, res in ipairs(M.state.resources) do
      resource_map[res.name] = res
    end

    -- Update or add resources
    for _, resource in ipairs(view.uiResources) do
      local status = "unknown"
      local resource_type = "unknown"
      local labels = {}

      -- Extract metadata
      if resource.metadata then
        resource_type = resource.metadata.type or "unknown"
        labels = resource.metadata.labels or {}
      end

      -- Determine resource type from various fields
      if resource.status then
        -- Check for k8s resource
        if resource.status.k8sResourceInfo then
          resource_type = "k8s"
          local podStatus = resource.status.k8sResourceInfo.podStatus
          if podStatus == "Running" then
            status = "ok"
          elseif podStatus == "Error" or podStatus == "CrashLoopBackOff" then
            status = "error"
          else
            status = "pending"
          end
        end

        -- Check for local resource
        if resource.status.localResourceInfo then
          resource_type = "local_resource"
        end

        -- Check for docker compose resource
        if resource.status.dcResourceInfo then
          resource_type = "docker_compose"
        end

        -- Check for server/service
        if resource.status.serveStatus then
          resource_type = "server"
        end

        -- Check runtime status (primary status indicator)
        if resource.status.runtimeStatus then
          if resource.status.runtimeStatus == "ok" then
            status = "ok"
          elseif resource.status.runtimeStatus == "error" then
            status = "error"
          elseif resource.status.runtimeStatus == "pending" then
            status = "pending"
          elseif resource.status.runtimeStatus == "not_applicable" then
            status = "disabled"
          end
        end

        -- Check disable status (overrides other statuses)
        if resource.status.disableStatus then
          local disable_state = resource.status.disableStatus.state
          if disable_state == "Disabled" or disable_state == "disabled" then
            status = "disabled"
          end
        end

        -- Check build status if no runtime status
        if status == "unknown" and resource.status.buildHistory and #resource.status.buildHistory > 0 then
          local lastBuild = resource.status.buildHistory[1]
          if lastBuild.error then
            status = "error"
          elseif lastBuild.finishTime then
            status = "ok"
          else
            status = "building"
          end
        end

        -- Infer type from name patterns if not already determined
        if resource_type == "unknown" and resource.metadata and resource.metadata.name then
          local name = resource.metadata.name
          if name:match("-test") or name:match("^test%-") then
            resource_type = "test"
          elseif name:match("-lib$") or name:match("^lib%-") or name:match("%-component") then
            resource_type = "lib"
          elseif name:match("-server") or name:match("-api") or name:match("-service") then
            resource_type = "server"
          end
        end
      end

      -- Extract endpoints
      local endpoints = {}
      if resource.status and resource.status.endpointLinks then
        for _, link in ipairs(resource.status.endpointLinks) do
          if type(link) == "table" and link.url then
            table.insert(endpoints, link.url)
          elseif type(link) == "string" then
            table.insert(endpoints, link)
          end
        end
      end

      -- Check if resource has runtime component
      local has_runtime = false
      if resource.status then
        -- Has runtime if it has k8s pods, docker containers, serve status, or is running
        has_runtime = (resource.status.k8sResourceInfo ~= nil) or
                     (resource.status.dcResourceInfo ~= nil) or
                     (resource.status.serveStatus ~= nil) or
                     (resource.status.runtimeStatus == "ok") or
                     (resource.status.localResourceInfo and resource.status.localResourceInfo.pid) or
                     (#endpoints > 0)
      end

      local resource_name = resource.metadata and resource.metadata.name or "unknown"
      local resource_data = {
        name = resource_name,
        status = status,
        type = resource_type,
        labels = labels,
        endpoints = endpoints,
        has_runtime = has_runtime,
      }

      -- Update existing or add new
      if is_full_update then
        table.insert(M.state.resources, resource_data)
      else
        -- For partial updates, update existing resource or add if new
        resource_map[resource_name] = resource_data
      end
    end

    -- For partial updates, rebuild the resource list from the map
    if not is_full_update then
      M.state.resources = {}
      for _, res in pairs(resource_map) do
        table.insert(M.state.resources, res)
      end
    end
  end

  -- Sort resources alphabetically for consistent ordering
  table.sort(M.state.resources, function(a, b)
    return a.name < b.name
  end)

  for _, cb in ipairs(M.state.callbacks) do
    cb(M.state.resources)
  end
end

---Get current resources list
---@return table List of resources
M.get_resources = function()
  return M.state.resources
end

---Get list of resource names with optional prefix filter
---@param prefix string? Optional prefix to filter names
---@return table List of resource names
M.get_resource_names = function(prefix)
  local names = {}
  for _, resource in ipairs(M.state.resources) do
    if not prefix or vim.startswith(resource.name, prefix) then
      table.insert(names, resource.name)
    end
  end
  return names
end

---Register a callback for resource updates
---@param callback function Callback function(resources: table)
M.on_resources_update = function(callback)
  table.insert(M.state.callbacks, callback)
end

---Update the buttons state from UI buttons data
---@param buttons table List of UI button objects
M.update_buttons = function(buttons)
  -- Store buttons by name for easy access
  for _, button in ipairs(buttons) do
    if button.metadata and button.metadata.name then
      M.state.buttons[button.metadata.name] = button
    end
  end
end

---Get a specific button by name
---@param button_name string Name of the button
---@return table? Button object or nil
M.get_button = function(button_name)
  return M.state.buttons[button_name]
end

return M
