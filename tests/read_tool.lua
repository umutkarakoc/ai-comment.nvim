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

assert(M._read_file("a.txt") == "hello", "icine dosya okunamadi")
assert(M._read_file("./a.txt") == "hello", "./ okunamadi")
expect_err(M._read_file("../secret.txt"))  -- .. kacisi
expect_err(M._read_file(base .. "/secret.txt")) -- mutlak disari
expect_err(M._read_file("/etc/passwd"))     -- sistem dosyasi
expect_err(M._read_file("yok.txt"))         -- yok dosya
print("read_tool guard test: GECTI")
