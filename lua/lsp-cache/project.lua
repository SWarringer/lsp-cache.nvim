--- Locating a project: its git root, cache dir, config file and saved state.
local M = {}

local uv = vim.uv

--- Git toplevel (repo, submodule or worktree) containing `path`, symlinks resolved.
---@param path string?
---@return string?
function M.root(path)
  if not path or path == "" then
    return nil
  end
  local root = vim.fs.root(path, ".git")
  return root and (uv.fs_realpath(root) or root) or nil
end

--- Root for the current buffer, falling back to the cwd.
---@return string?
function M.current_root()
  return M.root(vim.api.nvim_buf_get_name(0)) or M.root(uv.cwd())
end

---@param root string
---@return string
function M.name(root)
  return vim.fs.basename(root)
end

--- Cache dir for a root. Keyed by path, so each clone/worktree gets its own.
---@param root string
---@return string
function M.cache_dir(root)
  local base = vim.fn.stdpath("state") .. "/lsp-cache"
  return ("%s/%s-%s"):format(base, M.name(root), vim.fn.sha256(root):sub(1, 8))
end

--- Per-project config file. Lives in your nvim config so it travels with your dotfiles.
---@param root string
---@return string
function M.config_path(root)
  return ("%s/lsp-cache/%s.lua"):format(vim.fn.stdpath("config"), M.name(root))
end

---@class lsp_cache.Toolchain
---@field run string[] Prefix that reaches the compiler, e.g. { "podman", "exec", "builder" }; {} runs it directly.
---@field compilers string[] Compiler basenames as they appear in the compile DB.

---@class lsp_cache.ProjectConfig
---@field generated_include_dirs? string[] Repo-relative dirs of generated headers to keep a copy of.
---@field python? { version?: string, requirements?: string[] }
---@field toolchain? lsp_cache.Toolchain

--- Load the per-project config. Missing file => {} (only the compile DB is cached).
---@param root string
---@return lsp_cache.ProjectConfig
function M.config(root)
  local path = M.config_path(root)
  if not uv.fs_stat(path) then
    return {}
  end
  local ok, cfg = pcall(dofile, path)
  if not ok then
    error(("lsp-cache: error in %s:\n%s"):format(path, cfg), 0)
  end
  if type(cfg) ~= "table" then
    error(("lsp-cache: %s must return a table"):format(path), 0)
  end
  return cfg
end

M.template = [[
-- lsp-cache config for %s (see :help lsp-cache-config)
return {
  -- Generated headers to keep a copy of, so clangd resolves them after `make clean`.
  generated_include_dirs = {
    -- "build_dir/generated",
  },

  -- Host-native venv built with uv; pyright/basedpyright are pointed at it.
  python = {
    -- version = "3.11",
    requirements = {
      -- "requirements*.txt",
    },
  },

  -- Copy the cross toolchain's system headers so clangd works without the toolchain.
  -- toolchain = {
  --   run = { "podman", "exec", "builder" }, -- prefix to reach the compiler; {} = run directly
  --   compilers = { "arm-none-eabi-gcc" },
  -- },
}
]]

---@param path string
---@return string?
function M.read_file(path)
  local f = io.open(path, "rb")
  if not f then
    return nil
  end
  local data = f:read("*a")
  f:close()
  return data
end

--- Write via a temp file + rename, so readers (clangd) never see a half-written file.
---@param path string
---@param data string
function M.write_file(path, data)
  vim.fn.mkdir(vim.fs.dirname(path), "p")
  local tmp = path .. ".tmp"
  local f = assert(io.open(tmp, "wb"))
  f:write(data)
  f:close()
  assert(uv.fs_rename(tmp, path))
end

---@param path string
---@param default any
---@return any
function M.read_json(path, default)
  local data = M.read_file(path)
  if not data or data == "" then
    return default
  end
  local ok, value = pcall(vim.json.decode, data, { luanil = { object = true, array = true } })
  return ok and value or default
end

---@param path string
---@param value any
function M.write_json(path, value)
  M.write_file(path, vim.json.encode(value, { escape_slash = false, indent = " " }))
end

---@param cache string
---@return table
function M.state(cache)
  return M.read_json(cache .. "/state.json", {})
end

---@param cache string
---@param state table
function M.save_state(cache, state)
  M.write_json(cache .. "/state.json", state)
end

return M
