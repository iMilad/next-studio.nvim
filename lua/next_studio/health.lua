local M = {}
function M.check()
  vim.health.start("NEXT Studio")
  if vim.fn.has("nvim-0.12") == 1 then vim.health.ok("Neovim 0.12+ available")
  else vim.health.error("Neovim 0.12+ is required") end
  vim.health.ok("File browsing is handled by your existing Neovim tools")
  vim.health.ok("Snacks, LazyVim and external UI plugins are optional")
  if vim.fn.has("win32") == 1 then vim.health.warn("Windows has not been validated; current shell/path tests cover POSIX systems") end
end
return M
