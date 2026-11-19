--- `:LspCache sync`: snapshot what the LSPs need into the project's cache.
---
--- Runs in a coroutine; external commands (uv, the toolchain, cp) run through
--- vim.system and yield, so the editor stays responsive.
local compdb = require("lsp-cache.compdb")
local project = require("lsp-cache.project")

local M = {}

local uv = vim.uv
local running = {} ---@type table<string, boolean>

--- Run a command from inside the sync coroutine and wait for it.
---@param cmd string[]
---@param opts? vim.SystemOpts
---@return vim.SystemCompleted
local function run(cmd, opts)
  local co = assert(coroutine.running(), "run() must be called from a coroutine")
  local ok, err = pcall(vim.system, cmd, vim.tbl_extend("force", { text = true }, opts or {}), function(res)
    vim.schedule(function()
      coroutine.resume(co, res)
    end)
  end)
  if not ok then -- e.g. executable not found
    return { code = 127, signal = 0, stdout = "", stderr = tostring(err) }
  end
  return coroutine.yield()
end

--- stdout+stderr as lines, CRs stripped. Wrappers that allocate a TTY
--- (e.g. `podman exec -t`) deliver everything on one stream.
---@param res vim.SystemCompleted
---@return string[]
local function output_lines(res)
  local text = (res.stdout or "") .. "\n" .. (res.stderr or "")
  local lines = {}
  for line in text:gmatch("[^\n]+") do
    lines[#lines + 1] = (line:gsub("\r$", ""))
  end
  return lines
end

---@param lines string[]
local function tail(lines, n)
  return table.concat(vim.list_slice(lines, math.max(1, #lines - n + 1)), "\n")
end

---@param path string
local function is_dir(path)
  local st = uv.fs_stat(path)
  return st ~= nil and st.type == "directory"
end

---@class lsp_cache.SyncCtx
---@field root string
---@field cache string
---@field cfg lsp_cache.ProjectConfig
---@field state table
---@field log string[]
---@field failed boolean
---@field opts { venv: boolean, toolchain: boolean }

---@param ctx lsp_cache.SyncCtx
local function say(ctx, fmt, ...)
  ctx.log[#ctx.log + 1] = fmt:format(...)
end

---@param ctx lsp_cache.SyncCtx
local function fail(ctx, fmt, ...)
  ctx.failed = true
  say(ctx, "FAILED: " .. fmt, ...)
end

---@param ctx lsp_cache.SyncCtx
---@return table<string, string> gen_map
local function snapshot_generated(ctx)
  local gen_map = {}
  for _, rel in ipairs(ctx.cfg.generated_include_dirs or {}) do
    local src = vim.fs.normalize(ctx.root .. "/" .. rel)
    local dst = ctx.cache .. "/gen/" .. rel
    if is_dir(src) then
      local tmp = dst .. ".tmp"
      vim.fs.rm(tmp, { recursive = true, force = true })
      vim.fn.mkdir(vim.fs.dirname(dst), "p")
      local res = run({ "cp", "-rL", src, tmp })
      if res.code == 0 then
        vim.fs.rm(dst, { recursive = true, force = true })
        uv.fs_rename(tmp, dst)
        say(ctx, "generated: copied %s", rel)
      else
        fail(ctx, "copying %s: %s", rel, res.stderr)
      end
    elseif is_dir(dst) then
      say(ctx, "generated: %s missing, kept previous copy", rel)
    else
      say(ctx, "generated: %s missing, nothing cached yet", rel)
    end
    if is_dir(dst) then
      gen_map[src] = dst
    end
  end
  return gen_map
end

---@param ctx lsp_cache.SyncCtx
---@param db lsp_cache.Entry[]
---@return table<string, lsp_cache.SysInc> keyed by "cc|lang"
local function snapshot_toolchain(ctx, db)
  local tc = ctx.cfg.toolchain
  if not tc then
    vim.fs.rm(ctx.cache .. "/sysroot", { recursive = true, force = true })
    return {}
  end
  if not ctx.opts.toolchain then
    say(ctx, "toolchain: skipped")
    return ctx.state.sysinc or {}
  end
  local needed = {}
  for _, e in ipairs(db) do
    local cc, lang = compdb.toolchain_key(e)
    needed[cc .. "|" .. lang] = true
  end
  local function tc_run(cmd)
    return run(vim.list_extend(vim.deepcopy(tc.run or {}), cmd), { cwd = ctx.root })
  end

  local result = {}
  for _, cc in ipairs(tc.compilers or {}) do
    for _, lang in ipairs({ "c", "c++" }) do
      if needed[cc .. "|" .. lang] then
        local dirs = compdb.parse_search_list(output_lines(tc_run({ cc, "-x", lang, "-E", "-v", "/dev/null" })))
        local machine = output_lines(tc_run({ cc, "-dumpmachine" }))
        local version = output_lines(tc_run({ cc, "--version" }))
        if not dirs or #machine == 0 then
          fail(ctx, "toolchain: could not query %s (is `%s` working?)", cc, table.concat(tc.run or {}, " "))
        else
          local dest = ctx.cache .. "/sysroot/" .. vim.fn.sha256(table.concat(version, "\n")):sub(1, 12)
          local missing = vim.tbl_filter(function(d)
            return not is_dir(dest .. d)
          end, dirs)
          if #missing > 0 then
            -- Copy from wherever the compiler lives. $HOME is mounted at the
            -- same path in containers, so `dest` is valid on both sides.
            local script = 'd="$1"; shift; mkdir -p "$d" && cp -rL --parents "$@" "$d"'
            local res = tc_run(vim.list_extend({ "sh", "-c", script, "sh", dest }, missing))
            if res.code ~= 0 then
              fail(ctx, "toolchain: copying %s headers:\n%s", cc, tail(output_lines(res), 10))
            else
              say(ctx, "toolchain: %s (%s) copied %d dirs", cc, lang, #missing)
            end
          else
            say(ctx, "toolchain: %s (%s) up to date", cc, lang)
          end
          result[cc .. "|" .. lang] = {
            triple = machine[#machine],
            dirs = vim.tbl_map(function(d)
              return dest .. d
            end, dirs),
          }
        end
      end
    end
  end
  ctx.state.sysinc = result
  return result
end

---@param ctx lsp_cache.SyncCtx
local function snapshot_venv(ctx)
  local py = ctx.cfg.python or {}
  local files = {}
  for _, pat in ipairs(py.requirements or {}) do
    for _, f in ipairs(vim.fn.glob(ctx.root .. "/" .. pat, false, true)) do
      files[f:sub(#ctx.root + 2)] = true
    end
  end
  files = vim.tbl_keys(files)
  table.sort(files)
  if #files == 0 then
    say(ctx, "venv: no requirements configured")
    return
  end
  if not ctx.opts.venv then
    say(ctx, "venv: skipped")
    return
  end

  local parts = { py.version or "" }
  for _, f in ipairs(files) do
    parts[#parts + 1] = f .. "\n" .. (project.read_file(ctx.root .. "/" .. f) or "")
  end
  local hash = vim.fn.sha256(table.concat(parts, "\n"))
  local venv = ctx.cache .. "/venv"
  if ctx.state.venv_hash == hash and uv.fs_stat(venv .. "/bin/python") then
    say(ctx, "venv: up to date")
    return
  end

  local uv_bin = vim.fn.exepath("uv")
  if uv_bin == "" then
    return fail(ctx, "venv: `uv` not found on PATH (https://docs.astral.sh/uv/)")
  end
  local create = { uv_bin, "venv", "--quiet", "--clear" }
  if py.version then
    vim.list_extend(create, { "--python", py.version })
  end
  local res = run(vim.list_extend(create, { venv }))
  if res.code ~= 0 then
    return fail(ctx, "venv: %s", tail(output_lines(res), 10))
  end
  local bad = {}
  for _, f in ipairs(files) do
    -- From the repo root: lines like `vendor/pip/x.tar.gz` are cwd-relative.
    res = run({ uv_bin, "pip", "install", "--quiet", "--python", venv .. "/bin/python", "-r", f }, { cwd = ctx.root })
    if res.code ~= 0 then
      bad[#bad + 1] = f
      say(ctx, "venv: %s:\n%s", f, tail(output_lines(res), 10))
    end
  end
  if #bad > 0 then
    return fail(ctx, "venv: %s (will retry next sync)", table.concat(bad, ", "))
  end
  ctx.state.venv_hash = hash
  say(ctx, "venv: rebuilt from %d requirement files", #files)
end

---@param ctx lsp_cache.SyncCtx
local function do_sync(ctx)
  say(ctx, "repo  %s", ctx.root)
  say(ctx, "cache %s", ctx.cache)
  vim.fn.mkdir(ctx.cache, "p")

  local raw_path = ctx.cache .. "/raw_compile_commands.json"
  local new = project.read_json(ctx.root .. "/compile_commands.json", {})
  local db, dropped = compdb.merge(project.read_json(raw_path, {}), new)
  project.write_json(raw_path, db)
  say(ctx, "compile db: %d entries (%d from repo, %d stale dropped)", #db, #new, dropped)

  local gen_map = snapshot_generated(ctx)
  local sysinc = snapshot_toolchain(ctx, db)

  -- Derived DB: rewrites applied to a copy, so the raw DB never accumulates them.
  local out = {}
  for _, raw in ipairs(db) do
    local e = vim.deepcopy(raw)
    compdb.rewrite_generated(e, gen_map)
    local cc, lang = compdb.toolchain_key(e)
    local sys = sysinc[cc .. "|" .. lang]
    if sys then
      compdb.add_sysinc(e, sys)
    end
    out[#out + 1] = e
  end
  project.write_json(ctx.cache .. "/compile_commands.json", out)

  snapshot_venv(ctx)
end

--- Sync the cache for `root`. Calls `on_done(ok, log)` on the main loop.
---@param root string
---@param opts? { venv?: boolean, toolchain?: boolean }
---@param on_done fun(ok: boolean, log: string[])
function M.sync(root, opts, on_done)
  if running[root] then
    return on_done(false, { "a sync is already running for " .. root })
  end
  running[root] = true
  local cache = project.cache_dir(root)

  coroutine.wrap(function()
    ---@type lsp_cache.SyncCtx
    local ctx = {
      root = root,
      cache = cache,
      cfg = {},
      state = project.state(cache),
      log = {},
      failed = false,
      opts = vim.tbl_extend("force", { venv = true, toolchain = true }, opts or {}),
    }
    -- LuaJIT can yield across pcall, so errors after a yield still land here.
    local ok, err = xpcall(function()
      ctx.cfg = project.config(root)
      do_sync(ctx)
    end, debug.traceback)
    if not ok then
      fail(ctx, "%s", err)
    end
    ctx.state.last_sync = os.time()
    ctx.state.last_ok = not ctx.failed
    pcall(project.save_state, cache, ctx.state)
    pcall(project.write_file, cache .. "/last_sync.log", table.concat(ctx.log, "\n") .. "\n")
    running[root] = nil
    on_done(not ctx.failed, ctx.log)
  end)()
end

---@param root string
function M.is_running(root)
  return running[root] == true
end

return M
