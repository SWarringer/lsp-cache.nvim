local M = {}

function M.check()
  local h = vim.health
  local project = require("lsp-cache.project")
  local lc = require("lsp-cache")

  h.start("lsp-cache: requirements")
  if vim.fn.has("nvim-0.11") == 1 then
    h.ok("Neovim " .. tostring(vim.version()))
  else
    h.error("Neovim 0.11+ required (vim.lsp.config, function `cmd`)")
  end
  for _, exe in ipairs({ "git", "cp" }) do
    if vim.fn.executable(exe) == 1 then
      h.ok(exe .. " found")
    else
      h.error(exe .. " not found")
    end
  end
  if vim.fn.executable("uv") == 1 then
    h.ok("uv found: " .. vim.fn.exepath("uv"))
  else
    h.warn("uv not found: python venvs can't be built", { "https://docs.astral.sh/uv/" })
  end

  h.start("lsp-cache: current project")
  local root = project.current_root()
  if not root then
    h.info("not inside a git repo")
    return
  end
  h.info("root: " .. root)
  local cfg_path = project.config_path(root)
  if vim.uv.fs_stat(cfg_path) then
    local ok, err = pcall(project.config, root)
    if ok then
      h.ok("config: " .. cfg_path)
    else
      h.error(tostring(err))
    end
  else
    h.info("no config (only the compile DB is cached); create one with :LspCache edit")
  end
  local cache = project.cache_dir(root)
  if vim.uv.fs_stat(cache) then
    h.ok("cache: " .. cache)
  else
    h.warn("not synced yet", { ":LspCache sync" })
  end
  h.info("clangd cmd: " .. table.concat(lc.clangd_cmd(root), " "))
  h.info("python: " .. (lc.python_path(root) or "server default"))
end

return M
