--!strict
--[[
	HUDService.luau
	Purpose: Drives the Quake-style HUD authored in StarterGui/QuakeHUD
	(src/assets/QuakeHUD.model.json): health, speed (ups) and the keystroke
	overlay. The GUI is a real instance tree shipped with the place - this
	service only binds data to it and never constructs UI at runtime.
	Architecture notes: Reads InputService (abstract actions, rebind-friendly)
	for keystrokes, the simulation state for speed and the Humanoid for health.
	Text/colors are only written when the value actually changes.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local FrameworkModule = ReplicatedStorage:WaitForChild("MovementFramework")
local Framework = require(FrameworkModule)
local VectorMath = require(FrameworkModule:WaitForChild("Math"):WaitForChild("VectorMath"))
local InputConfig = require(FrameworkModule:WaitForChild("Config"):WaitForChild("InputConfig"))

export type HUDService = {
	Name: string,
	Dependencies: { string }?,
	Init: (self: HUDService, registry: any) -> (),
	Start: (self: HUDService) -> (),
	Destroy: (self: HUDService) -> (),
}

type KeyEntry = { label: TextLabel, action: InputConfig.ActionName, held: boolean }

type HUDInternal = HUDService & {
	_fw: Framework.MovementFramework,
	_input: any,
	_replay: any,
	_gui: ScreenGui?,
	_healthValue: TextLabel?,
	_speedValue: TextLabel?,
	_keys: { KeyEntry },
	_conns: { RBXScriptConnection },
	_healthConn: RBXScriptConnection?,
	_lastSpeed: number,
	_enabled: boolean,
}

local RENDER_PRIORITY = 160

local KEY_ACTIONS: { [string]: InputConfig.ActionName } = {
	W = "MoveForward",
	A = "MoveLeft",
	S = "MoveBack",
	D = "MoveRight",
	Jump = "Jump",
}

local KEY_ACTIVE_COLOR = Color3.fromRGB(255, 170, 60)
local KEY_IDLE_COLOR = Color3.fromRGB(0, 0, 0)
local KEY_ACTIVE_TEXT = Color3.fromRGB(20, 20, 20)
local KEY_IDLE_TEXT = Color3.fromRGB(255, 255, 255)
local KEY_ACTIVE_TRANSPARENCY = 0.1
local KEY_IDLE_TRANSPARENCY = 0.55

local HP_FULL = Color3.fromRGB(235, 235, 235)
local HP_MID = Color3.fromRGB(255, 210, 80)
local HP_LOW = Color3.fromRGB(255, 90, 80)

local HUDService = {}
HUDService.__index = HUDService

local function bindGui(self: HUDInternal, gui: ScreenGui)
	self._gui = gui
	local health = gui:FindFirstChild("Health")
	self._healthValue = if health then health:FindFirstChild("Value") :: TextLabel? else nil
	local speed = gui:FindFirstChild("Speed")
	self._speedValue = if speed then speed:FindFirstChild("Value") :: TextLabel? else nil

	table.clear(self._keys)
	local cluster = gui:FindFirstChild("Keystrokes")
	if cluster then
		for name: string, action: InputConfig.ActionName in KEY_ACTIONS do
			local label = cluster:FindFirstChild(name)
			if label and label:IsA("TextLabel") then
				table.insert(self._keys, { label = label, action = action, held = false })
			end
		end
	end
end

local function setHealth(self: HUDInternal, humanoid: Humanoid)
	local label = self._healthValue
	if not label then
		return
	end
	local hp = math.max(math.ceil(humanoid.Health), 0)
	label.Text = tostring(hp)
	local ratio = if humanoid.MaxHealth > 0 then humanoid.Health / humanoid.MaxHealth else 0
	label.TextColor3 = if ratio >= 0.66 then HP_FULL elseif ratio >= 0.33 then HP_MID else HP_LOW
end

local function watchCharacter(self: HUDInternal, character: Model)
	local humanoid = character:WaitForChild("Humanoid") :: Humanoid
	if self._healthConn then
		self._healthConn:Disconnect()
	end
	setHealth(self, humanoid)
	self._healthConn = humanoid.HealthChanged:Connect(function()
		setHealth(self, humanoid)
	end)
end

-- Per-frame refresh: speed readout + keystroke highlights. Writes only on change.
local function update(self: HUDInternal)
	local speedLabel = self._speedValue
	if speedLabel then
		local speed = math.floor(VectorMath.horizontalLength(self._fw.State.velocity) + 0.5)
		if speed ~= self._lastSpeed then
			self._lastSpeed = speed
			speedLabel.Text = tostring(speed)
		end
	end

	-- Source of truth for keystrokes: the replay while it plays (so the
	-- overlay shows the recorded run's inputs, not the idle live keyboard),
	-- otherwise the live InputService.
	local replay = self._replay
	local source = if replay and replay:IsPlaying() then replay else self._input
	local keys = self._keys
	for i = 1, #keys do
		local entry = keys[i]
		local held = source:IsActionHeld(entry.action) == true
		if held ~= entry.held then
			entry.held = held
			entry.label.BackgroundColor3 = if held then KEY_ACTIVE_COLOR else KEY_IDLE_COLOR
			entry.label.BackgroundTransparency = if held then KEY_ACTIVE_TRANSPARENCY else KEY_IDLE_TRANSPARENCY
			entry.label.TextColor3 = if held then KEY_ACTIVE_TEXT else KEY_IDLE_TEXT
		end
	end
end

function HUDService.Init(self: HUDInternal, registry: any)
	self._input = registry:Get("InputService")
	self._replay = registry:Get("ReplayService")
end

function HUDService.Start(self: HUDInternal)
	local player = Players.LocalPlayer
	local playerGui = player:WaitForChild("PlayerGui")

	-- StarterGui clones into PlayerGui on first spawn; bind lazily, never yield.
	local existing = playerGui:FindFirstChild("QuakeHUD")
	if existing and existing:IsA("ScreenGui") then
		bindGui(self, existing)
	else
		table.insert(self._conns, playerGui.ChildAdded:Connect(function(child: Instance)
			if self._gui == nil and child.Name == "QuakeHUD" and child:IsA("ScreenGui") then
				bindGui(self, child)
			end
		end))
	end

	if player.Character then
		watchCharacter(self, player.Character)
	end
	table.insert(self._conns, player.CharacterAdded:Connect(function(character: Model)
		watchCharacter(self, character)
	end))

	self._fw.Scheduler:RegisterRender(RENDER_PRIORITY, function(_dt: number, _alpha: number)
		if self._enabled and self._gui ~= nil then
			update(self)
		end
	end)
end

function HUDService.Destroy(self: HUDInternal)
	self._enabled = false
	for _, conn in self._conns do
		conn:Disconnect()
	end
	table.clear(self._conns)
	if self._healthConn then
		self._healthConn:Disconnect()
		self._healthConn = nil
	end
end

local function new(fw: Framework.MovementFramework): HUDService
	return setmetatable({
		Name = "HUDService",
		Dependencies = { "InputService", "ReplayService" },
		_fw = fw,
		_input = nil,
		_replay = nil,
		_gui = nil,
		_healthValue = nil,
		_speedValue = nil,
		_keys = {},
		_conns = {},
		_healthConn = nil,
		_lastSpeed = -1,
		_enabled = true,
	}, HUDService) :: any
end

return { new = new }
