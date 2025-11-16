local Buffer = require("glance.buffer")
local CommitView = require("glance.commit_view")
local LineBuffer = require('glance.line_buffer')

local M = {
	index = 1,
}

function M.get_logview_index()
	local index = M.index
	M.index = M.index + 1
	return index
end

local function add_sign(signs, index, name)
	signs[index] = name
end

local function add_highlight(highlights, line, from, to, name)
	table.insert(highlights, {
		line = line - 1,
		from = from,
		to = to,
		name = name
	})
end

local function get_table_size(t)
    local count = 0
    for _, __ in pairs(t) do
        count = count + 1
    end
    return count
end

function M:comparelist_find_commit(commit)
	for _,c in ipairs(self.comparelist) do
		if commit.message:find(c.message, 1, true) or c.message:find(commit.message, 1, true) then
			return c
		end
	end
	return nil
end

function M:comparelist_add_commit(commit)
	for _,c in ipairs(self.comparelist) do
		if c.hash == commit.hash then
			return
		end
	end
	table.insert(self.comparelist, commit)
end

function M:comparelist_delete_all()
	self.comparelist = {}
end

function M.new(headers, message, commits, comments)
	local name = "GlanceLog-" .. M.get_logview_index()

	if commits == nil then
		vim.notify("No commits to display", vim.log.levels.ERROR, {})
		return nil
	end

	local commit_start_line = 1
	if headers ~=nil then
		commit_start_line = commit_start_line + get_table_size(headers) + 1
	end
	if message ~= nil then
		commit_start_line = commit_start_line + #message + 1
	end
	local comment_start_line = commit_start_line + get_table_size(commits) + 1

	local instance = {
		name = name,
		headers = headers,
		message = message,
		commits = commits,
		commit_start_line = commit_start_line,
		comments = comments,
		comment_start_line = comment_start_line,
		text = {},
		comparelist = {},
		buffer = nil,
	}

	setmetatable(instance, { __index = M })

	return instance
end

function M:open_commit_view(commit)
	local opts = {diff_context = require("glance").config.diff_context}
	local view = CommitView.new(commit, opts)
	if (view == nil) then
		vim.notify("Bad commit: " .. commit, vim.log.levels.ERROR, {})
		return
	end
	view:open()
end

local function parse_upstream_commit_from_message(raw_info)
	local idx = 0

	local function advance()
		idx = idx + 1
		return raw_info[idx]
	end

	local line = advance()
	while line do
		if vim.startswith(line, "commit ") then
			commit_id = line:match("commit (%w+)")
			return commit_id
		end
		line = advance()
	end
	return nil
end

local function get_upstream_commit_by_subject(commit_id)
	local subject = vim.fn.systemlist("git log --format=%s -n 1 " .. commit_id)[1]
	local cmd = string.format("git rev-list --no-merges -P --grep='^\\Q%s\\E' -n 1 origin/master", subject)
	return vim.fn.systemlist(cmd)[1]
end

function M:get_compare_commit(commit)
	local commit_id = commit.hash
	local upstream_commit_id = parse_upstream_commit_from_message(vim.fn.systemlist("git log --format=%B -n 1 " .. commit_id))

	if upstream_commit_id == nil then
		upstream_commit_id = get_upstream_commit_by_subject(commit_id)
	end

	if upstream_commit_id == nil then
		local upstream_commit = self:comparelist_find_commit(commit)
		if upstream_commit then
			upstream_commit_id = upstream_commit.hash
		end
	end

	return upstream_commit_id
end

function M:open_parallel_views(commit)
	local commit_id = commit.hash
	local upstream_commit_id = self:get_compare_commit(commit)
	if upstream_commit_id == nil then
		vim.notify("Not a backport commit", vim.log.levels.ERROR, {})
		return
	end

	local opts = {diff_context = require("glance").config.diff_context}

	local view_left = CommitView.new(upstream_commit_id, opts)
	if (view_left == nil) then
		vim.notify("Bad commit: " .. upstream_commit_id, vim.log.levels.ERROR, {})
		return
	end
	local view_right = CommitView.new(commit_id, opts)
	if (view_right == nil) then
		vim.notify("Bad commit: " .. commit_id, vim.log.levels.ERROR, {})
		view_left:close()
		return
	end

	CommitView.sort_diffs_file(view_left, view_right)

	view_left:open({name = "Upstream: " .. upstream_commit_id})
	vim.cmd("wincmd o")
	vim.cmd(string.format("%d", view_left:get_first_hunk_line()))
	vim.cmd.normal("zz")
	vim.cmd("set scrollbind")

	view_right:open({name = "Backport: " .. commit_id})
	vim.cmd("wincmd L")
	vim.cmd(string.format("%d", view_right:get_first_hunk_line()))
	vim.cmd.normal("zz")
	vim.cmd("set scrollbind")

	view_left:set_scrollbind_view(view_right)
	view_right:set_scrollbind_view(view_left)
