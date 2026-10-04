--!nonstrict
-- Template, shipped disabled. The kernel clones it once per generation, points `Root` at the mounted server tree and
-- `Kernel` at the Api module, parents the clone to ServerScriptService.TypeTorchEntries and enables it. Everything the
-- generation runs starts from this script, so disabling the clone is the hard stop (spike S5).

local root = script:WaitForChild("Root").Value
local Api = require(script:WaitForChild("Kernel").Value)
local kernel = Api.forEntry(script)

local ok, err = pcall(function()
	local boot = require(root:WaitForChild("Server"):WaitForChild("boot"))
	local stop = boot.boot(kernel)
	assert(typeof(stop) == "function", "Server.boot.boot(kernel) must return a stop function")
	kernel.ready(stop)
end)
if not ok then
	kernel.failed(tostring(err))
end
