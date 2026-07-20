--!strict
--[[
	CameraService.luau
	Purpose: The camera pipeline. Owns first-person look input (yaw/pitch), composes
	every registered ICameraEffect into a single additive contribution, and writes
	the final CFrame + FieldOfView exactly once per render frame.
	Architecture notes: Effects never see the Camera. They fill a shared
	CameraContribution which the pipeline sums, so no effect can overwrite another -
	they only ever add. Ordering is irrelevant to correctness (addition commutes),
	which keeps effect registration decoupled.
	Performance: One reused contribution struct, one reused context struct. The
	per-frame cost is N effect Update calls plus one CFrame compose - no allocation.
]]

local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")

local FrameworkModule = game:GetService("ReplicatedStorage"):WaitForChild("MovementFramework")
local Types = require(FrameworkModule:WaitForChild("Core"):WaitForChild("Types"))
local CameraConfig = require(FrameworkModule:WaitForChild("Config"):WaitForChild("CameraConfig"))
local VectorMath = require(FrameworkModule:WaitForChild("Math"):WaitForChild("VectorMath"))

local HeadBob = require(script.Parent.CameraEffects.HeadBob)
local LandingEffect = require(script.Parent.CameraEffects.LandingEffect)
local FOVEffect = require(script.Parent.CameraEffects.FOVEffect)
local TiltEffect = require(script.Parent.CameraEffects.TiltEffect)
local ShakeEffect = require(script.Parent.CameraEffects.ShakeEffect)
local SwayEffect = require(script.Parent.CameraEffects.SwayEffect)
local SlideEffect = require(script.Parent.CameraEffects.SlideEffect)

export type CameraService = {
	Name: string,
	Dependencies: { string }?,
	SetProfile: (self: CameraService, profile: CameraConfig.CameraProfile) -> (),
	GetYaw: (self: CameraService) -> number,
	GetPitch: (self: CameraService) -> number,
	-- Programmatic look override (replay playback drives the view per tick).
	SetLook: (self: CameraService, yaw: number, pitch: number) -> (),
	SetEyeAnchor: (self: CameraService, getter: () -> Vector3) -> (),
	AddTrauma: (self: CameraService, amount: number) -> (),
	-- Frees/locks the cursor (GUI interaction); look input pauses while free.
	ToggleMouseLock: (self: CameraService) -> (),
	IsMouseUnlocked: (self: CameraService) -> boolean,
	Render: (self: CameraService, dt: number, alpha: number, state: Types.MoveState, strafeInput: number) -> (),
	Init: (self: CameraService, registry: any) -> (),
	Start: (self: CameraService) -> (),
	Destroy: (self: CameraService) -> (),
}

type CameraInternal = CameraService & {
	_profile: CameraConfig.CameraProfile,
	_effects: { Types.ICameraEffect },
	_shake: ShakeEffect.ShakeEffect,
	_yaw: number,
	_pitch: number,
	_sensitivity: number,
	_gamepadSens: number,
	_gamepadLook: Vector3, -- last Thumbstick2 deflection, integrated per frame
	_mouseUnlocked: boolean,
	_eyeGetter: (() -> Vector3)?,
	_camera: Camera,
	_contribution: Types.CameraContribution,
	_ctx: Types.CameraContext,
	_conns: { RBXScriptConnection },
}

local CameraService = {}
CameraService.__index = CameraService

local PITCH_LIMIT = math.rad(89)

function CameraService.SetProfile(self: CameraInternal, profile: CameraConfig.CameraProfile)
	self._profile = profile
	self._shake = ShakeEffect.new(profile.Shake)
	self._effects = {
		HeadBob.new(profile.HeadBob),
		SwayEffect.new(profile.Sway),
		SlideEffect.new(profile.Slide),
		LandingEffect.new(profile.Landing),
		TiltEffect.new(profile.Tilt),
		FOVEffect.new(profile.FOV),
		self._shake,
	}
end

function CameraService.GetYaw(self: CameraInternal): number
	return self._yaw
end

function CameraService.GetPitch(self: CameraInternal): number
	return self._pitch
end

function CameraService.SetLook(self: CameraInternal, yaw: number, pitch: number)
	self._yaw = yaw
	self._pitch = math.clamp(pitch, -PITCH_LIMIT, PITCH_LIMIT)
end

function CameraService.SetEyeAnchor(self: CameraInternal, getter: () -> Vector3)
	self._eyeGetter = getter
end

function CameraService.AddTrauma(self: CameraInternal, amount: number)
	self._shake:AddTrauma(amount)
end

function CameraService.ToggleMouseLock(self: CameraInternal)
	self._mouseUnlocked = not self._mouseUnlocked
	if self._mouseUnlocked then
		UserInputService.MouseBehavior = Enum.MouseBehavior.Default
		UserInputService.MouseIconEnabled = true
	else
		UserInputService.MouseBehavior = Enum.MouseBehavior.LockCenter
		UserInputService.MouseIconEnabled = false
	end
end

function CameraService.IsMouseUnlocked(self: CameraInternal): boolean
	return self._mouseUnlocked
end

