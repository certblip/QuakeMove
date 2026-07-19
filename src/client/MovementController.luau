--!strict
--[[
	MovementController.luau
	Purpose: Client orchestrator. Owns the per-tick pipeline wiring described in the
	brief:
	    Input Collection -> Simulation Tick -> Physics Step -> Movement Resolution
	    -> Camera Update -> Visual Effects
	It does NOT implement any of those stages - it sequences the services that do.
	This is the composition root for the client, deliberately thin.
	Architecture notes: Fixed-step callback (priority 100) collects input, steps the
	simulator, records the prediction snapshot, ships the input packet and notifies
	the adapter. Render callback (priority 100) drives camera + character interp.
	Physics runs at the sim rate; rendering interpolates - the two are fully
	decoupled, so camera never influences movement.
	Performance: Reuses one InputCommand and one snapshot buffer forever.
]]

local Players = game:GetService("Players")

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Framework = require(ReplicatedStorage:WaitForChild("MovementFramework"))
local Types = require(ReplicatedStorage.MovementFramework.Core.Types)

local InputCommand = require(ReplicatedStorage.MovementFramework.Networking.InputCommand)
local PredictionBuffer = require(ReplicatedStorage.MovementFramework.Networking.PredictionBuffer)
local MoveState = require(ReplicatedStorage.MovementFramework.Simulation.MoveState)

export type MovementController = {
	Name: string,
	Dependencies: { string }?,
	Init: (self: MovementController, registry: any) -> (),
	Start: (self: MovementController) -> (),
	Destroy: (self: MovementController) -> (),
}

type ControllerInternal = MovementController & {
	_fw: Framework.MovementFramework,
	_input: any,
	_camera: any,
	_adapter: any,
	_debug: any,
	_transport: Types.ITransport,
	_cmd: Types.InputCommand,
	_prediction: PredictionBuffer.PredictionBuffer,
	_inputPacket: buffer,
	_serverState: Types.MoveState,
	_bound: boolean,
	_strafeInput: number,
}

local MovementController = {}
MovementController.__index = MovementController

function MovementController.Init(self: ControllerInternal, registry: any)
	self._input = registry:Get("InputService")
	self._camera = registry:Get("CameraService")
	self._adapter = registry:Get("CharacterAdapter")
	self._debug = registry:TryGet("DebugOverlay")
end

local function bindCharacter(self: ControllerInternal, character: Model)
	self._adapter:Bind(character)
	self._fw.CollisionWorld:SetIgnoreCharacter(character)
	local root = self._adapter:GetRoot()
	if root then
		self._fw.State.position = root.Position
	end
	self._bound = true
end

function MovementController.Start(self: ControllerInternal)
	local player = Players.LocalPlayer
	local profile = self._fw:GetMovementProfile()

	-- Eye anchor: sim position + eye height, read fresh each render frame.
	self._camera:SetEyeAnchor(function(): Vector3
		local s = self._fw.State
		return s.position + Vector3.new(0, profile.EyeHeight, 0)
	end)

	if player.Character then
		bindCharacter(self, player.Character)
	end
	player.CharacterAdded:Connect(function(character: Model)
		bindCharacter(self, character)
	end)

	-- FIXED STEP: the deterministic pipeline.
	self._fw.Scheduler:RegisterFixed(100, function(tick: number, dt: number)
		if not self._fw:IsEnabled() or not self._bound then
			return
		end
		local t0 = os.clock()

		-- 1. Input Collection
		self._input:BuildCommand(self._cmd, tick, dt, self._camera:GetYaw(), self._camera:GetPitch())
		self._strafeInput = self._cmd.moveX

		-- 2/3/4. Simulation + Physics + Resolution
		self._fw.Simulator:Step(self._fw.State, self._cmd)

		-- Modifiers (jump pads, zones) run after the deterministic core.
		self._fw:ApplyModifiers(dt)

		-- Prediction bookkeeping + replication (unreliable input up).
		self._prediction:Record(self._cmd, self._fw.State)
		InputCommand.serialize(self._cmd, self._inputPacket, 0)
		self._transport:SendInput(self._inputPacket)

		self._adapter:OnTickCommitted(self._fw.State)

		-- Debug toggle edge from input abstraction.
		if self._input:GetDebugToggled() then
			self._fw:SetDebug(not self._fw:IsDebug())
			if self._debug then
				self._debug:SetVisible(self._fw:IsDebug())
			end
		end

		if self._debug and self._fw:IsDebug() then
			self._debug:SetSimTime(math.round((os.clock() - t0) * 1e6))
			self._debug:SetNetworkStats(0, self._prediction:GetLastError())
			self._debug:Update(self._fw.State)
		end
	end)

	-- RENDER: camera + visual interpolation. Never mutates simulation state.
	self._fw.Scheduler:RegisterRender(100, function(dt: number, alpha: number)
		if not self._bound then
			return
		end
		-- 5. Camera Update / 6. Visual Effects
		self._camera:Render(dt, alpha, self._fw.State, self._strafeInput)
		self._adapter:Render(dt, alpha, self._camera:GetYaw())
	end)

	-- Authoritative snapshots (reconciliation scaffold; server echoes state today).
	self._transport:OnSnapshot(function(packet: buffer)
		MoveState.deserialize(self._serverState, packet, 0)
		local err = self._prediction:Reconcile(self._serverState, self._fw.State, self._fw.Simulator)
		if err > 0 then
			self._adapter:AbsorbCorrection(Vector3.zero)
		end
	end)
end

function MovementController.Destroy(self: ControllerInternal)
	self._transport:Destroy()
end

local function new(fw: Framework.MovementFramework, transport: Types.ITransport): MovementController
	return setmetatable({
		Name = "MovementController",
		Dependencies = { "InputService", "CameraService", "CharacterAdapter" },
		_fw = fw,
		_input = nil,
		_camera = nil,
		_adapter = nil,
		_debug = nil,
		_transport = transport,
		_cmd = InputCommand.new(),
		_prediction = PredictionBuffer.new(128, 3.0),
		_inputPacket = buffer.create(InputCommand.WIRE_BYTES),
		_serverState = MoveState.new(Vector3.zero),
		_bound = false,
		_strafeInput = 0,
	}, MovementController) :: any
end

return { new = new }
