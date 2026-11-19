--- lsp-cache.nvim: keep what clangd and pyright need for a project in a cache
--- outside the repo, so `make clean`, branch switches or container rebuilds
--- don't break the LSPs. See :help lsp-cache.
local project = require("lsp-cache.project")

local M = {}

local uv = vim.uv

---@class lsp_cache.Opts
---@field clangd? { enabled?: boolean, cmd?: string[], fallback_args?: string[] }
---@field python_servers? string[] Servers whose settings.python.pythonPath is set.
---@field restart_after_sync? boolean
M.opts = {
  clangd = {
    enabled = true,
    -- Base command; --compile-commands-dir=<cache> is appended when cached.
    cmd = { "clangd", "--background-index" },
    -- Appended only when no toolchain headers are cached, e.g.
    -- { "--query-driver=/usr/bin/arm-none-eabi-*" }.
    fallback_args = {},
  },
  python_servers = { "pyright", "basedpyright" },
  restart_after_sync = true,
}

local function exists(path)
  return uv.fs_stat(path) ~= nil
end

--- Cache dir for the project containing `path`, if it has been synced.
---@param path string?
---@return string?
function M.cache_for(path)
  local root = project.root(path)
  local dir = root and project.cache_dir(root)
  return dir and exists(dir) and dir or nil
end

--- clangd command line for a root dir (used by the clangd `cmd` hook).
---@param root_dir string?
---@return string[]
function M.clangd_cmd(root_dir)
  local o = M.opts.clangd
  local cmd = vim.deepcopy(o.cmd)
  local cache = M.cache_for(root_dir)
  if cache and exists(cache .. "/compile_commands.json") then
    cmd[#cmd + 1] = "--compile-commands-dir=" .. cache
  end
  if not (cache and exists(cache .. "/sysroot")) then
    vim.list_extend(cmd, o.fallback_args or {})
  end
  return cmd
end

--- Python interpreter of the cached venv, if any.
---@param root_dir string?
---@return string?
function M.python_path(root_dir)
  local cache = M.cache_for(root_dir)
  local py = cache and cache .. "/venv/bin/python"
  return py and exists(py) and py or nil
end

--- Restart the LSP clients that belong to `root`, re-attaching their buffers.
--- Restarting re-runs the `cmd` hook, which picks up the new cache.
---@param root string
function M.restart_clients(root)
  local names = vim.list_extend({ "clangd" }, M.opts.python_servers)
  for _, client in ipairs(vim.lsp.get_clients()) do
    if vim.tbl_contains(names, client.name) and project.root(client.root_dir) == root then
      local bufs = vim.tbl_keys(client.attached_buffers)
      local config = client.config
      client:stop()
      local timer = assert(uv.new_timer())
      timer:start(100, 100, function()
        if not client:is_stopped() then
          return
        end
        timer:stop()
        timer:close()
        vim.schedule(function()
          local id = vim.lsp.start(config, { attach = false })
          for _, buf in ipairs(id and bufs or {}) do
            if vim.api.nvim_buf_is_valid(buf) then
              vim.lsp.buf_attach_client(buf, id)
            end
          end
        end)
      end)
    end
  end
end

-- Subcommands -------------------------------------------------------------

local function need_root()
  local root = project.current_root()
  if not root then
    vim.notify("lsp-cache: not inside a git repo", vim.log.levels.WARN)
  end
  return root
end

--- Show lines in a scratch float; `q` closes it.
---@param title string
---@param lines string[]
local function show(title, lines)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  vim.bo[buf].bufhidden = "wipe"
  local width = 40
  for _, l in ipairs(lines) do
    width = math.max(width, vim.fn.strdisplaywidth(l))
  end
  width = math.min(width + 2, vim.o.columns - 4)
  local height = math.min(#lines, vim.o.lines - 6)
  vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    width = width,
    height = height,
    row = math.floor((vim.o.lines - height) / 2) - 1,
    col = math.floor((vim.o.columns - width) / 2),
    border = "rounded",
    title = " " .. title .. " ",
    style = "minimal",
  })
  vim.keymap.set("n", "q", "<cmd>close<cr>", { buffer = buf, nowait = true })
end

---@param bang boolean
---@param args string[]
function M.sync(bang, args)
  local root = need_root()
  if not root then
    return
  end
  local opts = {
    venv = not vim.tbl_contains(args, "--no-venv"),
    toolchain = not vim.tbl_contains(args, "--no-toolchain"),
  }
  local headless = #vim.api.nvim_list_uis() == 0
  local done = false
  local msg = ("lsp-cache: syncing %s…"):format(project.name(root))
  if headless then
    io.stdout:write(msg .. "\n")
  else
    vim.notify(msg)
  end
  require("lsp-cache.sync").sync(root, opts, function(ok, log)
    done = true
    local level = ok and vim.log.levels.INFO or vim.log.levels.ERROR
    if headless then
      io.stdout:write(table.concat(log, "\n") .. "\n")
    else
      vim.notify("lsp-cache:\n" .. table.concat(log, "\n", 3), level)
    end
    if M.opts.restart_after_sync and not bang then
      M.restart_clients(root)
    end
  end)
  if headless then -- `nvim --headless +'LspCache sync' +q` must wait for it
    vim.wait(30 * 60 * 1000, function()
      return done
    end, 200)
  end
end

