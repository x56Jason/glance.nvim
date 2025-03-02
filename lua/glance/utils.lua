local M = {}

function M.parse_git_log(cmd)
	local output = vim.fn.systemlist(cmd)
	local output_len = #output
	local commits = {}

	for i=1,output_len do
		local hash, rest = output[i]:match("([a-zA-Z0-9]+) (.*)")
		if hash ~= nil then
			local remote, message = rest:match("^%((.+)%) (.*)")
			if remote == nil then
				message = rest
			end

			local commit = {
				hash = hash,
				remote = remote or "",
				message = message
			}
			table.insert(commits, commit)
		end
	end

	return commits
end

return M
