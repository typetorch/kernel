--!nonstrict
-- TypeTorch loader, client half (kernel 0.4.1; plans/22): ReplicatedFirst.TypeTorchLoaderClient, baked into the place
-- with the loader. ReplicatedFirst replicates ONCE, at join (kernel 0.3.9), so:
--   * a player who joins after the loader installed the kernel already has ReplicatedFirst.TypeTorchKernelClient
--     (enabled): it runs by itself and draws the holding screen;
--   * a player who joins while the loader still works (it has up to 4 s) gets only this script: it covers the place at
--     once, waits for the late copy the loader leaves in ReplicatedStorage (TypeTorchKernelClientLate), and runs that
--     copy from PlayerScripts.
-- Either way this script's own screen comes down when the kernel client runs (its ClientReady / Holding attributes,
-- 0.3.8) or after 60 s. No emojis, a UIScale pop (the user's UI rules).

local Players = game:GetService("Players")
local ReplicatedFirst = game:GetService("ReplicatedFirst")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local player = Players.LocalPlayer
local LATE_CLIENT = "TypeTorchKernelClientLate"
local GIVE_UP = 60

-- The screen: an opaque backdrop and one word, above the game's UI (the kernel client's own screen replaces it).
local gui = Instance.new("ScreenGui")
gui.Name = "TypeTorchLoaderScreen"
gui.IgnoreGuiInset = true
gui.ResetOnSpawn = false
gui.DisplayOrder = 1_000_000
local backdrop = Instance.new("Frame")
backdrop.Size = UDim2.fromScale(1, 1)
backdrop.BackgroundColor3 = Color3.fromRGB(16, 17, 20)
backdrop.BorderSizePixel = 0
backdrop.Parent = gui
local label = Instance.new("TextLabel")
label.AnchorPoint = Vector2.new(0.5, 0.5)
label.Position = UDim2.fromScale(0.5, 0.5)
label.Size = UDim2.fromScale(0.6, 0.08)
label.BackgroundTransparency = 1
label.Text = "Starting..."
label.TextScaled = true
label.Font = Enum.Font.GothamMedium
label.TextColor3 = Color3.fromRGB(235, 235, 240)
label.Parent = backdrop
local scale = Instance.new("UIScale")
scale.Scale = 0.9
scale.Parent = label
pcall(function()
	gui.Parent = player:WaitForChild("PlayerGui")
	TweenService:Create(scale, TweenInfo.new(0.25, Enum.EasingStyle.Back, Enum.EasingDirection.Out), { Scale = 1 }):Play()
end)

local function running(client): boolean
	return client ~= nil and (client:GetAttribute("ClientReady") == true or client:GetAttribute("Holding") ~= nil or client:GetAttribute("HoldReason") ~= nil)
end

local deadline = os.clock() + GIVE_UP
-- The kernel client that came with ReplicatedFirst at join (all of ReplicatedFirst arrives together).
local client = ReplicatedFirst:FindFirstChild("TypeTorchKernelClient") or ReplicatedFirst:WaitForChild("TypeTorchKernelClient", 1)
if client == nil then
	-- Joined before the loader finished: run the late copy from PlayerScripts.
	local late = ReplicatedStorage:WaitForChild(LATE_CLIENT, GIVE_UP)
	if late then
		local copy = late:Clone()
		copy.Name = "TypeTorchKernelClient"
		copy.Disabled = false
		local ok = pcall(function()
			copy.Parent = player:WaitForChild("PlayerScripts")
		end)
		client = if ok then copy else nil
	end
end
while not running(client) and os.clock() < deadline do
	task.wait(0.1)
end
pcall(function()
	local out = TweenService:Create(scale, TweenInfo.new(0.15, Enum.EasingStyle.Quad, Enum.EasingDirection.In), { Scale = 0.9 })
	out:Play()
	out.Completed:Wait()
end)
gui:Destroy()
