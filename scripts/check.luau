-- Syntax check for every kernel Luau file: `lune run scripts/check.luau` (from kernel/; Lune is pinned in rokit.toml).
-- Compiles each file with Lune's Luau compiler (no type check, no Roblox API): catches parse errors before a place
-- publish, since a kernel bug can only be fixed with a restart.

local fs = require("@lune/fs")
local luau = require("@lune/luau")
local process = require("@lune/process")

local failures = 0
local checked = 0

local function walk(path: string)
	for _, name in fs.readDir(path) do
		local child = `{path}/{name}`
		if fs.isDir(child) then
			walk(child)
		elseif string.sub(name, -5) == ".luau" or string.sub(name, -4) == ".lua" then
			checked += 1
			local ok, err = pcall(luau.compile, fs.readFile(child))
			if ok then
				print(`ok    {child}`)
			else
				failures += 1
				print(`FAIL  {child}\n      {string.split(tostring(err), "\n")[1]}`)
			end
		end
	end
end

local roots = if #process.args > 0 then process.args else { "src", "scripts" }
for _, root in roots do
	walk(root)
end
print(`{checked} files, {failures} failed`)
process.exit(if failures == 0 and checked > 0 then 0 else 1)
