local M = { buffers = {} }
local api, uv = vim.api, vim.uv
local store = require("next_studio.store")

local function path(root)
  local dir = store.directory() .. "/notes"
  vim.fn.mkdir(dir, "p", 448)
  local stat = uv.fs_lstat(dir)
  assert(stat and stat.type == "directory", "Invalid notes directory")
  return dir .. "/" .. vim.fn.sha256(root) .. ".md"
end

local function write(buf, file)
  local stat = uv.fs_lstat(file)
  if stat and stat.type ~= "file" then return false, "Invalid notes file" end
  local revision = stat and (stat.mtime.sec .. ":" .. stat.mtime.nsec .. ":" .. stat.size) or ""
  if revision ~= vim.b[buf].next_studio_notes_revision then return false, "Notes changed in another Neovim; save a copy before reopening" end
  local bytes = table.concat(api.nvim_buf_get_lines(buf, 0, -1, false), "\n") .. "\n"
  if #bytes > 1024 * 1024 then return false, "Notes exceed 1 MB" end
  local tmp = file .. ".tmp-" .. uv.os_getpid()
  local fd = uv.fs_open(tmp, "wx", 384)
  if not fd then return false, "Cannot write notes" end
  local count = uv.fs_write(fd, bytes, 0)
  uv.fs_fsync(fd)
  uv.fs_close(fd)
  if count ~= #bytes or not uv.fs_rename(tmp, file) then uv.fs_unlink(tmp); return false, "Cannot save notes" end
  stat = uv.fs_lstat(file)
  vim.b[buf].next_studio_notes_revision = stat.mtime.sec .. ":" .. stat.mtime.nsec .. ":" .. stat.size
  vim.bo[buf].modified = false
  return true
end

function M.save(buf)
  buf = buf or api.nvim_get_current_buf()
  if not api.nvim_buf_is_valid(buf) or vim.b[buf].next_studio_kind ~= "notes" or not vim.bo[buf].modified then return true end
  local file = path(vim.b[buf].next_studio_root)
  local lock = file .. ".lock"
  local fd = uv.fs_open(lock, "wx", 384)
  if not fd then return false, "Notes are busy in another Neovim; try saving again" end
  local ok, result, err = pcall(write, buf, file)
  uv.fs_close(fd)
  uv.fs_unlink(lock)
  if not ok then return false, "Could not save notes; the edited buffer is retained" end
  return result, err
end

function M.buffer(root)
  local buf = M.buffers[root]
  if buf and api.nvim_buf_is_valid(buf) then return buf end
  local file = path(root)
  local stat = uv.fs_lstat(file)
  assert(not stat or (stat.type == "file" and stat.size <= 1024 * 1024), "Invalid notes file")
  local lines = { "# Project Notes", "", "## Next", "", "- [ ] ", "", "## Notes", "" }
  if stat then
    local fd = assert(uv.fs_open(file, "r", 384))
    local text = uv.fs_read(fd, stat.size, 0)
    uv.fs_close(fd)
    lines = vim.split((text or ""):gsub("\n$", ""), "\n", { plain = true })
  end
  buf = api.nvim_create_buf(false, true)
  M.buffers[root] = buf
  api.nvim_buf_set_name(buf, "next-studio://notes/" .. vim.fn.sha256(root) .. "/Project Notes.md")
  vim.bo[buf].buftype, vim.bo[buf].bufhidden = "acwrite", "hide"
  vim.bo[buf].swapfile, vim.bo[buf].undofile, vim.bo[buf].modeline = false, false, false
  vim.bo[buf].filetype = "markdown"
  vim.b[buf].next_studio_kind, vim.b[buf].next_studio_root = "notes", root
  vim.b[buf].next_studio_notes_revision = stat and (stat.mtime.sec .. ":" .. stat.mtime.nsec .. ":" .. stat.size) or ""
  api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modified = false
  local function save()
    local ok, err = M.save(buf)
    if not ok then vim.notify("NEXT: " .. err, vim.log.levels.ERROR) end
  end
  api.nvim_create_autocmd({ "BufWriteCmd", "BufLeave" }, { buffer = buf, callback = save })
  return buf
end

function M.check()
  if vim.b.next_studio_kind ~= "notes" then vim.notify("NEXT: Select Project Notes first"); return end
  local line = api.nvim_get_current_line()
  if line:match("^%s*[-*] %[%s%]") then line = line:gsub("%[ %]", "[x]", 1)
  elseif line:match("^%s*[-*] %[[xX]%]") then line = line:gsub("%[[xX]%]", "[ ]", 1)
  else line = "- [ ] " .. line end
  api.nvim_set_current_line(line)
end

function M.setup()
  local group = api.nvim_create_augroup("NextStudioNotes", { clear = true })
  api.nvim_create_autocmd("VimLeavePre", { group = group, callback = function()
    for _, buf in pairs(M.buffers) do
      local ok, err = M.save(buf)
      if not ok then vim.notify("NEXT: " .. err, vim.log.levels.ERROR) end
    end
  end })
end

return M
