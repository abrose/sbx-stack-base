return {
  "saghen/blink.cmp",
  dependencies = {
    "saghen/blink.lib",
    -- optional: provides snippets for the snippet source
    "rafamadriz/friendly-snippets",
  },
  build = function()
    require("blink.cmp").build():pwait()
  end,
  -- build = function()
  -- build the fuzzy matcher, wait up to 60 seconds
  -- you can use `gb` in `:Lazy` to rebuild the plugin as needed
  --   require("blink.cmp").build():wait(60000)
  -- end,

  ---@module 'blink.cmp'
  ---@type blink.cmp.Config
  opts = {
    -- 'default' (recommended) for mappings similar to built-in completions (C-y to accept)
    -- 'super-tab' for mappings similar to vscode (tab to accept)
    -- 'enter' for enter to accept
    -- 'none' for no mappings
    --
    -- All presets have the following mappings:
    -- C-space: Open menu or open docs if already open
    -- C-n/C-p or Up/Down: Select next/previous item
    -- C-e: Hide menu
    -- C-k: Toggle signature help (if signature.enabled = true)
    --
    -- See :h blink-cmp-config-keymap for defining your own keymap
    keymap = {
      preset = "default",
      -- <Alt-y> manually triggers minuet completions
      ["<A-y>"] = {
        function(cmp)
          cmp.show({ providers = { "minuet" } })
        end,
      },
    },

    -- (Default) Only show the documentation popup when manually triggered
    completion = { documentation = { auto_show = false } },

    -- (Default) list of enabled providers defined so that you can extend it
    -- elsewhere in your config, without redefining it, due to `opts_extend`
    sources = {
      default = { "lsp", "path", "snippets", "buffer" },
      -- Don't add 'minuet' to `default` — that would auto-trigger on every
      -- keystroke and rack up API calls. Manual-only is the sane default.
      providers = {
        minuet = {
          name = "minuet",
          module = "minuet.blink",
          score_offset = 100, -- float minuet items to the top when present
        },
      },
    },
    -- (Default) Rust fuzzy matcher for typo resistance and significantly better performance
    -- You may use a lua implementation instead by using `implementation = "lua"`
    -- See the fuzzy documentation for more information
    fuzzy = { implementation = "prefer_rust_with_warning" },
  },
}
