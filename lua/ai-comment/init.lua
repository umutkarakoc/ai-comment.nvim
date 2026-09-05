-- ai-comment: edit files by writing comments
--   "comment ai!": apply an AI edit to the file
--   "comment ai?": ask the AI, answer is inserted as a comment below
--
-- Requires: OPENROUTER_API_KEY

local M = {}

M.config = {
	model = vim.env.AI_COMMENT_MODEL or "deepseek/deepseek-v4-flash",
	url = vim.env.AI_COMMENT_URL or "https://openrouter.ai/api/v1/chat/completions",
	-- key priority: OPENAI_API_KEY, then OPENROUTER_API_KEY
	api_key = vim.env.OPENAI_API_KEY or vim.env.OPENROUTER_API_KEY,
	max_tokens = 16384,
	-- markers; customize if ai!/ai? clash with your language
	edit_marker = "ai!", -- apply an AI edit
	ask_marker = "ai?", -- ask the AI, answer inserted below
	history_size = 10, -- conversation turns kept per buffer
	read_tool = true, -- let the AI read files inside the project dir (cwd)
	read_tool_max_bytes = 100000, -- per-file size limit for read_tool
	read_tool_budget = 300000, -- max total bytes read per request
	max_reads = 6, -- max total read_file/list_files calls per request
	max_tool_rounds = 50, -- max tool-call rounds per request
}

-- Per-request read budget (bytes consumed by read_file this request).
local read_budget_used = 0
local reads_used = 0

-- Per-buffer conversation history: { [bufnr] = { { role, content }, ... } }
local history = {}

-- Returns the history for a buffer (current by default)
function M.history(bufnr)
	local h = history[bufnr or vim.api.nvim_get_current_buf()]
	return h or {}
end

-- ================= helpers =================

-- Notify. Always auto-dismisses (no persistent toasts).
local function notify(msg, level)
	vim.notify(msg, level or vim.log.levels.INFO)
end

-- Sign shown in the sign column while a request is in flight
local SIGN_NAME = "AICommentWorking"
local current_sign = nil
vim.fn.sign_define(SIGN_NAME, { text = "⏳", texthl = "DiagnosticInfo" })

local function sign_show()
	local buf = vim.api.nvim_get_current_buf()
	local lnum = vim.fn.line(".")
	current_sign = vim.fn.sign_place(0, "AICommentGroup", SIGN_NAME, buf, { lnum = lnum })
end

local function sign_hide()
	local ok = pcall(function()
		if current_sign then
			vim.fn.sign_unplace("AICommentGroup", { id = current_sign })
			current_sign = nil
		end
	end)
	if not ok then
		current_sign = nil
	end
end

local function current_line()
	return vim.api.nvim_get_current_line()
end

-- Escape Lua pattern magic chars so markers like '?' work literally
local function escape_pattern(s)
	return (s:gsub("[%^%$%(%)%%%.%[%]%*%+%-%?]", "%%%1"))
end

local function is_marker(marker)
	return current_line():find(escape_pattern(marker) .. "%s*$") ~= nil
end

local function extract_instruction(marker)
	local line = current_line()
	-- strip the comment sigil (// # -- /* * <!-- etc.)
	local instr = line:gsub("^%s*[/#%*%-%s;%[%]]*", "")
	instr = instr:gsub("%s*" .. escape_pattern(marker) .. "%s*$", "")
	return instr:gsub("^%s+", ""):gsub("%s+$", "")
end

local function file_content()
	return table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), "\n")
end

-- Returns the git diff for the buffer if it lives in a repo and has changes.
local function git_diff_for(bufnr)
	local path = vim.api.nvim_buf_get_name(bufnr)
	if path == "" then
		return nil
	end
	local cwd = vim.fn.getcwd()
	local ok, res = pcall(vim.system, { "git", "-C", cwd, "diff", "--", path }, { text = true })
	if not ok then
		return nil
	end
	if res.code ~= 0 then
		return nil
	end
	local diff = res.stdout
	if diff == "" then
		return nil
	end
	return diff
end

local function strip_fences(text)
	if text:match("^%s*```") then
		text = text:gsub("^%s*```[%w+-]*%s*\n?", "")
		text = text:gsub("```%s*$", "")
	end
	return text
end

-- ================= request =================

