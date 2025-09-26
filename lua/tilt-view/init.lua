local M = {}
local config = require("tilt-view.config")
local websocket = require("tilt-view.websocket")
local ui = require("tilt-view.ui")
local api = require("tilt-view.api")

---Setup the tilt-view plugin with given options
---@param opts table? Optional configuration options
M.setup = function(opts)
    config.setup(opts)
end

---Handle Tilt commands
---@param args string Command arguments string
M.command = function(args)
    local parts = vim.split(args, "%s+", { trimempty = true })
    local cmd = parts[1] or "show"

    if cmd == "show" or cmd == "" then
        ui.show_resources()
    elseif cmd == "restart" then
        local resource = parts[2]
        if resource then
            api.restart_resource(resource)
        else
            vim.notify("Usage: :Tilt restart <resource>", vim.log.levels.WARN)
        end
    elseif cmd == "enable" then
        local resource = parts[2]
        if resource then
            api.enable_resource(resource)
        else
            vim.notify("Usage: :Tilt enable <resource>", vim.log.levels.WARN)
        end
    elseif cmd == "disable" then
        local resource = parts[2]
        if resource then
            api.disable_resource(resource)
        else
            vim.notify("Usage: :Tilt disable <resource>", vim.log.levels.WARN)
        end
    elseif cmd == "logs" then
        local resource = parts[2]
        ui.show_logs(resource)
    elseif cmd == "connect" then
        websocket.connect()
    elseif cmd == "disconnect" then
        websocket.disconnect()
    elseif cmd == "config" then
        config.show_config()
    else
        vim.notify("Unknown command: " .. cmd, vim.log.levels.ERROR)
        vim.notify("Available commands: show, restart, enable, disable, logs, connect, disconnect, config",
            vim.log.levels.INFO)
    end
end

---Provide command completion suggestions
---@param ArgLead string Leading argument being typed
---@param CmdLine string Full command line string
---@param _CursorPos number Cursor position in the command line (unused but required by Neovim API)
---@return table List of completion suggestions
M.complete = function(ArgLead, CmdLine, _CursorPos)
    local parts = vim.split(CmdLine, "%s+", { trimempty = true })

    if #parts == 1 or (#parts == 2 and ArgLead ~= "") then
        local commands = { "show", "restart", "enable", "disable", "logs", "connect", "disconnect", "config" }
        return vim.tbl_filter(function(cmd)
            return vim.startswith(cmd, ArgLead)
        end, commands)
    elseif #parts >= 2 then
        local cmd = parts[2]
        if cmd == "restart" or cmd == "enable" or cmd == "disable" or cmd == "logs" then
            return websocket.get_resource_names(ArgLead)
        end
    end

    return {}
end

return M