function CameraService.Render(
	self: CameraInternal,
	dt: number,
	_alpha: number,
	state: Types.MoveState,
	strafeInput: number
)
	local getter = self._eyeGetter
	if not getter then
		return
	end

	-- Reclaim the camera every frame: the engine replaces CurrentCamera and
	-- resets CameraType to Custom on respawn, which reactivates the default
	-- PlayerModule (its TransparencyController then un-hides the character
	-- and its controller fights our CFrame). Cheap: two compares per frame.
	local camera = Workspace.CurrentCamera
	if camera == nil then
		return
	end
	self._camera = camera
	if camera.CameraType ~= Enum.CameraType.Scriptable then
		camera.CameraType = Enum.CameraType.Scriptable
	end
	-- Core scripts reset mouse state on focus/menu changes; keep enforcing
	-- whichever mode (locked / G-unlocked) is currently ours.
	local wantedBehavior = if self._mouseUnlocked
		then Enum.MouseBehavior.Default
		else Enum.MouseBehavior.LockCenter
	if UserInputService.MouseBehavior ~= wantedBehavior then
		UserInputService.MouseBehavior = wantedBehavior
	end

	-- Gamepad look: integrate the stored stick deflection every frame
	-- (dt-scaled => turn rate is framerate-independent).
	if not self._mouseUnlocked then
		local gp = self._gamepadLook
		local mag = math.sqrt(gp.X * gp.X + gp.Y * gp.Y)
		if mag > 0.18 then -- matches InputConfig.Default.GamepadDeadzone
			local sens = self._gamepadSens * dt
			self._yaw -= gp.X * sens
			self._pitch = math.clamp(self._pitch + gp.Y * sens, -PITCH_LIMIT, PITCH_LIMIT)
		end
	end

	local eye = getter()

	-- Reset the shared contribution (no allocation).
	local contrib = self._contribution
	contrib.positionOffset = Vector3.zero
	contrib.rotationOffset = Vector3.zero
	contrib.fovOffset = 0

	local baseLook = CFrame.fromEulerAnglesYXZ(self._pitch, self._yaw, 0).LookVector

	local ctx = self._ctx
	ctx.dt = dt
	ctx.state = state
	ctx.horizontalSpeed = VectorMath.horizontalLength(state.velocity)
	ctx.lookVector = baseLook
	ctx.strafeInput = strafeInput

	local effects = self._effects
	for i = 1, #effects do
		effects[i]:Update(ctx, contrib)
	end

	-- Compose: base orientation from look input, plus additive effect rotation,
	-- positioned at the eye plus additive effect offset expressed in view space.
	local baseCFrame = CFrame.fromEulerAnglesYXZ(
		self._pitch + contrib.rotationOffset.X,
		self._yaw + contrib.rotationOffset.Y,
		contrib.rotationOffset.Z
	)
	local worldOffset = baseCFrame:VectorToWorldSpace(contrib.positionOffset)
	self._camera.CFrame = CFrame.new(eye + worldOffset) * baseCFrame
	self._camera.FieldOfView = math.clamp(self._profile.FOV.BaseFOV + contrib.fovOffset, 40, 120)
end

function CameraService.Init(self: CameraInternal, _registry: any)
	self._camera = Workspace.CurrentCamera
	self._camera.CameraType = Enum.CameraType.Scriptable
end

function CameraService.Start(self: CameraInternal)
	UserInputService.MouseBehavior = Enum.MouseBehavior.LockCenter
	UserInputService.MouseIconEnabled = false

	table.insert(self._conns, UserInputService.InputChanged:Connect(function(io: InputObject, processed: boolean)
		if processed then
			return
		end
		if io.UserInputType == Enum.UserInputType.MouseMovement then
			if self._mouseUnlocked then
				return -- cursor is free for GUI: moving it must not turn the view
			end
			local delta = io.Delta
			local sens = self._sensitivity * 0.0022
			self._yaw -= delta.X * sens
			self._pitch = math.clamp(self._pitch - delta.Y * sens, -PITCH_LIMIT, PITCH_LIMIT)
		elseif io.KeyCode == Enum.KeyCode.Thumbstick2 then
			-- Store only: InputChanged fires on CHANGE, so integrating here
			-- would stall the turn while the stick is held at a constant
			-- deflection. Render integrates the stored value every frame.
			self._gamepadLook = io.Position
		end
	end))
end

function CameraService.Destroy(self: CameraInternal)
	for _, conn in self._conns do
		conn:Disconnect()
	end
	table.clear(self._conns)
	UserInputService.MouseBehavior = Enum.MouseBehavior.Default
	UserInputService.MouseIconEnabled = true
	if self._camera then
		self._camera.CameraType = Enum.CameraType.Custom
	end
end

local function new(profile: CameraConfig.CameraProfile, sensitivity: number, gamepadSensitivity: number?): CameraService
	local self: CameraInternal = setmetatable({
		Name = "CameraService",
		Dependencies = nil,
		_profile = profile,
		_effects = {},
		_shake = nil :: any,
		_yaw = 0,
		_pitch = 0,
		_sensitivity = sensitivity,
		_gamepadSens = gamepadSensitivity or 6,
		_gamepadLook = Vector3.zero,
		_mouseUnlocked = false,
		_eyeGetter = nil,
		_camera = Workspace.CurrentCamera,
		_contribution = { positionOffset = Vector3.zero, rotationOffset = Vector3.zero, fovOffset = 0 },
		_ctx = {
			dt = 0,
			state = nil :: any,
			horizontalSpeed = 0,
			lookVector = Vector3.zAxis,
			strafeInput = 0,
		},
		_conns = {},
	}, CameraService) :: any
	self:SetProfile(profile)
	local _ = Players -- referenced for future per-player camera routing
	return self
end

return { new = new }
