--!strict
--[[
	MovementFramework/init.luau
	Purpose: Public facade. Owns the ServiceRegistry, Scheduler and Simulator;
	exposes the profile/enable/modifier API. Everything under this module is
	internal - games interact only with the surface defined here.
	Architecture notes: Modifiers are ordered hooks that run against the MoveState
	after each simulation tick (jump pads, speed zones, grapples). They receive the
	state and the profile but never engine objects.
]]

local Types = require(script.Core.Types)
local ServiceRegistry = require(script.Core.ServiceRegistry)
local Scheduler = require(script.Core.Scheduler)
local Signal = require(script.Core.Signal)
local MoveState = require(script.Simulation.MoveState)
local Simulator = require(script.Simulation.Simulator)
local Collision = require(script.Simulation.Collision)
local StateMachine = require(script.Simulation.StateMachine)
local MovementConfig = require(script.Config.MovementConfig)
local CameraConfig = require(script.Config.CameraConfig)
local InputConfig = require(script.Config.InputConfig)
local NetworkConfig = require(script.Config.NetworkConfig)
local Replay = require(script.Networking.Replay)

export type Modifier = {
	Name: string,
	Priority: number,
	Apply: (state: Types.MoveState, profile: MovementConfig.MovementProfile, dt: number) -> (),
}

export type MovementFramework = {
	Registry: ServiceRegistry.ServiceRegistry,
	Scheduler: Scheduler.Scheduler,
	Simulator: Simulator.Simulator,
	CollisionWorld: Collision.CollisionWorld,
	State: Types.MoveState,
	StateChanged: Signal.Signal<number, number>,

	RegisterService: (self: MovementFramework, service: ServiceRegistry.Service) -> MovementFramework,
	GetService: (self: MovementFramework, name: string) -> ServiceRegistry.Service,
	SetMovementProfile: (self: MovementFramework, profile: MovementConfig.MovementProfile) -> (),
	GetMovementProfile: (self: MovementFramework) -> MovementConfig.MovementProfile,
	SetCameraProfile: (self: MovementFramework, profile: CameraConfig.CameraProfile) -> (),
	GetCameraProfile: (self: MovementFramework) -> CameraConfig.CameraProfile,
	SetInputProfile: (self: MovementFramework, profile: InputConfig.InputProfile) -> (),
	GetInputProfile: (self: MovementFramework) -> InputConfig.InputProfile,
	AddModifier: (self: MovementFramework, modifier: Modifier) -> (),
	RemoveModifier: (self: MovementFramework, name: string) -> (),
	ApplyModifiers: (self: MovementFramework, dt: number) -> (),
	ApplyModifiersTo: (self: MovementFramework, state: Types.MoveState, dt: number) -> (),
	Enable: (self: MovementFramework) -> (),
	Disable: (self: MovementFramework) -> (),
	IsEnabled: (self: MovementFramework) -> boolean,
	SetDebug: (self: MovementFramework, enabled: boolean) -> (),
	IsDebug: (self: MovementFramework) -> boolean,
	Start: (self: MovementFramework) -> (),
	Destroy: (self: MovementFramework) -> (),
}

type FrameworkInternal = MovementFramework & {
	_modifiers: { Modifier },
	_cameraProfile: CameraConfig.CameraProfile,
	_inputProfile: InputConfig.InputProfile,
	_enabled: boolean,
	_debug: boolean,
	_debugChanged: Signal.Signal<boolean>,
}

local Framework = {}
Framework.__index = Framework

function Framework.RegisterService(self: FrameworkInternal, service: ServiceRegistry.Service): MovementFramework
	self.Registry:Register(service)
	return self
end

function Framework.GetService(self: FrameworkInternal, name: string): ServiceRegistry.Service
	return self.Registry:Get(name)
end

function Framework.SetMovementProfile(self: FrameworkInternal, profile: MovementConfig.MovementProfile)
	self.Simulator:SetProfile(profile)
end

function Framework.GetMovementProfile(self: FrameworkInternal): MovementConfig.MovementProfile
	return self.Simulator:GetProfile()
end

