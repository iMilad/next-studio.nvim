local root = assert(vim.env.NEXT_STUDIO_TEST_ROOT)
local plugin = assert(vim.env.NEXT_STUDIO_PLUGIN)
vim.opt.rtp:prepend(plugin)
vim.g.mapleader = " "
vim.o.shadafile, vim.o.swapfile, vim.o.undofile, vim.o.modeline = "NONE", false, false, false
for _, provider in ipairs({ "python", "python3", "node", "ruby", "perl" }) do vim.g["loaded_" .. provider .. "_provider"] = 0 end
vim.o.lines, vim.o.columns, vim.o.winminwidth = 46, 160, 5
vim.o.shell = "/bin/sh"
require("next_studio").setup({ auto_open = false, state_dir = root .. "/state", project_roots = { root .. "/projects" },
  shell = { "/bin/sh", "-c", "printf 'Synthetic shell ready\n'; exec /bin/cat" } })
