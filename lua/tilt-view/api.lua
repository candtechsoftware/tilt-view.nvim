local M = {}
local websocket = require("tilt-view.websocket")
local config = require("tilt-view.config")

---Helper to add microsecond offset to ISO datetime (matching VS Code)
---@return string ISO datetime string with microseconds
local function get_timestamp()
  local now = os.date("!%Y-%m-%dT%H:%M:%S")
  local microseconds = math.random(100000, 999999)
  return now .. "." .. microseconds .. "Z"
end

---Restart a Tilt resource
---@param resource_name string Name of the resource to restart
M.restart_resource = function(resource_name)
  local host = config.get("host")
  local port = config.get("port")

  -- Use curl command as fallback if plenary not available
  local url = string.format("http://%s:%s/api/trigger", host, port)
  local body = vim.json.encode({
    manifest_names = { resource_name },
    build_reason = 16,  -- Manual trigger
  })

  local cmd = string.format(
    "curl -X POST -H 'Content-Type: application/json' -d '%s' %s 2>/dev/null",
    body, url
  )

  vim.fn.jobstart(cmd, {
    on_exit = function(_, exit_code)
      if exit_code ~= 0 then
        vim.notify("Failed to restart " .. resource_name, vim.log.levels.ERROR)
      end
    end,
  })
end

---Toggle the disable status of a resource
---@param resource_name string Name of the resource
---@param enable boolean True to enable, false to disable
local function toggle_disable_status(resource_name, enable)
  local host = config.get("host")
  local port = config.get("port")
  local button_name = "toggle-" .. resource_name .. "-disable"
  local button = websocket.get_button(button_name)

  if not button then
    -- Try alternate button naming patterns
    button = websocket.get_button(resource_name .. ":disable")
    if button then
      button_name = resource_name .. ":disable"
    else
      -- Button not found, continue without button version
    end
  end

  local action = enable and "off" or "on"  -- off = enable, on = disable

  local url = string.format(
    "http://%s:%s/proxy/apis/tilt.dev/v1alpha1/uibuttons/%s/status",
    host, port, button_name
  )

  local version = (button and button.metadata and button.metadata.resourceVersion) or ""
  local body = vim.json.encode({
    metadata = {
      resourceVersion = version,
      name = button_name,
    },
    status = {
      lastClickedAt = get_timestamp(),
      inputs = {
        {
          name = "action",
          hidden = {
            value = action,
          },
        },
      },
    },
  })

  local cmd = string.format(
    "curl -X PUT -H 'Content-Type: application/json' -d '%s' %s 2>/dev/null",
    body, url
  )

  vim.fn.jobstart(cmd, {
    on_exit = function(_, exit_code)
      if exit_code ~= 0 then
        vim.notify("Failed to toggle " .. resource_name, vim.log.levels.ERROR)
      end
    end,
  })
end

---Enable a Tilt resource
---@param resource_name string Name of the resource to enable
M.enable_resource = function(resource_name)
  toggle_disable_status(resource_name, true)
end

---Disable a Tilt resource
---@param resource_name string Name of the resource to disable
M.disable_resource = function(resource_name)
  toggle_disable_status(resource_name, false)
end

---Trigger an update for a resource
---@param resource_name string Name of the resource to update
M.trigger_update = function(resource_name)
  M.restart_resource(resource_name)  -- Same as restart for now
end

return M