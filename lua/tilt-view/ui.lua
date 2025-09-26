local M = {}
local websocket = require("tilt-view.websocket")
local config = require("tilt-view.config")

-- Create a namespace for our highlights
local ns_id = vim.api.nvim_create_namespace("tilt-view")

---Get icon for resource status
---@param status string Status type
---@return string Icon character
local function get_status_icon(status)
  local icons = {
    ok = "✓",
    error = "✗",
    building = "~",
    pending = "o",
    disabled = "-",
    unknown = "?",
  }

  return icons[status] or "?"
end

---Get display text for resource status
---@param status string Status type
---@return string Status display text
local function get_status_text(status)
  local text = {
    ok = "Running",
    error = "Error",
    building = "Building",
    pending = "Pending",
    disabled = "Disabled",
    unknown = "Unknown",
  }

  return text[status] or status
end

---Get highlight group for status
---@param status string Status type
---@return string Highlight group name
local function get_status_highlight(status)
  -- Define custom highlight groups that only set foreground colors
  local highlights = {
    ok = "TiltStatusOk",
    error = "TiltStatusError",
    building = "TiltStatusBuilding",
    pending = "TiltStatusPending",
    disabled = "TiltStatusDisabled",
    unknown = "TiltStatusUnknown",
  }

  return highlights[status] or "TiltStatusUnknown"
end

---Create custom highlight groups for UI
M.create_highlight_groups = function()
  -- Use standard Neovim highlight groups that work with any theme
  vim.api.nvim_set_hl(0, "TiltHeader", { link = "Title" })
  vim.api.nvim_set_hl(0, "TiltBorder", { link = "FloatBorder" })
  vim.api.nvim_set_hl(0, "TiltResource", { link = "Normal" })
  vim.api.nvim_set_hl(0, "TiltHelp", { link = "Comment" })
  vim.api.nvim_set_hl(0, "TiltKey", { link = "Special" })
  vim.api.nvim_set_hl(0, "TiltTab", { link = "TabLine" })
  vim.api.nvim_set_hl(0, "TiltTabActive", { link = "Search" })  -- Use Search highlight for visibility
  vim.api.nvim_set_hl(0, "TiltActiveTab", { link = "Title" })

  -- Status highlights - use only foreground colors, no backgrounds
  -- Extract colors from diagnostic groups but create our own without backgrounds
  local function get_fg_color(group)
    local ok, hl = pcall(vim.api.nvim_get_hl, 0, { name = group })
    if ok and hl.fg then
      return hl.fg
    end
    return nil
  end

  vim.api.nvim_set_hl(0, "TiltStatusOk", { fg = get_fg_color("DiagnosticOk") or get_fg_color("String") })
  vim.api.nvim_set_hl(0, "TiltStatusError", { fg = get_fg_color("DiagnosticError") or get_fg_color("ErrorMsg") })
  vim.api.nvim_set_hl(0, "TiltStatusBuilding", { fg = get_fg_color("DiagnosticWarn") or get_fg_color("WarningMsg") })
  vim.api.nvim_set_hl(0, "TiltStatusPending", { fg = get_fg_color("DiagnosticInfo") or get_fg_color("Question") })
  vim.api.nvim_set_hl(0, "TiltStatusDisabled", { fg = get_fg_color("Comment") })
  vim.api.nvim_set_hl(0, "TiltStatusUnknown", { fg = get_fg_color("Comment") })  -- Use Comment color for unknown too
end

-- Track the current active tab and window
local current_tab = 1
local current_win = nil
local pending_actions = {}

