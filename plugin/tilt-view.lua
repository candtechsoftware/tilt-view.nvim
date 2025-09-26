if vim.g.loaded_tilt_view then
  return
end
vim.g.loaded_tilt_view = 1

vim.api.nvim_create_user_command("Tilt", function(args)
  require("tilt-view").command(args.args)
end, {
  nargs = "*",
  complete = function(ArgLead, CmdLine, CursorPos)
    return require("tilt-view").complete(ArgLead, CmdLine, CursorPos)
  end,
  desc = "Tilt resource management",
})