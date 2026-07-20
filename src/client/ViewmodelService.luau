--!strict
--[[
	ViewmodelService.luau
	Purpose: First-person viewmodel (arms). Clones the Viewmodel asset authored
	in ReplicatedStorage.QuakeAssets (src/assets/Viewmodel.model.json - a real
	instance tree, not runtime construction) into the camera and drives it every
	render frame: camera-relative offsets + look sway (rotation lag), movement
	bob, a landing-dip spring and a vertical float while airborne.
	Architecture notes: Pure render-layer consumer. Reads CameraService
	(yaw/pitch) and the simulation state; never writes to either. Registered on
	the shared Scheduler at render priority 150 so it runs after the camera
	pipeline (priority 100) has finalized this frame's camera CFrame.
	Performance: Two anchored parts, two CFrame writes per frame, zero
	allocation in the render path.
]]

local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local FrameworkModule = ReplicatedStorage:WaitForChild("MovementFramework")
local Framework = require(FrameworkModule)
local VectorMath = require(FrameworkModule:WaitForChild("Math"):WaitForChild("VectorMath"))
local Spring = require(FrameworkModule:WaitForChild("Math"):WaitForChild("Spring"))

export type ViewmodelService = {
	Name: string,
	Dependencies: { string }?,
	Init: (self: ViewmodelService, registry: any) -> (),
	Start: (self: ViewmodelService) -> (),
	Destroy: (self: ViewmodelService) -> (),
}

type PartEntry = { part: BasePart, offset: CFrame }

type ViewmodelInternal = ViewmodelService & {
	_fw: Framework.MovementFramework,
	_cameraService: any,
	_model: Model?,
	_parts: { PartEntry },
	_lastYaw: number,
	_lastPitch: number,
	_swayYaw: number,
	_swayPitch: number,
	_bobPhase: number,
	_bobAmp: number,
	_landSpring: Spring.Spring3,
	_lastLandTick: number,
	_enabled: boolean,
}

local RENDER_PRIORITY = 150

-- Camera-relative rest pose per part name (authored here, geometry in the asset).
local OFFSETS: { [string]: CFrame } = {
	RightArm = CFrame.new(1.0, -0.9, -1.15) * CFrame.fromEulerAnglesYXZ(math.rad(-4), math.rad(-6), math.rad(6)),
	LeftArm = CFrame.new(-1.0, -0.9, -1.15) * CFrame.fromEulerAnglesYXZ(math.rad(-4), math.rad(6), math.rad(-6)),
}

local SWAY_SCALE = 2.2 -- rotation lag per radian of look delta
local SWAY_DAMP = 12
local BOB_DAMP = 8
local LAND_DIP_PER_SPEED = 0.02
local LAND_DIP_MAX = 0.5

local ViewmodelService = {}
ViewmodelService.__index = ViewmodelService

local function update(self: ViewmodelInternal, dt: number)
	local model = self._model
	if not model then
		return
	end
	local camera = Workspace.CurrentCamera
	if not camera then
		return
	end
	-- The engine can replace CurrentCamera (respawn/reset); follow it.
	if model.Parent ~= camera then
		model.Parent = camera
	end

	local state = self._fw.State

	-- Rotation lag (sway): proportional to this frame's look delta, damped.
	local yaw = self._cameraService:GetYaw() :: number
	local pitch = self._cameraService:GetPitch() :: number
	local dYaw = math.clamp(yaw - self._lastYaw, -0.2, 0.2)
	local dPitch = math.clamp(pitch - self._lastPitch, -0.2, 0.2)
	self._lastYaw = yaw
	self._lastPitch = pitch
	self._swayYaw = VectorMath.damp(self._swayYaw, dYaw * SWAY_SCALE, SWAY_DAMP, dt)
	self._swayPitch = VectorMath.damp(self._swayPitch, dPitch * SWAY_SCALE, SWAY_DAMP, dt)

	-- Movement bob: figure-eight, fades out when airborne or slowing down.
	local hSpeed = VectorMath.horizontalLength(state.velocity)
	local ampTarget = if state.grounded then math.min(hSpeed / 20, 1.6) else 0
	self._bobAmp = VectorMath.damp(self._bobAmp, ampTarget, BOB_DAMP, dt)
	if self._bobAmp > 1e-3 then
		self._bobPhase += dt * (5 + hSpeed * 0.3)
	end
	local bobX = math.cos(self._bobPhase) * 0.035 * self._bobAmp
	local bobY = math.sin(self._bobPhase * 2) * 0.022 * self._bobAmp

	-- Landing dip through a stiff spring (tick-guarded: landedThisTick spans a
	-- whole sim tick which covers multiple render frames).
	if state.landedThisTick and state.tick ~= self._lastLandTick then
		self._lastLandTick = state.tick
		local dip = math.min(state.landingSpeed * LAND_DIP_PER_SPEED, LAND_DIP_MAX)
		self._landSpring:Impulse(Vector3.new(0, -dip * 40, 0))
	end
	local springPos = self._landSpring:Update(dt)

	-- Vertical float: arms lag opposite to vertical motion while airborne.
	local floatY = math.clamp(-state.velocity.Y * 0.004, -0.12, 0.12)

	local base = camera.CFrame
		* CFrame.fromEulerAnglesYXZ(-self._swayPitch, -self._swayYaw, self._swayYaw * 0.6)
		* CFrame.new(bobX + self._swayYaw * 0.5, bobY + floatY + springPos.Y, 0)

	local parts = self._parts
	for i = 1, #parts do
		local entry = parts[i]
		entry.part.CFrame = base * entry.offset
	end
end

function ViewmodelService.Init(self: ViewmodelInternal, registry: any)
	self._cameraService = registry:Get("CameraService")
end

function ViewmodelService.Start(self: ViewmodelInternal)
	local assets = ReplicatedStorage:WaitForChild("QuakeAssets")
	local template = assets:WaitForChild("Viewmodel") :: Model
	local model = template:Clone()
	self._model = model

	for _, inst in model:GetChildren() do
		if inst:IsA("BasePart") then
			local offset = OFFSETS[inst.Name]
			if offset then
				table.insert(self._parts, { part = inst, offset = offset })
			end
		end
	end
	model.Parent = Workspace.CurrentCamera

	self._fw.Scheduler:RegisterRender(RENDER_PRIORITY, function(dt: number, _alpha: number)
		if self._enabled then
			update(self, dt)
		end
	end)
end

function ViewmodelService.Destroy(self: ViewmodelInternal)
	self._enabled = false
	if self._model then
		self._model:Destroy()
		self._model = nil
	end
	table.clear(self._parts)
end

local function new(fw: Framework.MovementFramework): ViewmodelService
	return setmetatable({
		Name = "ViewmodelService",
		Dependencies = { "CameraService" },
		_fw = fw,
		_cameraService = nil,
		_model = nil,
		_parts = {},
		_lastYaw = 0,
		_lastPitch = 0,
		_swayYaw = 0,
		_swayPitch = 0,
		_bobPhase = 0,
		_bobAmp = 0,
		_landSpring = Spring.new(240, 20),
		_lastLandTick = -1,
		_enabled = true,
	}, ViewmodelService) :: any
end

return { new = new }
