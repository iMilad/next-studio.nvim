local M = { projects = {} }
local api = vim.api

function M.start(root, item)
  assert(type(item.cmd) == "string" or type(item.cmd) == "table", "Task needs an explicit command")
  assert(item.name == nil or (type(item.name) == "string" and #item.name <= 80 and not item.name:find("[%z\1-\31\127]")), "Use a short task name")
  local studio, layout = require("next_studio"), require("next_studio.layout")
  studio.prepare("start task")
  local win = layout.new(root, "horizontal")
  local buf = api.nvim_get_current_buf()
  local shell = vim.o.shell
  local name = vim.fs.basename(shell)
  local command = item.cmd
  if type(command) == "string" then
    command = name == "zsh" and { shell, "-f", "-c", command }
      or name == "bash" and { shell, "--noprofile", "--norc", "-c", command }
      or { shell, "-c", command }
  end
  local task = { name = item.name or "Task", cmd = item.cmd, buf = buf, root = root }
  M.projects[root] = M.projects[root] or {}
  M.projects[root][#M.projects[root] + 1] = task
  task.job = vim.fn.jobstart(command, { term = true, cwd = root, on_exit = function(_, code)
    task.code = code
  end })
  vim.b[buf].next_studio_kind, vim.b[buf].next_studio_root, vim.b[buf].next_studio_task = "terminal", root, true
  vim.bo[buf].bufhidden = "hide"
  for _, key in ipairs({ "h", "j", "k", "l" }) do
    vim.keymap.set("t", "<C-" .. key .. ">", "<C-\\><C-n><C-w>" .. key, { buffer = buf, silent = true })
  end
  vim.keymap.set("t", "<Esc><Esc>", "<C-\\><C-n>", { buffer = buf, silent = true })
  studio.bind_terminal_keys(buf)
  layout.title(win, task.name)
  if task.job <= 0 then vim.notify("NEXT: Task could not start", vim.log.levels.ERROR) end
  return task
end

function M.pick(root)
  local choices = { { name = "+ Run a command", add = true } }
  local configured = require("next_studio.config").options.tasks
  if type(configured) == "function" then configured = configured(root) end
  for _, item in ipairs(configured or {}) do choices[#choices + 1] = { name = item.name or "Configured task", definition = item } end
  for _, task in ipairs(M.projects[root] or {}) do
    choices[#choices + 1] = { name = task.name .. (vim.fn.jobwait({ task.job }, 0)[1] == -1 and " · running" or " · exited " .. (task.code or "?")), task = task }
  end
  local tab = api.nvim_get_current_tabpage()
  local function current() return api.nvim_get_current_tabpage() == tab and require("next_studio").current() and require("next_studio").current().root == root end
  vim.ui.select(choices, { prompt = "NEXT / Project commands", format_item = function(item) return item.name end }, function(item)
    if not item or not current() then return end
    if item.add then
      vim.ui.input({ prompt = "Run in this project: " }, function(command)
        if not command or command == "" or not current() then return end
        vim.ui.input({ prompt = "Task name: ", default = "Task" }, function(name)
          if name and current() then vim.schedule(function() if current() then M.start(root, { name = name, cmd = command }) end end) end
        end)
      end)
    elseif item.definition then
      vim.schedule(function() if current() then M.start(root, item.definition) end end)
    else
      vim.ui.select({ "Show output", "Run again", "Stop" }, { prompt = item.task.name }, function(action)
        if not action or not current() then return end
        vim.schedule(function()
          if not current() then return end
          if action == "Stop" then vim.fn.jobstop(item.task.job)
          elseif action == "Run again" then M.start(root, item.task)
          elseif api.nvim_buf_is_valid(item.task.buf) then
            for _, win in ipairs(vim.fn.win_findbuf(item.task.buf)) do
              if api.nvim_win_get_tabpage(win) == tab then api.nvim_set_current_win(win); return end
            end
            require("next_studio").prepare("show task output")
            require("next_studio.layout").new(root, "horizontal")
            api.nvim_win_set_buf(0, item.task.buf)
            require("next_studio.layout").title(api.nvim_get_current_win(), item.task.name)
          end
        end)
      end)
    end
  end)
end

return M
