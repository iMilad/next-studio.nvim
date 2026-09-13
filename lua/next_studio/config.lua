local M = {}
M.defaults = {
  auto_open = false,
  project_roots = {},
  state_dir = nil,
  legacy_registry = nil,
  keymaps = true,
  key_prefix = "<leader>p",
  shell = nil,
  screensaver = { enabled = true, key = "<F12>" },
  history_limit = 30,
  tasks = {},
}
M.options = vim.deepcopy(M.defaults)

function M.setup(opts)
  M.options = vim.tbl_deep_extend("force", vim.deepcopy(M.defaults), opts or {})
  assert(type(M.options.key_prefix) == "string" and M.options.key_prefix ~= "", "key_prefix must be a string")
  assert(type(M.options.history_limit) == "number" and M.options.history_limit >= 1 and M.options.history_limit <= 100, "history_limit must be 1..100")
  return M.options
end

function M.hint(key)
  local leader = vim.g.mapleader or "\\"
  if leader == " " then leader = "Space" end
  return M.options.key_prefix:gsub("<leader>", function() return leader .. " " end) .. " " .. key
end

return M