---Show resources in a floating window with tabs
---@param active_tab number? Active tab index
M.show_resources = function(active_tab)
  M.create_highlight_groups()
  current_tab = active_tab or current_tab  -- Remember active tab

  -- Always ensure we have a valid connection
  if not websocket.state.connected or not websocket.state.connection then
    websocket.state.connected = false
    websocket.state.connection = nil

    if not M._update_callback_registered then
      M._update_callback_registered = true
      websocket.on_resources_update(function(resources)
        vim.schedule(function()
          if resources and #resources > 0 then
            pending_actions = {}
            if current_win and vim.api.nvim_win_is_valid(current_win) then
              local cursor_pos = vim.api.nvim_win_get_cursor(current_win)
              M.show_resources(current_tab)
              vim.defer_fn(function()
                if current_win and vim.api.nvim_win_is_valid(current_win) then
                  pcall(vim.api.nvim_win_set_cursor, current_win, cursor_pos)
                end
              end, 50)
            else
              M.show_resources(current_tab)
              vim.cmd("redraw")
            end
          end
        end)
      end)
    end

    websocket.connect(function(success)
      if success then
        -- Subscribe to resources after connecting
        websocket.subscribe_to_resources()
        -- Resources will come through the update callback, no need to show immediately
      else
        vim.notify("Failed to connect to Tilt. Is Tilt running on port 10350?", vim.log.levels.ERROR)
      end
    end)
    return
  end

  local resources = websocket.get_resources()

  if #resources == 0 then
    -- Silently wait for resources to come in
    return
  end

  -- Use remembered tab or default to first
  active_tab = active_tab or current_tab or 1

  -- Sort resources alphabetically by name for consistent ordering
  table.sort(resources, function(a, b)
    return a.name < b.name
  end)

  -- Categorize resources
  local services = {}
  local libraries = {}
  local tests = {}
  local unlabeled = {}
  local all_resources = resources

  for _, resource in ipairs(resources) do
    local categorized = false

    -- Tests: anything with 'test' or 'spec' in the name
    if resource.name and (resource.name:match("test") or resource.name:match("spec")) then
      table.insert(tests, resource)
      categorized = true
    -- Services: k8s, docker, has endpoints/runtime, or service-like names
    elseif resource.type == "k8s" or resource.type == "docker_compose" or
           (resource.endpoints and #resource.endpoints > 0) or
           resource.has_runtime or
           (resource.status == "ok" and resource.type == "local_resource" and
            (resource.name:match("portal") or resource.name:match("server") or
             resource.name:match("api") or resource.name:match("app"))) or
           (resource.status == "running") then
      table.insert(services, resource)
      categorized = true
    -- Libraries: build/compile resources with lib-like names
    elseif resource.type == "local_resource" and
           (resource.name and (resource.name:match("lib") or resource.name:match("component") or
            resource.name:match("package") or resource.name:match("build"))) then
      table.insert(libraries, resource)
      categorized = true
    end

    -- Everything else goes to unlabeled
    if not categorized then
      table.insert(unlabeled, resource)
    end
  end

  -- Define tabs in specific order
  local tabs = {}

  -- Always add "All" tab first
  table.insert(tabs, { name = "All", resources = all_resources })

  -- Add Services tab if there are services
  if #services > 0 then
    table.insert(tabs, { name = "Services", resources = services })
  end

  -- Add Libraries tab if there are libraries
  if #libraries > 0 then
    table.insert(tabs, { name = "Libraries", resources = libraries })
  end

  -- Add Tests tab if there are tests
  if #tests > 0 then
    table.insert(tabs, { name = "Tests", resources = tests })
  end

  -- Add Unlabeled tab if there are unlabeled resources
  if #unlabeled > 0 then
    table.insert(tabs, { name = "Unlabeled", resources = unlabeled })
  end

  -- Build display lines
  local lines = {}
  local highlights = {}
  local resource_map = {}

  -- Create tab bar that scrolls to keep active tab visible
  local tab_items = {}
  for i, tab in ipairs(tabs) do
    local tab_text
    if i == active_tab then
      -- Active tab: with brackets to show it's selected
      tab_text = string.format("[%d:%s(%d)]", i, tab.name, #tab.resources)
    else
      -- Inactive tabs: number and name
      tab_text = string.format("%d:%s(%d)", i, tab.name, #tab.resources)
    end
    table.insert(tab_items, tab_text)
  end

  -- Build tab line, centering around active tab if needed
  local tab_line = ""
  local max_width = 70  -- Maximum width for tab line

  -- If active tab is 4 or 5, show tabs 3-5 to keep active tab visible
  local start_tab = 1
  local end_tab = #tabs

  if active_tab >= 4 and #tabs >= 5 then
    -- Shift view to show later tabs
    start_tab = math.max(1, active_tab - 2)
    end_tab = math.min(#tabs, start_tab + 4)
  elseif #tabs > 4 then
    -- Show first 4 tabs and indicate more
    end_tab = math.min(4, #tabs)
  end

  -- Add left indicator if not showing all tabs from start
  if start_tab > 1 then
    tab_line = "< "
  end

  -- Add visible tabs
  for i = start_tab, end_tab do
    tab_line = tab_line .. " " .. tab_items[i]
  end

  -- Add right indicator if not showing all tabs to end
  if end_tab < #tabs then
    tab_line = tab_line .. " >"
  end

  table.insert(lines, "")
  table.insert(lines, tab_line)

  -- Add help text right under tabs
  local tab_keys = #tabs > 1 and ("1-" .. #tabs .. ":tab | ") or ""
  local help_text = " " .. tab_keys .. "r:restart | e:enable | d:disable | l:logs | q:quit"
  table.insert(lines, help_text)
  table.insert(lines, string.rep("─", 70))

  -- Ensure active_tab is valid
  if active_tab > #tabs then
    active_tab = 1
  end
  current_tab = active_tab  -- Update current tab

  -- Add resources for active tab
  if not tabs[active_tab] then
    vim.notify("No tabs available", vim.log.levels.WARN)
    return
  end
  local current_resources = tabs[active_tab].resources

  if #current_resources == 0 then
    table.insert(lines, "")
    table.insert(lines, "  No resources in this category")
  else
    table.insert(lines, "")
    for _, resource in ipairs(current_resources) do
      local status = resource.status
      if pending_actions[resource.name] then
        status = "pending"
      end
      local icon = get_status_icon(status)
      local status_text = get_status_text(status)
      local name = resource.name
      if #name > 35 then
        name = name:sub(1, 32) .. "..."
      end

      local line = string.format("  %s %-38s %s", icon, name, status_text)
      table.insert(lines, line)
      resource_map[#lines] = resource

      -- Highlight icon
      table.insert(highlights, {
        line = #lines - 1,
        col_start = 2,
        col_end = 3,
        hl_group = get_status_highlight(resource.status),
      })

      -- Highlight status text only (not the entire line)
      -- Find where the status text actually starts in the line
      local status_pos = line:find(status_text, 1, true)
      if status_pos then
        table.insert(highlights, {
          line = #lines - 1,
          col_start = status_pos - 1,  -- 0-indexed
          col_end = status_pos - 1 + #status_text,
          hl_group = get_status_highlight(resource.status),
        })
      end
    end
  end

  -- Add padding at the bottom
  table.insert(lines, "")
  table.insert(lines, "")

  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  vim.bo[buf].filetype = "tilt"
  vim.bo[buf].buftype = "nofile"

  for _, hl in ipairs(highlights) do
    vim.api.nvim_buf_set_extmark(buf, ns_id, hl.line, hl.col_start, {
      end_col = hl.col_end,
      hl_group = hl.hl_group,
    })
  end

  -- Highlight active tab in tab bar
  if #lines >= 2 and tabs[active_tab] then
    local tab_line_num = 1  -- Second line (0-indexed)
    local tab_text = lines[2]
    -- Find the active tab pattern [N:TabName(count)]
    local pattern = string.format("[%d:%s", active_tab, tabs[active_tab].name)
    local start_pos = string.find(tab_text, "[" .. active_tab .. ":", 1, true)
    if start_pos then
      -- Find the closing bracket after this position
      local end_pos = string.find(tab_text, "]" , start_pos, true)
      if end_pos then
        -- Highlight the entire active tab including brackets
        vim.api.nvim_buf_set_extmark(buf, ns_id, tab_line_num, start_pos - 1, {
          end_col = end_pos,
          hl_group = "TiltTabActive",
        })
      end
    end
  end

  -- Close any existing window first
  if current_win and vim.api.nvim_win_is_valid(current_win) then
    pcall(vim.api.nvim_win_close, current_win, true)
  end

  -- Calculate window size
  local width = math.min(80, math.floor(vim.o.columns * 0.8))
  -- Increased height since help bar will be fixed at bottom
  local height = math.min(30, math.floor(vim.o.lines * 0.7))

  -- Create main window
  local start_row = math.floor((vim.o.lines - height - 3) / 2)
  local start_col = math.floor((vim.o.columns - width) / 2)

  -- Create window without footer (help is in content)
  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    width = width,
    height = height,
    row = start_row,
    col = start_col,
    style = "minimal",
    border = "rounded",
    title = " Tilt Resources ",
    title_pos = "center",
  })

  -- Store current window and buffer references
  current_win = win
  current_buf = buf

  -- Set window options for proper scrolling
  vim.wo[win].wrap = false
  vim.wo[win].cursorline = true

  -- If we have many lines, ensure we can see the help bar by starting at top
  if #lines > height then
    vim.api.nvim_win_set_cursor(win, {1, 0})
  end

  -- Highlight the help bar line (now at the top)
  local help_line_num = 2  -- The help text line is at position 3 (0-indexed = 2)
  vim.api.nvim_buf_set_extmark(buf, ns_id, help_line_num, 0, {
    end_line = help_line_num + 1,
    hl_group = "TiltHelp",
  })

  -- Set cursor to first resource
  local first_resource_line = 0
  for line_num, _ in pairs(resource_map) do
    if first_resource_line == 0 or line_num < first_resource_line then
      first_resource_line = line_num
    end
  end
  if first_resource_line > 0 then
    vim.api.nvim_win_set_cursor(win, {first_resource_line, 0})
  end

  local function get_resource_at_cursor()
    local cursor_line = vim.api.nvim_win_get_cursor(win)[1]
    return resource_map[cursor_line]
  end

  local function close_windows()
    -- Close main window
    if win and vim.api.nvim_win_is_valid(win) then
      pcall(vim.api.nvim_win_close, win, true)
    end
    -- Delete buffer to clean up completely
    if buf and vim.api.nvim_buf_is_valid(buf) then
      pcall(vim.api.nvim_buf_delete, buf, { force = true })
    end
    -- Clear references
    current_win = nil
    current_buf = nil
  end

  local function refresh_with_tab(tab)
    -- Store cursor position before refresh
    local cursor_pos = vim.api.nvim_win_get_cursor(win)
    close_windows()
    -- Schedule the refresh to avoid conflicts
    vim.schedule(function()
      M.show_resources(tab)
      -- Try to restore cursor position
      vim.schedule(function()
        if current_win and vim.api.nvim_win_is_valid(current_win) then
          pcall(vim.api.nvim_win_set_cursor, current_win, cursor_pos)
        end
      end)
    end)
  end

  -- Key mappings
  local keymaps = {
    ["1"] = function() refresh_with_tab(1) end,
    ["2"] = function() if #tabs >= 2 then refresh_with_tab(2) end end,
    ["3"] = function() if #tabs >= 3 then refresh_with_tab(3) end end,
    ["4"] = function() if #tabs >= 4 then refresh_with_tab(4) end end,
    ["5"] = function() if #tabs >= 5 then refresh_with_tab(5) end end,
    ["<Tab>"] = function()
      local next_tab = active_tab % #tabs + 1
      refresh_with_tab(next_tab)
    end,
    ["<S-Tab>"] = function()
      local prev_tab = active_tab - 1
      if prev_tab < 1 then prev_tab = #tabs end
      refresh_with_tab(prev_tab)
    end,
    ["<CR>"] = function()
      local resource = get_resource_at_cursor()
      if resource then
        M.show_resource_details(resource)
      end
    end,
    ["r"] = function()
      local resource = get_resource_at_cursor()
      if resource then
        pending_actions[resource.name] = true
        M.show_resources(current_tab)
        require("tilt-view.api").restart_resource(resource.name)
      end
    end,
    ["e"] = function()
      local resource = get_resource_at_cursor()
      if resource then
        pending_actions[resource.name] = true
        M.show_resources(current_tab)
        require("tilt-view.api").enable_resource(resource.name)
      end
    end,
    ["d"] = function()
      local resource = get_resource_at_cursor()
      if resource then
        pending_actions[resource.name] = true
        M.show_resources(current_tab)
        require("tilt-view.api").disable_resource(resource.name)
      end
    end,
    ["l"] = function()
      local resource = get_resource_at_cursor()
      if resource then
        close_windows()
        M.show_logs(resource.name)
      end
    end,
    ["R"] = function()
      websocket.subscribe_to_resources()
      vim.defer_fn(function() refresh_with_tab(active_tab) end, 200)
    end,
    ["q"] = function()
      close_windows()
    end,
    ["<Esc>"] = function()
      close_windows()
    end,
  }

  for key, action in pairs(keymaps) do
    vim.api.nvim_buf_set_keymap(buf, "n", key, "", {
      callback = action,
      noremap = true,
      silent = true,
    })
  end

  -- No need for autocmd since status is part of main window now
end

---Show detailed information for a resource
---@param resource table Resource data object
M.show_resource_details = function(resource)
  local lines = {
    "",
    "  " .. get_status_icon(resource.status) .. " " .. resource.name,
    "",
    "  Status:   " .. get_status_text(resource.status),
    "  Type:     " .. (resource.type or "Unknown"),
    "",
  }

  if resource.endpoints and #resource.endpoints > 0 then
    table.insert(lines, "  Endpoints:")
    for _, endpoint in ipairs(resource.endpoints) do
      table.insert(lines, "    • " .. (endpoint.url or endpoint))
    end
    table.insert(lines, "")
  end

  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false

  local width = 50
  local height = #lines

  local win = vim.api.nvim_open_win(buf, true, {
    relative = "cursor",
    width = width,
    height = height,
    row = 1,
    col = 0,
    style = "minimal",
    border = "rounded",
    title = " Resource Details ",
    title_pos = "center",
  })

  -- Highlight status
  vim.api.nvim_buf_set_extmark(buf, ns_id, 1, 2, {
    end_col = 5,
    hl_group = get_status_highlight(resource.status),
  })

  vim.api.nvim_buf_set_keymap(buf, "n", "q", "", {
    callback = function()
      vim.api.nvim_win_close(win, true)
    end,
    noremap = true,
    silent = true,
  })

  vim.api.nvim_buf_set_keymap(buf, "n", "<Esc>", "", {
    callback = function()
      vim.api.nvim_win_close(win, true)
    end,
    noremap = true,
    silent = true,
  })
end

---Show logs for a resource in a floating window
---@param resource_name string? Name of resource or nil for all
M.show_logs = function(resource_name)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].modifiable = false
  vim.bo[buf].filetype = "log"

  local width = math.floor(vim.o.columns * 0.9)
  local height = math.floor(vim.o.lines * 0.8)

  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    width = width,
    height = height,
    row = math.floor((vim.o.lines - height) / 2),
    col = math.floor((vim.o.columns - width) / 2),
    style = "minimal",
    border = "rounded",
    title = string.format(" Logs: %s ", resource_name or "All"),
    title_pos = "center",
  })

  local lines = { "  Fetching logs...", "", "  Press 'q' or <Esc> to close" }
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false

  vim.api.nvim_buf_set_keymap(buf, "n", "q", "", {
    callback = function()
      vim.api.nvim_win_close(win, true)
    end,
    noremap = true,
    silent = true,
  })

  vim.api.nvim_buf_set_keymap(buf, "n", "<Esc>", "", {
    callback = function()
      vim.api.nvim_win_close(win, true)
    end,
    noremap = true,
    silent = true,
  })

  -- TODO: Implement actual log streaming
  vim.notify("Log streaming coming soon!", vim.log.levels.INFO)
end

return M