local function human_age(t)
  if not t then
    return "never"
  end
  local s = os.time() - t
  if s < 120 then
    return s .. "s ago"
  elseif s < 7200 then
    return math.floor(s / 60) .. " min ago"
  elseif s < 172800 then
    return math.floor(s / 3600) .. " h ago"
  end
  return math.floor(s / 86400) .. " days ago"
end

function M.status()
  local root = need_root()
  if not root then
    return
  end
  local cache = project.cache_dir(root)
  local cfg_path = project.config_path(root)
  local state = project.state(cache)
  local lines = {
    "Project   " .. root,
    "Config    " .. cfg_path .. (exists(cfg_path) and "" or "  (none: :LspCache edit)"),
    "Cache     " .. cache .. (exists(cache) and "" or "  (none: :LspCache sync)"),
    "Last sync " .. human_age(state.last_sync) .. (state.last_ok == false and "  FAILED (:LspCache log)" or ""),
    "",
  }
  local db = project.read_json(cache .. "/compile_commands.json", nil)
  lines[#lines + 1] = "Compile DB    " .. (db and (#db .. " entries") or "-")
  local ok, cfg = pcall(project.config, root)
  for _, rel in ipairs(ok and cfg.generated_include_dirs or {}) do
    local cached = exists(cache .. "/gen/" .. rel) and "cached" or "not cached"
    local live = exists(root .. "/" .. rel) and "" or ", missing in repo"
    lines[#lines + 1] = ("Generated     %s (%s%s)"):format(rel, cached, live)
  end
  lines[#lines + 1] = "Toolchain     " .. (exists(cache .. "/sysroot") and "cached system headers" or "not cached (fallback args)")
  local py = M.python_path(root)
  lines[#lines + 1] = "Python venv   " .. (py or "-")
  lines[#lines + 1] = ""
  lines[#lines + 1] = "Running clients:"
  local any = false
  for _, c in ipairs(vim.lsp.get_clients()) do
    if project.root(c.root_dir) == root then
      any = true
      local detail = ""
      if c.name == "clangd" then
        detail = table.concat(M.clangd_cmd(c.root_dir), " ")
      elseif vim.tbl_contains(M.opts.python_servers, c.name) then
        detail = "python = " .. tostring(vim.tbl_get(c.settings, "python", "pythonPath") or "default")
      end
      lines[#lines + 1] = ("  %-12s %s"):format(c.name, detail)
    end
  end
  if not any then
    lines[#lines + 1] = "  (none for this project)"
  end
  show("LspCache status", lines)
end

function M.edit()
  local root = need_root()
  if not root then
    return
  end
  local path = project.config_path(root)
  if not exists(path) then
    project.write_file(path, project.template:format(project.name(root)))
  end
  vim.cmd.edit(vim.fn.fnameescape(path))
end

function M.clean()
  local root = need_root()
  if not root then
    return
  end
  local cache = project.cache_dir(root)
  if not exists(cache) then
    return vim.notify("lsp-cache: nothing cached for " .. project.name(root))
  end
  if vim.fn.confirm("Delete " .. cache .. "?", "&Yes\n&No", 2) ~= 1 then
    return
  end
  vim.fs.rm(cache, { recursive = true, force = true })
  vim.notify("lsp-cache: removed " .. cache)
  M.restart_clients(root)
end

function M.log()
  local root = need_root()
  if not root then
    return
  end
  local data = project.read_file(project.cache_dir(root) .. "/last_sync.log")
  show("LspCache log", data and vim.split(vim.trim(data), "\n") or { "No sync has run for this project yet." })
end

M.subcommands = {
  sync = M.sync,
  status = M.status,
  edit = M.edit,
  clean = M.clean,
  log = M.log,
}

--- Entry point for the :LspCache user command.
function M.command(cmd)
  local sub = cmd.fargs[1] or "status"
  local fn = M.subcommands[sub]
  if not fn then
    return vim.notify("lsp-cache: unknown subcommand " .. sub, vim.log.levels.ERROR)
  end
  fn(cmd.bang, vim.list_slice(cmd.fargs, 2))
end

function M.complete(arglead, line)
  local words = vim.split(line, "%s+", { trimempty = true })
  local n = #words + (line:match("%s$") and 1 or 0)
  local items = n <= 2 and vim.tbl_keys(M.subcommands)
    or (words[2] == "sync" and { "--no-venv", "--no-toolchain" } or {})
  table.sort(items)
  return vim.tbl_filter(function(s)
    return s:sub(1, #arglead) == arglead
  end, items)
end

-- Setup -------------------------------------------------------------------

---@param opts? lsp_cache.Opts
function M.setup(opts)
  M.opts = vim.tbl_deep_extend("force", M.opts, opts or {})

  if M.opts.clangd.enabled then
    vim.lsp.config("clangd", {
      -- A function, so flags are chosen per project root at every (re)start.
      cmd = function(dispatchers, config)
        return vim.lsp.rpc.start(M.clangd_cmd(config.root_dir), dispatchers, {
          cwd = config.cmd_cwd,
          env = config.cmd_env,
          detached = config.detached,
        })
      end,
    })
  end

  for _, name in ipairs(M.opts.python_servers) do
    vim.lsp.config(name, {
      on_init = function(client)
        local py = M.python_path(client.root_dir)
        if py then
          client.settings.python = vim.tbl_deep_extend("force", client.settings.python or {}, { pythonPath = py })
          client:notify("workspace/didChangeConfiguration", { settings = nil })
        end
      end,
    })
  end
end

return M