function Framework.SetCameraProfile(self: FrameworkInternal, profile: CameraConfig.CameraProfile)
	self._cameraProfile = profile
end

function Framework.GetCameraProfile(self: FrameworkInternal): CameraConfig.CameraProfile
	return self._cameraProfile
end

function Framework.SetInputProfile(self: FrameworkInternal, profile: InputConfig.InputProfile)
	self._inputProfile = profile
end

function Framework.GetInputProfile(self: FrameworkInternal): InputConfig.InputProfile
	return self._inputProfile
end

function Framework.AddModifier(self: FrameworkInternal, modifier: Modifier)
	self:RemoveModifier(modifier.Name)
	table.insert(self._modifiers, modifier)
	table.sort(self._modifiers, function(a, b)
		return a.Priority < b.Priority
	end)
end

function Framework.RemoveModifier(self: FrameworkInternal, name: string)
	for i, m in self._modifiers do
		if m.Name == name then
			table.remove(self._modifiers, i)
			return
		end
	end
end

-- State-parameterised so the SERVER can run the same ordered list against its
-- per-player states. Client prediction, rollback replay and the authoritative
-- sim must all execute identical modifier passes or pads/zones become
-- permanent prediction errors.
function Framework.ApplyModifiersTo(self: FrameworkInternal, state: Types.MoveState, dt: number)
	local profile = self.Simulator:GetProfile()
	local mods = self._modifiers
	for i = 1, #mods do
		mods[i].Apply(state, profile, dt)
	end
end

function Framework.ApplyModifiers(self: FrameworkInternal, dt: number)
	self:ApplyModifiersTo(self.State, dt)
end

function Framework.Enable(self: FrameworkInternal)
	self._enabled = true
end

function Framework.Disable(self: FrameworkInternal)
	self._enabled = false
end

function Framework.IsEnabled(self: FrameworkInternal): boolean
	return self._enabled
end

function Framework.SetDebug(self: FrameworkInternal, enabled: boolean)
	self._debug = enabled
	self._debugChanged:Fire(enabled)
end

function Framework.IsDebug(self: FrameworkInternal): boolean
	return self._debug
end

function Framework.Start(self: FrameworkInternal)
	self.Registry:Start()
	self.Scheduler:Start()
end

function Framework.Destroy(self: FrameworkInternal)
	self.Scheduler:Stop()
	self.Registry:Destroy()
	self.StateChanged:DisconnectAll()
	self._debugChanged:DisconnectAll()
end

export type FrameworkOptions = {
	FixedRate: number?,
	MovementProfile: MovementConfig.MovementProfile?,
	CameraProfile: CameraConfig.CameraProfile?,
	InputProfile: InputConfig.InputProfile?,
	SpawnPosition: Vector3?,
}

local function create(options: FrameworkOptions?): MovementFramework
	local opts: FrameworkOptions = options or {}
	local movementProfile = opts.MovementProfile or MovementConfig.Default
	local collisionWorld =
		Collision.new(movementProfile.ColliderSize, movementProfile.CrouchColliderHeight / movementProfile.ColliderSize.Y)
	local simulator = Simulator.new(movementProfile, collisionWorld.Trace)

	local self: FrameworkInternal = setmetatable({
		Registry = ServiceRegistry.new(),
		Scheduler = Scheduler.new(opts.FixedRate or 60),
		Simulator = simulator,
		CollisionWorld = collisionWorld,
		State = MoveState.new(opts.SpawnPosition or Vector3.new(0, 10, 0)),
		StateChanged = Signal.new(),
		_modifiers = {},
		_cameraProfile = opts.CameraProfile or CameraConfig.Default,
		_inputProfile = opts.InputProfile or InputConfig.Default,
		_enabled = true,
		_debug = false,
		_debugChanged = Signal.new(),
	}, Framework) :: any

	return self
end

return table.freeze({
	create = create,
	Types = Types,
	StateMachine = StateMachine,
	MovementConfig = MovementConfig,
	CameraConfig = CameraConfig,
	InputConfig = InputConfig,
	NetworkConfig = NetworkConfig,
	Replay = Replay,
	Signal = Signal,
})