end

function M:open_patchdiff_view(commit)
	local commit_id = commit.hash
	local upstream_commit_id = self:get_compare_commit(commit)
	if upstream_commit_id == nil then
		vim.notify("Not a backport commit", vim.log.levels.ERROR, {})
		return nil
	end

	local opts = {patchdiff = require("glance").config.patchdiff}
	local view = CommitView.new_patchdiff(commit_id, upstream_commit_id, opts)
	if not view then return end
	view:open({filetype="GlancePatchDiff"})
end

function M:close()
	self.buffer:close()
	self.buffer = nil
	self.headers = nil
	self.message = nil
	self.commits = nil
	self.comments = nil
end

function M:update_one_commit(line, select)
	local commits = self.commits
	local commit_start_line = self.commit_start_line
	local index = line - commit_start_line + 1
	if index > #commits then
		vim.notify("Invalid commit index", vim.log.levels.ERROR, {})
		return
	end
	local commit = commits[index]
	local output = ""

	commit.in_comparelist = true

	if commit.remote == "" then
		output = string.sub(commit.hash, 1, 12) .. " " .. commit.message
	else
		output = string.sub(commit.hash, 1, 12) .. " (" .. commit.remote .. ") " .. commit.message
	end
	self.buffer:unlock()
	self.buffer:set_lines(line-1, line, false, {output})

	local from = 0
	local to = 12 -- length of abrev commit_id
	local hl_name = "GlanceLogCompareList"
	if select then
		hl_name = "GlanceLogSelect"
	end
	self.buffer:add_highlight(line-1, from, to, hl_name)
	from = to + 1
	if commit.remote ~= "" then
		to = from + #commit.remote + 2
		self.buffer:add_highlight(line-1, from, to, "GlanceLogRemote")
		from = to + 1
	end
	to = from + #commit.message
	self.buffer:add_highlight(line-1, from, to, "GlanceLogSubject")
	self.buffer:lock()
end

function M:comparelist_add_commit_range()
	local commit_start_line = self.commit_start_line
	local commit_count = get_table_size(self.commits)
	local vstart = vim.fn.getpos('v')
	local vend = vim.fn.getpos('.')
	local start_row = vstart[2]
	local end_row = vend[2]
	if start_row > end_row then
		start_row = end_row
		end_row = vstart[2]
	end
	if start_row < commit_start_line then
		start_row = commit_start_line
	end
	if end_row >= commit_start_line + commit_count then
		end_row = commit_start_line + commit_count - 1
	end
	if end_row < start_row then
		end_row = start_row
	end

	for i=start_row,end_row do
		local commit = self.commits[i]
		self:comparelist_add_commit(commit)
		self:update_one_commit(i)
	end
end

