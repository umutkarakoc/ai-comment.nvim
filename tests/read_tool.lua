-- Run: nvim --headless -u NONE --cmd "set rtp+=/path/to/ai-comment.nvim" -l tests/read_tool.lua
local M = require("ai-comment")

local base = vim.fn.tempname()
vim.fn.mkdir(base, "p")
vim.fn.mkdir(base .. "/proj", "p")
local f1 = assert(io.open(base .. "/proj/a.txt", "w")); f1:write("hello"); f1:close()
local f2 = assert(io.open(base .. "/secret.txt", "w")); f2:write("sir"); f2:close()
vim.cmd("cd " .. base .. "/proj")

local function expect_err(r)
  assert(type(r) == "string" and r:find("^Error:"), "guard atladi: " .. tostring(r))
end

-- read_file guards
assert(M._read_file("a.txt") == "hello", "icine dosya okunamadi")
assert(M._read_file("./a.txt") == "hello", "./ okunamadi")
expect_err(M._read_file("../secret.txt"))
expect_err(M._read_file(base .. "/secret.txt"))
expect_err(M._read_file("/etc/passwd"))
expect_err(M._read_file("yok.txt"))

-- list_files
vim.fn.mkdir(base .. "/proj/src", "p")
vim.fn.writefile({ "x" }, base .. "/proj/src/main.rs")
local lr = M._list_files("src")
assert(type(lr) == "string" and lr:find("main.rs"), "list src calismadi: " .. tostring(lr))
local lr2 = M._list_files(".")
assert(type(lr2) == "string" and lr2:find("a.txt"), "list . calismadi: " .. tostring(lr2))
expect_err(M._list_files(".."))
expect_err(M._list_files("/etc"))
expect_err(M._list_files("yokdir"))

print("TUM GUARD TESTLERI GECTI")