-- Project-relative path of the buffer (nil if unnamed). Falls back to the
-- absolute path when the file lives outside the current dir.
local function buffer_relpath(bufnr)
	local path = vim.api.nvim_buf_get_name(bufnr)
	if path == "" then
		return nil
	end
	local cwd_real = vim.fn.resolve(vim.fn.getcwd())
	local real = vim.fn.resolve(path)
	local prefix = cwd_real == "/" and "/" or cwd_real .. "/"
	if real:sub(1, #prefix) == prefix then
		return real:sub(#prefix + 1)
	end
	return real
end

-- Tool the model can call to read files inside the project directory.
local READ_TOOL = {
	type = "function",
	["function"] = {
		name = "read_file",
		description = "Read a file inside the project directory. Use it to inspect related files before editing or answering. "
			.. "The path is relative to the project root (e.g. src/main.rs).",
		parameters = {
			type = "object",
			properties = {
				path = {
					type = "string",
					description = "Path relative to the project root, or absolute (only files inside the project work).",
				},
			},
			required = { "path" },
		},
	},
}

-- Tool the model can call to list a directory (like `ls`).
local LIST_TOOL = {
	type = "function",
	["function"] = {
		name = "list_files",
		description = "List files and subdirectories inside the project directory. Useful to explore the codebase "
			.. "before choosing what to read. The path is a directory relative to the project root (e.g. src).",
		parameters = {
			type = "object",
			properties = {
				path = {
					type = "string",
					description = "Directory path relative to the project root; empty string or '.' lists the project root.",
				},
			},
			required = { "path" },
		},
	},
}

TOOLS = { READ_TOOL, LIST_TOOL }

-- Resolve path inside project; returns real path or nil + error string.
-- Shared guard for read/list: never let the model escape cwd.
local function resolve_in_project(path)
	if type(path) ~= "string" then
		return nil, "path must be a string"
	end
	local cwd = vim.fn.getcwd()
	local cwd_real = vim.fn.resolve(cwd)
	local full = path == "" and cwd or (path:sub(1, 1) == "/" and path or cwd .. "/" .. path)
	local real = vim.fn.resolve(full)
	local prefix = cwd_real == "/" and "/" or cwd_real .. "/"
	if real ~= cwd_real and real:sub(1, #prefix) ~= prefix then
		return nil, "path escapes the project directory: " .. real
	end
	return real
end

-- Read a file, but only if the resolved (symlinks, `..`) path stays inside
-- the project dir. Trust boundary: never let the model read outside cwd.
local function read_project_file(path)
	if path == "" then
		return "Error: 'path' must be a non-empty string"
	end
	local real, perr = resolve_in_project(path)
	if not real then
		return "Error: " .. perr
	end
	if vim.fn.filereadable(real) == 0 then
		return "Error: file not found: " .. path .. ". Use list_files to find the correct path."
	end
	local size = vim.fn.getfsize(real)
	if size > M.config.read_tool_max_bytes then
		return string.format("Error: file too large (%d bytes, limit %d)", size, M.config.read_tool_max_bytes)
	end
	if read_budget_used + size > M.config.read_tool_budget then
		return string.format(
			"Error: read budget exceeded (%d/%d bytes). Read fewer files; only what is strictly needed.",
			read_budget_used,
			M.config.read_tool_budget
		)
	end
	read_budget_used = read_budget_used + size
	local f = io.open(real, "rb")
	if not f then
		return "Error: cannot open file: " .. path .. " (permissions?)"
	end
	local content = f:read("*a")
	f:close()
	return content
end

-- List a directory inside the project (like `ls`). Cap the number of entries.
local function list_project_files(path)
	local real, perr = resolve_in_project(path == "" and "." or path)
	if not real then
		return "Error: " .. perr
	end
	if vim.fn.isdirectory(real) == 0 then
		return "Error: not a directory: " .. path .. ". Use list_files with a directory, or read_file for a file."
	end
	local entries = vim.fn.readdir(real)
	if #entries > 200 then
		entries = vim.list_slice(entries, 1, 200)
		entries[#entries + 1] = "... (truncated, " .. "too many entries)"
	end
	table.sort(entries)
	return table.concat(entries, "\n")
end

-- Runs one tool call; always returns a string the model can read.
local function execute_tool(tc)
	if not (tc and tc["function"] and tc["function"].name) then
		return "Error: unsupported tool call"
	end
	local ok, args = pcall(vim.json.decode, tc["function"].arguments or "{}")
	if not ok or type(args) ~= "table" then
		return "Error: invalid tool arguments"
	end
	local name = tc["function"].name
	if name == "read_file" or name == "list_files" then
		if reads_used >= M.config.max_reads then
			return string.format(
				"Error: read limit reached (%d/%d calls). Do not call read/list again; finish with what you have.",
				reads_used,
				M.config.max_reads
			)
		end
		reads_used = reads_used + 1
	end
	if name == "read_file" then
		local res = read_project_file(args.path)
		notify(string.format("read_file: %s (%d bytes)", tostring(args.path), #tostring(res)))
		return res
	elseif name == "list_files" then
		local res = list_project_files(args.path)
		local n = #vim.split(res, "\n", { plain = true })
		notify(string.format("list_files: %s (%d entries)", tostring(args.path), n))
		return res
	end
	return "Error: unsupported tool call"
end

local function send_payload(payload, cb)
	local tmp = vim.fn.tempname()
	local f = assert(io.open(tmp, "w"))
	f:write(vim.json.encode(payload))
	f:close()

	local cmd = {
		"curl",
		"-s",
		"--max-time",
		"120",
		"-X",
		"POST",
		M.config.url,
		"-H",
		"Content-Type: application/json",
		"-H",
		"Authorization: Bearer " .. M.config.api_key,
		"--data-binary",
		"@" .. tmp,
	}
	vim.system(cmd, { text = true }, function(res)
		-- vim.system callbacks run in a fast-event context where vim.fn.* is
		-- forbidden; schedule to the main loop before touching any of it.
		vim.schedule(function()
			os.remove(tmp)
			if res.code ~= 0 then
				cb(nil, "curl error: " .. (res.stderr or "exit " .. tostring(res.code)))
				return
			end
			local ok, data = pcall(vim.json.decode, res.stdout)
			if not ok then
				cb(nil, "JSON parse error: " .. res.stdout:sub(1, 300))
				return
			end
			if data.error then
				cb(nil, "API error: " .. (data.error.message or data.error))
				return
			end
			cb(data)
		end)
	end)
end
local function build_payload(instruction, code, filetype, diff, mode, bufnr)
	mode = mode or "edit"
	local rel = buffer_relpath(bufnr)
	local where_hint = "The current working file is "
		.. (rel and ("'" .. rel .. "'") or "(an unsaved new buffer)")
		.. ". "
	if M.config.read_tool then
		where_hint = where_hint
			.. "You can read files in the project with the read_file tool (paths relative to the project root). "
	end
	local system
	if mode == "ask" then
		system = "You are an expert programmer. The user asks a question as a comment. "
			.. "Answer the question concisely and accurately. "
			.. "Comment can be multiline."
			.. "Keep tool calls minimal, only read files if needed. "
			.. "If the question is about the current file, reference it. "
			.. "Reply with ONLY the answer text, no markdown fences, no preamble. "
			.. "Short answers preferred (under 10 lines unless asked for detail). "
			.. where_hint
	else
		system = "You are an expert code editor working interactively on one file. "
			.. "The user gives an instruction as a comment. "
			.. "Comment can be multiline."
			.. "Keep tool calls minimal, only read files if needed. "
			.. "You already had previous edit conversations on this file (given in history). "
			.. "Apply the new instruction by editing the file. "
			.. "Reply with ONLY the complete edited file content, no explanations, no markdown fences. "
			.. "Remove the instruction comment lines itself after applying the edit. "
			.. "Preserve everything else exactly as-is (whitespace, comments, formatting). "
			.. where_hint
	end

	if M.config.read_tool then
		system = system
			.. ("\n\nHARD LIMIT: you have at most %d total read_file/list_files calls for this entire task. "):format(M.config.max_reads)
			.. "Read as FEW files as possible: only what is strictly needed for the instruction. "
			.. "The task almost always needs ZERO or ONE read. "
			.. "If the instruction makes you implement, override, or use a type/function/trait imported or defined in another file"
			.. " (you only see its import line, not its body), you MUST call read_file on that one definition before editing; "
			.. "then STOP reading. Never read files just to explore, "
			.. "never read siblings, tests, or related modules unless the instruction explicitly requires them. "
			.. "Never guess the shape of an API you have not read. "
			.. "Repeated tool calls that add little information are a failure: after 1-2 reads, produce the edit or answer."
	end

	local history_msgs = {}
	for _, m in ipairs(M.history()) do
		table.insert(history_msgs, { role = m.role, content = m.content })
	end

	-- Send the diff when available, otherwise the full file.
	local context
	if diff then
		context = ("File type: %s\n\n(History of previous edits follows.)\n\nCurrent uncommitted changes (git diff):\n```diff\n%s\n```\n\nFull file for reference (only if you need to see unchanged code):\n```\n%s\n```"):format(
			filetype,
			diff,
			code
		)
	else
		context = ("File type: %s\n\n(History of previous edits on this file follows.)\n\nInstruction: %s\n\nCurrent file:\n```\n%s\n```"):format(
			filetype,
			instruction,
			code
		)
	end

	local user = ("%s: %s\n\n%s"):format(mode == "ask" and "Question" or "Instruction", instruction, context)

	-- OpenRouter: fastest provider wins. Skipped for other providers.
	local payload = {
		model = M.config.model,
		messages = vim.list_extend(
			{ { role = "system", content = system } },
			vim.list_extend(history_msgs, {
				{ role = "user", content = user },
			})
		),
		temperature = 0.1,
		max_tokens = M.config.max_tokens,
	}
	if M.config.url:find("openrouter") then
		payload.provider = { sort = "latency" }
	end
	if M.config.read_tool then
		payload.tools = TOOLS
	end
	return payload
end

local function request_edit(instruction, code, filetype, bufnr, diff, mode, cb)
	if not M.config.api_key then
		vim.notify("OPENAI_API_KEY or OPENROUTER_API_KEY not set", vim.log.levels.ERROR)
		return
	end

	-- Temporarily switch to the target buffer so history() reads the right one
	local old_buf = vim.api.nvim_get_current_buf()
	vim.api.nvim_set_current_buf(bufnr)
	local ok_payload, payload = pcall(build_payload, instruction, code, filetype, diff, mode, bufnr)
	vim.api.nvim_set_current_buf(old_buf)
	if not ok_payload then
		cb(nil, "failed to build payload: " .. tostring(payload))
		return
	end

	-- Loop: resolve model tool calls, then resend, until it answers.
	-- ponytail: cap at 3 tool rounds; local file reads are fast.
	local rounds = 0
	read_budget_used = 0 -- reset per-request read budget
	reads_used = 0 -- reset per-request read count
	local function send()
		send_payload(payload, function(data, err)
			if err then
				cb(nil, err)
				return
			end
			local choice = data.choices and data.choices[1]
			local msg = choice and choice.message
			if choice and choice.finish_reason == "length" then
				cb(
					nil,
					"response truncated (max_tokens reached). File NOT modified. Split the request into smaller steps or raise max_tokens."
				)
				return
			end
			if msg and msg.tool_calls and #msg.tool_calls > 0 and M.config.read_tool then
				rounds = rounds + 1
				if rounds >= M.config.max_tool_rounds then
					cb(nil, "too many tool rounds, giving up")
					return
				end
				table.insert(
					payload.messages,
					{ role = "assistant", content = msg.content or "", tool_calls = msg.tool_calls }
				)
				for _, tc in ipairs(msg.tool_calls) do
					table.insert(payload.messages, { role = "tool", tool_call_id = tc.id, content = execute_tool(tc) })
				end
				send()
				return
			end
			-- some reasoning models return the answer in reasoning_content
			local content = msg and (msg.content or msg.reasoning_content)
			if not content then
				cb(nil, "empty response")
				return
			end
			cb(content)
		end)
	end
	send()
end

-- ================= apply =================

local function apply_edit(new_content)
	local new_lines = vim.split(strip_fences(new_content), "\n", { plain = true })
	-- drop a single trailing empty line (file-ending newline)
	if #new_lines > 1 and new_lines[#new_lines] == "" then
		table.remove(new_lines)
	end

	local old_count = vim.api.nvim_buf_line_count(0)
	local new_count = #new_lines
	if new_count < old_count * 0.5 then
		vim.notify(
			string.format("Suspiciously short response (%d -> %d lines). Not applied.", old_count, new_count),
			vim.log.levels.WARN
		)
		return
	end

	vim.api.nvim_buf_set_lines(0, 0, -1, false, new_lines)
	notify(
		string.format("%s applied: %d -> %d lines (undo with u)", M.config.edit_marker, old_count, new_count),
		vim.log.levels.INFO
	)
end

-- Comment sigil per filetype for the answer lines
local function comment_prefix(ft)
	if ft == "lua" then
		return "--"
	elseif ft == "python" then
		return "#"
	elseif ft == "sh" or ft == "bash" or ft == "fish" or ft == "yaml" or ft == "toml" then
		return "#"
	elseif ft == "sql" then
		return "--"
	elseif ft == "haskell" then
		return "--"
	elseif ft == "elixir" then
		return "#"
	elseif ft == "ruby" then
		return "#"
	elseif ft == "vim" then
		return '"'
	elseif ft == "html" or ft == "xml" or ft == "vue" then
		return "<!--"
	else
		return "//"
	end -- c, cpp, rust, go, js, ts, java
end

-- Insert the AI answer as comment lines right below the ask-marker line
local function apply_answer(answer, bufnr)
	local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
	local prefix = comment_prefix(vim.bo[bufnr].filetype or "")

	local ans_lines = vim.split(strip_fences(answer), "\n", { plain = true })
	if #ans_lines > 1 and ans_lines[#ans_lines] == "" then
		table.remove(ans_lines)
	end
	local comment_lines = {}
	for _, l in ipairs(ans_lines) do
		if l ~= "" then
			table.insert(comment_lines, prefix .. " " .. l)
		end
	end

	-- find the line ending with the ask marker
	local insert_at = -1
	for i, l in ipairs(lines) do
		if l:find(escape_pattern(M.config.ask_marker) .. "%s*$") then
			insert_at = i
			break
		end
	end
	if insert_at < 0 then
		insert_at = vim.api.nvim_win_get_cursor(0)[1]
	end

	vim.api.nvim_buf_set_lines(bufnr, insert_at, insert_at, false, comment_lines)
	notify(M.config.ask_marker .. " answer added (" .. #comment_lines .. " lines)", vim.log.levels.INFO)
end

-- ================= run =================

function M.run()
	local mode = is_marker(M.config.ask_marker) and "ask" or (is_marker(M.config.edit_marker) and "edit" or nil)
	if not mode then
		vim.notify(
			string.format(
				"Line must end with '%s' (edit) or '%s' (question)",
				M.config.edit_marker,
				M.config.ask_marker
			),
			vim.log.levels.WARN
		)
		return
	end
	local marker = mode == "ask" and M.config.ask_marker or M.config.edit_marker
	local instruction = extract_instruction(marker)
	if instruction == "" then
		vim.notify("Empty instruction", vim.log.levels.WARN)
		return
	end
	local code = file_content()
	if #code > 200000 then
		vim.notify("File too large (200KB+), not supported", vim.log.levels.ERROR)
		return
	end

	local ft = vim.bo.filetype ~= "" and vim.bo.filetype or vim.fn.expand("%:e")
	notify(marker .. " working: " .. instruction)
	sign_show()
	local bufnr = vim.api.nvim_get_current_buf()

	local diff = git_diff_for(bufnr)
	if diff then
		notify(marker .. " diff context found (" .. #diff .. " bytes)")
	end

	local history_msgs = M.history(bufnr)
	request_edit(instruction, code, ft, bufnr, diff, mode, function(content, err)
		if err then
			vim.schedule(function()
				sign_hide()
				notify(marker .. " error: " .. err, vim.log.levels.ERROR)
			end)
			return
		end
		vim.schedule(function()
			sign_hide()
			if mode == "ask" then
				apply_answer(content, bufnr)
			else
				apply_edit(content)
			end

			table.insert(history_msgs, { role = "user", content = instruction })
			table.insert(history_msgs, { role = "assistant", content = content })
			local max = M.config.history_size
			if #history_msgs > max * 2 then
				for _ = 1, #history_msgs - max * 2 do
					table.remove(history_msgs, 1)
				end
			end
			history[bufnr] = history_msgs
		end)
	end)
end

-- ================= setup =================

function M.setup(opts)
	M.config = vim.tbl_extend("force", M.config, opts or {})

	vim.api.nvim_create_user_command("AIComment", M.run, { desc = "Apply edit/ask marker on current line" })

	-- auto-trigger when the user leaves insert mode on a marker line
	vim.api.nvim_create_autocmd("InsertLeave", {
		group = vim.api.nvim_create_augroup("ai_comment", { clear = true }),
		callback = function()
			if is_marker(M.config.edit_marker) or is_marker(M.config.ask_marker) then
				vim.schedule(function()
					M.run()
				end)
			end
		end,
	})
end

-- Tool-call test hooks (internal)
M._read_file = read_project_file
M._list_files = list_project_files
M._reads_reset = function() reads_used = 0 end
M._execute_tool = execute_tool
M._set_max_reads = function(n) M.config.max_reads = n end

return M
