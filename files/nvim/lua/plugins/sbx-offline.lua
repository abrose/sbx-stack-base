-- The base image has no language servers, and Mason would download them at start, which the sandbox blocks.
-- Language layers bring their own servers later.
return {
  { "mason-org/mason.nvim", enabled = false },
  { "mason-org/mason-lspconfig.nvim", enabled = false },
}
