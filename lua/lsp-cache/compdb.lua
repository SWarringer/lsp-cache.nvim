--- compile_commands.json handling. Pure functions (apart from file existence
--- checks), so they can be unit tested without a build.
local M = {}

---@class lsp_cache.Entry
---@field directory string
---@field file string
---@field arguments string[]
---@field output? string

local CXX_EXT = { cc = true, cpp = true, cxx = true, ["c++"] = true, C = true }
local INCLUDE_FLAGS = { "-isystem", "-iquote", "-idirafter", "-I" }

--- Split a shell-style command line (the `command` form of an entry).
--- Handles single/double quotes and backslash escapes, which covers what
--- CMake/bear/compiledb emit.
---@param s string
---@return string[]
function M.shell_split(s)
  local args, cur, i, n = {}, nil, 1, #s
  local quote ---@type string?
  while i <= n do
    local ch = s:sub(i, i)
    if quote then
      if ch == quote then
        quote = nil
      elseif ch == "\\" and quote == '"' and i < n then
        i = i + 1
        cur = cur .. s:sub(i, i)
      else
        cur = cur .. ch
      end
    elseif ch == "'" or ch == '"' then
      quote, cur = ch, cur or ""
    elseif ch == "\\" and i < n then
      i = i + 1
      cur = (cur or "") .. s:sub(i, i)
    elseif ch:match("%s") then
      if cur then
        args[#args + 1], cur = cur, nil
      end
    else
      cur = (cur or "") .. ch
    end
    i = i + 1
  end
  if cur then
    args[#args + 1] = cur
  end
  return args
end

---@param dir string
---@param path string
---@return string
local function absolute(dir, path)
  if path:sub(1, 1) ~= "/" then
    path = dir .. "/" .. path
  end
  return vim.fs.normalize(path)
end

--- Give every entry an `arguments` list and an absolute `file`.
---@param e table
---@return lsp_cache.Entry
function M.normalise(e)
  local out = vim.deepcopy(e)
  if not out.arguments then
    out.arguments = M.shell_split(out.command or "")
    out.command = nil
  end
  out.file = absolute(out.directory, out.file)
  return out
end

---@param e lsp_cache.Entry
local function key(e)
  return e.directory .. "\0" .. e.file
end

--- Merge `new` into `old` keyed by (directory, file); new entries win, and
--- entries whose source file no longer exists are dropped.
---@param old lsp_cache.Entry[]
---@param new table[]
---@param exists? fun(path: string): boolean
---@return lsp_cache.Entry[] merged, integer dropped
function M.merge(old, new, exists)
  exists = exists or function(p)
    return vim.uv.fs_stat(p) ~= nil
  end
  local by_key, order = {}, {}
  local function put(e)
    local k = key(e)
    if not by_key[k] then
      order[#order + 1] = k
    end
    by_key[k] = e
  end
  for _, e in ipairs(old) do
    put(e)
  end
  for _, e in ipairs(new) do
    put(M.normalise(e))
  end
  local merged, dropped = {}, 0
  for _, k in ipairs(order) do
    local e = by_key[k]
    if exists(e.file) then
      merged[#merged + 1] = e
    else
      dropped = dropped + 1
    end
  end
  return merged, dropped
end

--- Parse args[i] as an include flag, joined (-Ifoo) or separate (-I foo).
---@return string? flag, string? path, integer consumed
local function include_at(args, i)
  local a = args[i]
  for _, flag in ipairs(INCLUDE_FLAGS) do
    if a == flag and args[i + 1] then
      return flag, args[i + 1], 2
    elseif #a > #flag and a:sub(1, #flag) == flag then
      return flag, a:sub(#flag + 1), 1
    end
  end
  return nil, nil, 1
end

--- Point include paths that fall inside a generated dir at its cached copy.
---@param e lsp_cache.Entry
---@param gen_map table<string, string> absolute source dir -> cached copy
function M.rewrite_generated(e, gen_map)
  if next(gen_map) == nil then
    return
  end
  local args, out, i = e.arguments, {}, 1
  while i <= #args do
    local flag, path, used = include_at(args, i)
    if not flag then
      out[#out + 1] = args[i]
    else
      local abs = absolute(e.directory, path --[[@as string]])
      for src, dst in pairs(gen_map) do
        if abs == src or abs:sub(1, #src + 1) == src .. "/" then
          path = dst .. abs:sub(#src + 1)
          break
        end
      end
      if used == 1 then
        out[#out + 1] = flag .. path
      else
        out[#out + 1] = flag
        out[#out + 1] = path
      end
    end
    i = i + used
  end
  e.arguments = out
end

--- (compiler basename, language) an entry needs system headers for.
---@param e lsp_cache.Entry
---@return string cc, "c"|"c++" lang
function M.toolchain_key(e)
  local ext = e.file:match("%.([^./]+)$") or ""
  return vim.fs.basename(e.arguments[1] or ""), CXX_EXT[ext] and "c++" or "c"
end

---@class lsp_cache.SysInc
---@field triple string
---@field dirs string[]

--- Replace the compiler's built-in search path with the cached copy.
---@param e lsp_cache.Entry
---@param sys lsp_cache.SysInc
function M.add_sysinc(e, sys)
  local extra = { "--target=" .. sys.triple, "-nostdinc" }
  for _, d in ipairs(sys.dirs) do
    vim.list_extend(extra, { "-isystem", d })
  end
  local args = e.arguments
  e.arguments = vim.list_extend({ args[1] }, vim.list_extend(extra, args, 2))
end

--- Parse `cc -E -v` output into the system include list (gcc's order).
---@param lines string[]
---@return string[]?
function M.parse_search_list(lines)
  local dirs, inside = {}, false
  for _, line in ipairs(lines) do
    if line == "#include <...> search starts here:" then
      inside = true
    elseif line == "End of search list." then
      return inside and dirs or nil
    elseif inside then
      dirs[#dirs + 1] = vim.fs.normalize(vim.trim(line))
    end
  end
  return nil
end

return M
