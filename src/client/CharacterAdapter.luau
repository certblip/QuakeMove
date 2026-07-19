--!strict
--[[
	CharacterAdapter.luau
	Purpose: The bridge between the simulation and the Roblox character. Neutralizes
	Humanoid movement (the Humanoid becomes a pure container for appearance,
	health and animation) and writes interpolated simulation transforms to the
	root part every render frame.
	Architecture notes: Interpolation blends previous->current fixed-tick positions
	by the scheduler alpha, so a 60Hz sim renders glass-smooth at 240 FPS.
	Correction smoothing: when prediction rollback teleports the state, the visual
	offset is absorbed and decayed exponentially instead of snapping.
]]

local FrameworkModule = game:GetService("ReplicatedStorage"):WaitForChild("MovementFramework")
local Types = require(FrameworkModule:WaitForChild("Core"):WaitForChild("Types"))

export type CharacterAdapter = {
	Name: string,
	Dependencies: { string }?,
	Bind: (self: CharacterAdapter, character: Model) -> (),
	Unbind: (self: CharacterAdapter) -> (),
	OnTickCommitted: (self: CharacterAdapter, state: Types.MoveState) -> (),
	AbsorbCorrection: (self: CharacterAdapter, visualDelta: Vector3) -> (),
	Render: (self: CharacterAdapter, dt: number, alpha: number, yaw: number) -> (),
	GetRoot: (self: CharacterAdapter) -> BasePart?,
	Init: (self: CharacterAdapter, registry: any) -> (),
	Start: ((self: CharacterAdapter) -> ())?, -- optional per Service contract
	Destroy: (self: CharacterAdapter) -> (),
}

type AdapterInternal = CharacterAdapter & {
	_root: BasePart?,
	_humanoid: Humanoid?,
	_character: Model?,
	_hideConn: RBXScriptConnection?,
	_prevPos: Vector3,
	_currPos: Vector3,
	_correction: Vector3,
	_correctionLambda: number,
}

local CharacterAdapter = {}
CharacterAdapter.__index = CharacterAdapter

local DISABLED_STATES: { Enum.HumanoidStateType } = {
	Enum.HumanoidStateType.Climbing,
	Enum.HumanoidStateType.FallingDown,
	Enum.HumanoidStateType.Flying,
	Enum.HumanoidStateType.Freefall,
	Enum.HumanoidStateType.GettingUp,
	Enum.HumanoidStateType.Jumping,
	Enum.HumanoidStateType.Landed,
	Enum.HumanoidStateType.Ragdoll,
	Enum.HumanoidStateType.Running,
	Enum.HumanoidStateType.RunningNoPhysics,
	Enum.HumanoidStateType.Seated,
	Enum.HumanoidStateType.StrafingNoPhysics,
	Enum.HumanoidStateType.Swimming,
	-- NOTE: "Touched" is a BasePart event, not a HumanoidStateType; indexing it
	-- errors at module load. PlatformStanding is the state that was missing.
	Enum.HumanoidStateType.PlatformStanding,
}

-- First-person: hide the local character (head, hair, accessories, body)
-- without touching replication. LocalTransparencyModifier is a client-only
-- visual override - other players still see the character normally. The
-- default Roblox transparency controller only does this for its own camera;
-- with a Scriptable camera we must do it ourselves.
local function hideLocally(inst: Instance)
	-- Branches keep each write on a single narrowed type (union property
	-- writes do not typecheck). Texture inherits Decal, so two checks suffice.
	if inst:IsA("BasePart") then
		inst.LocalTransparencyModifier = 1
	elseif inst:IsA("Decal") then
		inst.LocalTransparencyModifier = 1
	end
end

function CharacterAdapter.Bind(self: AdapterInternal, character: Model)
	local root = character:WaitForChild("HumanoidRootPart") :: BasePart
	local humanoid = character:WaitForChild("Humanoid") :: Humanoid

	-- Rebind (respawn): drop the previous character's hide watcher first.
	if self._hideConn then
		self._hideConn:Disconnect()
		self._hideConn = nil
	end

	-- Hide everything already present, then keep hiding late arrivals -
	-- accessories/hair replicate in asynchronously after CharacterAdded.
	for _, inst in character:GetDescendants() do
		hideLocally(inst)
	end
	self._hideConn = character.DescendantAdded:Connect(hideLocally)
	self._character = character

	-- Humanoid becomes a container: no state machine, no auto-physics.
	for _, stateType in DISABLED_STATES do
		humanoid:SetStateEnabled(stateType, false)
	end
	humanoid:ChangeState(Enum.HumanoidStateType.Physics)
	humanoid.AutoRotate = false
	humanoid.EvaluateStateMachine = false

	root.Anchored = true
	self._root = root
	self._humanoid = humanoid
	self._prevPos = root.Position
	self._currPos = root.Position
	self._correction = Vector3.zero
end

function CharacterAdapter.Unbind(self: AdapterInternal)
	if self._hideConn then
		self._hideConn:Disconnect()
		self._hideConn = nil
	end
	-- Restore local visibility (e.g. when the framework is disabled/destroyed
	-- and the default third-person camera takes back over).
	local character = self._character
	if character then
		for _, inst in character:GetDescendants() do
			if inst:IsA("BasePart") then
				inst.LocalTransparencyModifier = 0
			elseif inst:IsA("Decal") then
				inst.LocalTransparencyModifier = 0
			end
		end
	end
	self._character = nil
	local root = self._root
	if root then
		root.Anchored = false
	end
	self._root = nil
	self._humanoid = nil
end

function CharacterAdapter.OnTickCommitted(self: AdapterInternal, state: Types.MoveState)
	self._prevPos = self._currPos
	self._currPos = state.position
end

function CharacterAdapter.AbsorbCorrection(self: AdapterInternal, visualDelta: Vector3)
	-- The sim already snapped; hide the visual pop and decay it out.
	self._correction += visualDelta
	self._prevPos = self._currPos
end

function CharacterAdapter.Render(self: AdapterInternal, dt: number, alpha: number, yaw: number)
	local root = self._root
	if not root then
		return
	end
	self._correction = self._correction:Lerp(Vector3.zero, 1 - math.exp(-self._correctionLambda * dt))
	local pos = self._prevPos:Lerp(self._currPos, alpha) + self._correction
	root.CFrame = CFrame.new(pos) * CFrame.Angles(0, yaw, 0)
end

function CharacterAdapter.GetRoot(self: AdapterInternal): BasePart?
	return self._root
end

function CharacterAdapter.Init(_self: AdapterInternal, _registry: any) end

function CharacterAdapter.Destroy(self: AdapterInternal)
	self:Unbind()
end

local function new(): CharacterAdapter
	return setmetatable({
		Name = "CharacterAdapter",
		Dependencies = nil,
		_root = nil,
		_humanoid = nil,
		_character = nil,
		_hideConn = nil,
		_prevPos = Vector3.zero,
		_currPos = Vector3.zero,
		_correction = Vector3.zero,
		_correctionLambda = 14,
	}, CharacterAdapter) :: any
end

return { new = new }
