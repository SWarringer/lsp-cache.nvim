# lsp-cache.nvim

Keeps what clangd and pyright need for a project in a cache **outside the
repo**, so `make clean`, branch switches and container rebuilds don't break
your LSPs. Nothing is written to the repository.

What gets cached per project:
- a merged `compile_commands.json`, so incremental bear runs don't shrink it
- copies of generated header dirs (e.g. protobuf output in `build_dir`)
- the cross toolchain's system headers, so clangd works without the toolchain
  installed where nvim runs (host, distrobox or container)
- a Python venv built with [uv](https://docs.astral.sh/uv/), independent of the
  system Python

## Commands

| Command | |
|---|---|
| `:LspCache sync` | snapshot this repo and restart its LSPs (`!` = no restart) |
| `:LspCache status` | what's cached and what each client is using |
| `:LspCache edit` | open this repo's config |
| `:LspCache log` | output of the last sync |
| `:LspCache clean` | delete this repo's cache |

From a shell: `nvim --headless +'LspCache sync' +q`

## Install (lazy.nvim)

```lua
{
  dir = "~/Dev/lsp-cache.nvim",
  lazy = false,
  opts = {
    clangd = { fallback_args = { "--query-driver=/usr/bin/arm-none-eabi-*" } },
  },
}
```

Per-project config lives in `~/.config/nvim/lsp-cache/<repo>.lua`. See
`:help lsp-cache-config`.

## Tests

```sh
nvim -l tests/compdb_spec.lua
```
