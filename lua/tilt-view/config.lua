local M = {}

M.defaults = {
  host = "localhost",
  port = 10350,
  auto_connect = true,
  show_icons = true,
  log_level = vim.log.levels.INFO,
  float_opts = {
    border = "rounded",
    width = 0.8,
    height = 0.8,
    relative = "editor",
    anchor = "NW",
  },
}

M.options = {}

---Setup configuration with user options
---@param opts table? User configuration options
M.setup = function(opts)
  M.options = vim.tbl_deep_extend("force", M.defaults, opts or {})
end

---Get configuration value or entire config
---@param key string? Optional key to retrieve specific value
---@return any Configuration value or entire config table
M.get = function(key)
  if key then
    return M.options[key]
  end
  return M.options
end

---Display current configuration in a floating window
M.show_config = function()
  local lines = { "Tilt Configuration:", "" }
  for key, value in pairs(M.options) do
    if type(value) == "table" then
      table.insert(lines, string.format("%s:", key))
      for k, v in pairs(value) do
        table.insert(lines, string.format("  %s: %s", k, tostring(v)))
      end
    else
      table.insert(lines, string.format("%s: %s", key, tostring(value)))
    end
  end

  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  vim.bo[buf].filetype = "tilt"

  local width = math.floor(vim.o.columns * 0.6)
  local height = math.floor(vim.o.lines * 0.6)

  vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    width = width,
    height = height,
    row = math.floor((vim.o.lines - height) / 2),
    col = math.floor((vim.o.columns - width) / 2),
    style = "minimal",
    border = "rounded",
    title = " Tilt Config ",
    title_pos = "center",
  })
end

return M