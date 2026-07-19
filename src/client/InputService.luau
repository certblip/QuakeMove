--!strict
--[[
	InputService.luau
	Purpose: Device abstraction. Translates keyboard / mouse / gamepad / touch into
	abstract action state and produces one InputCommand per simulation tick.
	Architecture notes: The simulation never sees devices - only commands. Jump is
	edge-buffered here (press => buffer flag for JumpBufferTime worth of ticks) so
	non-autojump play still gets forgiving bhop timing. Touch surfaces call
	SetAxis/SetActionHeld directly, which is also the rebinding-friendly path for
	custom UI.
	Performance: Action state is flat booleans; BuildCommand writes into a caller
	provided command table - zero allocation per tick.
]]

local UserInputService = game:GetService("UserInputService")

local FrameworkModule = game:GetService("ReplicatedStorage"):WaitForChild("MovementFramework")
local Types = require(FrameworkModule:WaitForChild("Core"):WaitForChild("Types"))
local InputConfig = require(FrameworkModule:WaitForChild("Config"):WaitForChild("InputConfig"))

local Buttons = Types.Buttons

export type InputService = {
	Name: string,
	Dependencies: { string }?,
	SetProfile: (self: InputService, profile: InputConfig.InputProfile) -> (),
	SetAxis: (self: InputService, x: number, z: number) -> (), -- external/touch injection
	SetActionHeld: (self: InputService, action: InputConfig.ActionName, held: boolean) -> (),
	BuildCommand: (self: InputService, cmd: Types.InputCommand, tick: number, dt: number, yaw: number, pitch: number) -> (),
	GetDebugToggled: (self: InputService) -> boolean,
	Init: (self: InputService, registry: any) -> (),
	Start: (self: InputService) -> (),
	Destroy: (self: InputService) -> (),
}

type InputInternal = InputService & {
	_profile: InputConfig.InputProfile,
	_held: { [string]: boolean },
	_keyToAction: { [Enum.KeyCode]: InputConfig.ActionName },
	_externalX: number,
	_externalZ: number,
	_gamepadX: number,
	_gamepadZ: number,
	_jumpQueued: boolean, -- edge event, consumed by the next BuildCommand
	_debugToggled: boolean,
	_conns: { RBXScriptConnection },
}

local InputService = {}
InputService.__index = InputService

local function rebuildKeyMap(self: InputInternal)
	table.clear(self._keyToAction)
	-- Explicit annotation: the old solver widens map-iteration keys to string.
	for action: InputConfig.ActionName, binding in self._profile.Bindings do
		for _, key in binding.Keyboard do
			self._keyToAction[key] = action
		end
		for _, key in binding.Gamepad do
			self._keyToAction[key] = action
		end
	end
end

function InputService.SetProfile(self: InputInternal, profile: InputConfig.InputProfile)
	self._profile = profile
	rebuildKeyMap(self)
end

function InputService.SetAxis(self: InputInternal, x: number, z: number)
	self._externalX = math.clamp(x, -1, 1)
	self._externalZ = math.clamp(z, -1, 1)
end

function InputService.SetActionHeld(self: InputInternal, action: InputConfig.ActionName, held: boolean)
	local was = self._held[action] == true
	self._held[action] = held
	if action == "Jump" and held and not was then
		self._jumpQueued = true
	end
	if action == "ToggleDebug" and held and not was then
		self._debugToggled = true
	end
end

function InputService.GetDebugToggled(self: InputInternal): boolean
	local v = self._debugToggled
	self._debugToggled = false
	return v
end

function InputService.BuildCommand(
	self: InputInternal,
	cmd: Types.InputCommand,
	tick: number,
	dt: number,
	yaw: number,
	pitch: number
)
	local held = self._held
	local x = 0
	local z = 0
	if held.MoveRight then
		x += 1
	end
	if held.MoveLeft then
		x -= 1
	end
	if held.MoveForward then
		z += 1
	end
	if held.MoveBack then
		z -= 1
	end
	x += self._externalX + self._gamepadX
	z += self._externalZ + self._gamepadZ

	cmd.tick = tick
	cmd.dt = dt
	cmd.moveX = math.clamp(x, -1, 1)
	cmd.moveZ = math.clamp(z, -1, 1)
	cmd.yaw = yaw
	cmd.pitch = pitch

	local buttons = 0
	if held.Jump or self._jumpQueued then
		buttons = bit32.bor(buttons, Buttons.Jump)
	end
	if held.Sprint then
		buttons = bit32.bor(buttons, Buttons.Sprint)
	end
	if held.Slide then
		buttons = bit32.bor(buttons, Buttons.Slide)
	end
	cmd.buttons = buttons
	self._jumpQueued = false -- consumed
end

function InputService.Init(self: InputInternal, _registry: any)
	rebuildKeyMap(self)
end

function InputService.Start(self: InputInternal)
	local conns = self._conns

	table.insert(conns, UserInputService.InputBegan:Connect(function(io: InputObject, processed: boolean)
		if processed then
			return
		end
		local action: InputConfig.ActionName? = self._keyToAction[io.KeyCode]
		if action then
			self:SetActionHeld(action, true)
		end
	end))

	table.insert(conns, UserInputService.InputEnded:Connect(function(io: InputObject, _processed: boolean)
		local action: InputConfig.ActionName? = self._keyToAction[io.KeyCode]
		if action then
			self:SetActionHeld(action, false)
		end
	end))

	table.insert(conns, UserInputService.InputChanged:Connect(function(io: InputObject, processed: boolean)
		if processed then
			return
		end
		if io.KeyCode == Enum.KeyCode.Thumbstick1 then
			local pos = io.Position
			local deadzone = self._profile.GamepadDeadzone
			local mag = math.sqrt(pos.X * pos.X + pos.Y * pos.Y)
			if mag < deadzone then
				self._gamepadX = 0
				self._gamepadZ = 0
			else
				local scale = (mag - deadzone) / (1 - deadzone) / mag
				self._gamepadX = pos.X * scale
				self._gamepadZ = pos.Y * scale
			end
		end
	end))
end

function InputService.Destroy(self: InputInternal)
	for _, conn in self._conns do
		conn:Disconnect()
	end
	table.clear(self._conns)
end

local function new(profile: InputConfig.InputProfile): InputService
	return setmetatable({
		Name = "InputService",
		Dependencies = nil,
		_profile = profile,
		_held = {},
		_keyToAction = {},
		_externalX = 0,
		_externalZ = 0,
		_gamepadX = 0,
		_gamepadZ = 0,
		_jumpQueued = false,
		_debugToggled = false,
		_conns = {},
	}, InputService) :: any
end

return { new = new }
