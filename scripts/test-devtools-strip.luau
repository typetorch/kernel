--!nocheck
-- 0.5.6: which frameworks' devtools leave the shared client tree. Runs the mount's own lines from the kernel source
-- against real Instances (from kernel/): `lune run scripts/test-devtools-strip.luau`

local fs = require("@lune/fs")
local luau = require("@lune/luau")
local process = require("@lune/process")
local roblox = require("@lune/roblox")
local Instance = roblox.Instance

local source = fs.readFile("src/server/Kernel.server.luau")
local from = assert(string.find(source, "local clientInclude = payload.include:Clone()", 1, true))
local to = assert(string.find(source, "payload.Client.Parent = clientTree", from, true))
local run = luau.load(`local payload, serverTree, clientTree = ...\n{string.sub(source, from, to - 1)}`, { debugName = "mount" })

local failed = 0
local function check(name, ok)
	print(`{if ok then "ok  " else "FAIL"}  {name}`)
	failed += if ok then 0 else 1
end

local function folder(name, parent)
	local made = Instance.new("Folder")
	made.Name = name
	made.Parent = parent
	return made
end

local function mount(devtools: { string }?)
	local payload = Instance.new("Model")
	local include = folder("include", payload)
	if devtools then
		local out = folder("out", folder("framework", folder("@typetorch", folder("node_modules", include))))
		local dir = folder("devtools", out)
		for _, name in devtools do
			local module = Instance.new("ModuleScript")
			module.Name = name
			module.Parent = dir
		end
	end
	local serverTree, clientTree = folder("server"), folder("client")
	run(payload, serverTree, clientTree)
	local client = clientTree.include:FindFirstChild("node_modules")
	for _, part in { "@typetorch", "framework", "out" } do
		client = client and client:FindFirstChild(part)
	end
	return payload, serverTree, clientTree, client
end

do
	local payload, serverTree, clientTree, out = mount({ "client", "on-demand" })
	check("on-demand framework: gone from the client tree", out:FindFirstChild("devtools") == nil)
	check("on-demand framework: the framework's other modules stay", out ~= nil)
	check("on-demand framework: still in the payload for the server tree", payload.include.node_modules["@typetorch"].framework.out:FindFirstChild("devtools") ~= nil)
	check("on-demand framework: both trees flagged", serverTree:GetAttribute("DevtoolsOnDemand") == true and clientTree:GetAttribute("DevtoolsOnDemand") == true)
end
do
	local _, serverTree, clientTree, out = mount({ "client" })
	check("older framework: stays in the client tree", out:FindFirstChild("devtools") ~= nil)
	check("older framework: no flag", serverTree:GetAttribute("DevtoolsOnDemand") == nil and clientTree:GetAttribute("DevtoolsOnDemand") == nil)
end
do
	local _, _, clientTree = mount(nil)
	check("a game without the framework mounts", clientTree:FindFirstChild("include") ~= nil and clientTree:GetAttribute("DevtoolsOnDemand") == nil)
end

if failed > 0 then
	process.exit(1)
end