function M:create_buffer(uconfig)
	local commits = self.commits
	local commit_start_line = self.commit_start_line
	local commit_count = get_table_size(self.commits)
	local function do_list_parallel()
		local line = vim.fn.line '.'
		if line >= commit_start_line and line < commit_start_line + commit_count then
			line = line - commit_start_line + 1
			local commit = commits[line]
			self:open_parallel_views(commit)
			return
		end
		vim.notify("Not a commit", vim.log.levels.WARN)
	end
	local function do_patchdiff()
		local line = vim.fn.line '.'
		if line >= commit_start_line and line < commit_start_line + commit_count then
			line = line - commit_start_line + 1
			local commit = commits[line]
			self:open_patchdiff_view(commit)
			return
		end
		vim.notify("Not a commit", vim.log.levels.WARN)
	end
	local function do_batch_add_comparelist()
		self:comparelist_add_commit_range()
		vim.api.nvim_input("<ESC>")
	end
	local config = {
		name = self.name,
		filetype = "GlanceLog",
		bufhidden = "hide",
		mappings = {
			n = {
				["<c-s>"] = function()
					local line = vim.fn.line '.'
					if line < commit_start_line or line >= commit_start_line + commit_count then
						vim.notify("Not a commit", vim.log.levels.WARN)
						return
					end
					local index = line - commit_start_line + 1
					local commit = commits[index]
					self:comparelist_add_commit(commit)
					self:update_one_commit(line)
				end,
				["<enter>"] = function()
					local line = vim.fn.line '.'
					if line >= commit_start_line and line < commit_start_line + commit_count then
						line = line - commit_start_line + 1
						local commit = commits[line].hash
						self:open_commit_view(commit)
						return
					end
					vim.notify("Not a commit", vim.log.levels.WARN)
				end,
				["l"] = do_list_parallel,
				["2"] = do_list_parallel,
				["p"] = do_patchdiff,
				["e"] = do_patchdiff,
				["q"] = function()
					local glance = require("glance")
					if glance.config.q_quit_log == "off" then return end

					self:close()
				end
			},
			v = {
				["<c-s>"] = function()
					self:comparelist_add_commit_range()
					vim.api.nvim_input("<ESC>")
				end
			},
		},
	}

	config = vim.tbl_deep_extend("force", config, uconfig or {})
	local buffer = Buffer.create(config)
	if buffer == nil then
		return
	end
	vim.cmd("wincmd o")

	self.buffer = buffer
end

local function put_one_commit(output, highlights, commit)
	if commit.remote == "" then
		output:append(string.sub(commit.hash, 1, 12) .. " " .. commit.message)
	else
		output:append(string.sub(commit.hash, 1, 12) .. " (" .. commit.remote .. ") " .. commit.message)
	end

	local from = 0
	local to = 12 -- length of abrev commit_id
	local hl_name = "GlanceLogCommit"
	if commit.in_comparelist then
		hl_name = "GlanceLogCompareList"
	end
	add_highlight(highlights, #output, from, to, hl_name)
	from = to + 1
	if commit.remote ~= "" then
		to = from + #commit.remote + 2
		add_highlight(highlights, #output, from, to, "GlanceLogRemote")
		from = to + 1
	end
	to = from + #commit.message
	add_highlight(highlights, #output, from, to, "GlanceLogSubject")
end

-- each entry in headers table is a table of:
-- {line, sign, {{hl.name, from, to}, {hl.name, from, to}, ...}}
-- 
function M:put_log_contents(contents, output, highlights, signs)
	for _, e in pairs(contents) do
		local to = string.find(e.line, "\r", 1)
		if to then
			e.line = string.sub(e.line, 1, to - 1)
		end
		output:append(e.line)
		if e.sign ~= nil then
			add_sign(signs, #output, e.sign)
		elseif e.hls ~= nil then
			for _, hl in pairs(e.hls) do
				add_highlight(highlights, #output, hl.from, hl.to, hl.name)
			end
		end
	end
end

function M:put_log_message(output)
	for _, line in pairs(self.message) do
		local to = string.find(line, "\r", 1)
		if to then
			line = string.sub(line, 1, to - 1)
		end
		output:append("    " .. line)
	end
end

function M:open_buffer()
	local buffer = self.buffer
	if buffer == nil then
		return
	end

	local output = LineBuffer.new()
	local signs = {}
	local highlights = {}

	if self.headers then
		self:put_log_contents(self.headers, output, highlights, signs)
		output:append("---")
	end

	if self.message then
		self:put_log_message(output)
		output:append("---")
	end

	for _, commit in pairs(self.commits) do
		put_one_commit(output, highlights, commit)
	end
	output:append("---")

	if self.comments then
		self:put_log_contents(self.comments, output, highlights, signs)
	end

	buffer:replace_content_with(output)

	for line, name in pairs(signs) do
		buffer:place_sign(line, name, "hl")
	end

	for _, hi in ipairs(highlights) do
		buffer:add_highlight(hi.line, hi.from, hi.to, hi.name)
	end

	buffer:set_option("modifiable", false)
	buffer:set_option("readonly", true)

	vim.cmd("setlocal cursorline")

	M.buffer = buffer
	M.highlights = highlights
	vim.api.nvim_create_autocmd({"ColorScheme"}, {
		pattern = { "*" },
		callback = function()
			vim.cmd("syntax on")
		end,
	})
end

function M:open(config)
	self:create_buffer(config)
	if self.buffer == nil then
		return
	end

	self:open_buffer()
end

return M
