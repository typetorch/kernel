--!nonstrict
-- Template, shipped disabled. The kernel client clones it into PlayerScripts once per client generation and enables
-- it; disabling the clone is the client hard stop (spike S4/S5).

local root = script:WaitForChild("Root").Value
local ClientApi = require(script:WaitForChild("Kernel").Value)
local kernel = ClientApi.forEntry(script)

local ok, err = pcall(function()
	local boot = require(root:WaitForChild("Client"):WaitForChild("boot"))
	local stop = boot.boot(kernel)
	assert(typeof(stop) == "function", "Client.boot.boot(kernel) must return a stop function")
	kernel.ready(stop)
end)
if not ok then
	kernel.failed(tostring(err))
end
