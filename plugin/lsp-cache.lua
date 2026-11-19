if vim.g.loaded_lsp_cache then
  return
end
vim.g.loaded_lsp_cache = true

vim.api.nvim_create_user_command("LspCache", function(cmd)
  require("lsp-cache").command(cmd)
end, {
  nargs = "*",
  bang = true,
  desc = "LSP cache: sync | status | edit | clean | log",
  complete = function(arglead, line)
    return require("lsp-cache").complete(arglead, line)
  end,
})
