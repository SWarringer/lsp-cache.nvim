-- Unit tests for lsp-cache.compdb. Run: nvim -l tests/compdb_spec.lua
vim.opt.rtp:prepend(vim.fs.dirname(vim.fs.dirname(debug.getinfo(1, "S").source:sub(2))))
local compdb = require("lsp-cache.compdb")

local failures = 0
local function eq(name, expected, actual)
  if vim.deep_equal(expected, actual) then
    print("ok   " .. name)
  else
    failures = failures + 1
    print(("FAIL %s\n  expected %s\n  actual   %s"):format(name, vim.inspect(expected), vim.inspect(actual)))
  end
end

eq("shell_split plain", { "gcc", "-c", "a.c" }, compdb.shell_split("gcc  -c a.c"))
eq(
  "shell_split quotes/escapes",
  { "gcc", '-DX="a b"', "-DY=c d", "e f" },
  compdb.shell_split([[gcc "-DX=\"a b\"" '-DY=c d' e\ f]])
)

local all = function()
  return true
end
eq(
  "normalise command form",
  { directory = "/r", file = "/r/src/a.c", arguments = { "gcc", "-c", "src/a.c" } },
  compdb.normalise({ directory = "/r", file = "src/./a.c", command = "gcc -c src/a.c" })
)

local old = {
  { directory = "/r", file = "/r/a.c", arguments = { "old" } },
  { directory = "/r", file = "/r/gone.c", arguments = { "x" } },
}
local new = { { directory = "/r", file = "a.c", arguments = { "new" } }, { directory = "/r", file = "b.c", arguments = { "b" } } }
local merged, dropped = compdb.merge(old, new, function(p)
  return p ~= "/r/gone.c"
end)
eq("merge: new wins, order kept, stale dropped", {
  { directory = "/r", file = "/r/a.c", arguments = { "new" } },
  { directory = "/r", file = "/r/b.c", arguments = { "b" } },
}, merged)
eq("merge: dropped count", 1, dropped)
eq("merge: same file, other dir kept separately", 2, #compdb.merge({}, {
  { directory = "/r/x", file = "/r/a.c", arguments = {} },
  { directory = "/r/y", file = "/r/a.c", arguments = {} },
}, all))

local e = {
  directory = "/r",
  file = "/r/a.c",
  arguments = {
    "gcc",
    "-isystembuild_dir/gen",
    "-isystembuild_dir/gen/ble",
    "-I",
    "/r/build_dir/gen",
    "-Ibuild_dir/generated_other",
    "-Isrc",
    "-c",
    "a.c",
  },
}
compdb.rewrite_generated(e, { ["/r/build_dir/gen"] = "/cache/gen/build_dir/gen" })
eq("rewrite_generated", {
  "gcc",
  "-isystem/cache/gen/build_dir/gen",
  "-isystem/cache/gen/build_dir/gen/ble",
  "-I",
  "/cache/gen/build_dir/gen",
  "-Ibuild_dir/generated_other", -- prefix match must respect path boundaries
  "-Isrc",
  "-c",
  "a.c",
}, e.arguments)

eq("toolchain_key c", { "arm-none-eabi-gcc", "c" }, {
  compdb.toolchain_key({ directory = "/", file = "/a.c", arguments = { "/usr/bin/arm-none-eabi-gcc" } }),
})
eq("toolchain_key c++", { "g++", "c++" }, {
  compdb.toolchain_key({ directory = "/", file = "/a.cpp", arguments = { "g++" } }),
})

local s = { directory = "/", file = "/a.c", arguments = { "cc", "-c", "a.c" } }
compdb.add_sysinc(s, { triple = "arm-none-eabi", dirs = { "/c/inc1", "/c/inc2" } })
eq(
  "add_sysinc",
  { "cc", "--target=arm-none-eabi", "-nostdinc", "-isystem", "/c/inc1", "-isystem", "/c/inc2", "-c", "a.c" },
  s.arguments
)

eq("parse_search_list", { "/usr/lib/gcc/x/12/include", "/usr/x/include" }, compdb.parse_search_list({
  "junk",
  "#include \"...\" search starts here:",
  "#include <...> search starts here:",
  " /usr/lib/gcc/x/12/include",
  " /usr/lib/gcc/x/12/../../../../x/include",
  "End of search list.",
}))
eq("parse_search_list missing", nil, compdb.parse_search_list({ "error: no such file" }))

if failures > 0 then
  print(failures .. " failure(s)")
  os.exit(1)
end
print("all passed")
