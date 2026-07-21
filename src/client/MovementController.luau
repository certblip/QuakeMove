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
local Replay = require(ReplicatedStorage.MovementFramework.Networking.Replay)
local MoveState = require(ReplicatedStorage.MovementFramework.Simulation.MoveState)
local NetworkConfig = require(ReplicatedStorage.MovementFramework.Config.NetworkConfig)

export type MovementController = {
	Name: string,
	Dependencies: { string }?,
	Init: (self: MovementController, registry: any) -> (),
	Start: (self: MovementController) -> (),
	Destroy: (self: MovementController) -> (),
	-- Deterministic replay capture of the local player's run.
	GetReplayRecorder: (self: MovementController) -> Replay.ReplayRecorder,
	GetTransport: (self: MovementController) -> Types.ITransport,
}

type ControllerInternal = MovementController & {
	_fw: Framework.MovementFramework,
	_input: any,
	_camera: any,
	_adapter: any,
	_debug: any,
	_debugDraw: any,
	_transport: Types.ITransport,
	_cmd: Types.InputCommand,
	_prediction: PredictionBuffer.PredictionBuffer,
	_recorder: Replay.ReplayRecorder,
	_applyModifiers: (dt: number) -> (),
	-- Redundant input: the last N quantized commands (oldest -> newest) live in
	-- this pooled window and ALL ship in every packet (framing in InputCommand),
	-- so a single lost datagram cannot cost the server a tick.
	_inputHistory: { Types.InputCommand },
	_redundancy: number,
	_inputPacket: buffer, -- packetSize(redundancy) bytes, reused forever
	_scratch: buffer, -- one-command buffer for the quantize round-trip
	_serverState: Types.MoveState,
	_bound: boolean,
	_strafeInput: number,
	_conns: { RBXScriptConnection },
	-- Net-graph: RTT via a timestamp echoed by the server, plus per-second
	-- snapshot/correction rates accumulated over a 1s window.
	_rttMs: number,
	_snapshotCount: number,
	_snapsPerSec: number,
	_correctionCount: number,
	_corrPerSec: number,
	_netWindowStart: number,
	-- Newest server-time stamp from a snapshot tail; echoed back in the input
	-- packet header so the SERVER can measure this player's RTT for lag comp.
	_serverStampEcho: number,
	-- Feet-relative eye heights (см. Start): damped for smooth crouch dips.
	_eyeAboveFeet: number,
	_eyeStand: number,
	_eyeCrouch: number,
}

local MovementController = {}
MovementController.__index = MovementController

function MovementController.Init(self: ControllerInternal, registry: any)
	self._input = registry:Get("InputService")
	self._camera = registry:Get("CameraService")
	self._adapter = registry:Get("CharacterAdapter")
	self._debug = registry:TryGet("DebugOverlay")
	self._debugDraw = registry:TryGet("DebugRenderer")
end

function MovementController.GetReplayRecorder(self: ControllerInternal): Replay.ReplayRecorder
	return self._recorder
end

-- Shared transport handle so sibling services (remote-player interpolation)
-- can subscribe to the broadcast channel without owning a second connection.
function MovementController.GetTransport(self: ControllerInternal): Types.ITransport
	return self._transport
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

	-- Eye anchor measured from the FEET. state.position is always the standing
	-- box centre (the crouch hull shrinks from the top, so position never jumps
	-- on a stance change); feet therefore sit at position.Y - halfStand always.
	-- _eyeAboveFeet is damped toward the pose target in the render callback, so
	-- ducking reads as a smooth dip rather than a snap.
	local halfStand = profile.ColliderSize.Y * 0.5
	self._eyeStand = halfStand + profile.EyeHeight
	-- Crouched eye: feet + (crouch hull height) - a bit, via CrouchEyeHeight
	-- measured above the crouched box centre, which sits halfCrouch off the feet.
	self._eyeCrouch = profile.CrouchColliderHeight * 0.5 + profile.CrouchEyeHeight
	self._eyeAboveFeet = self._eyeStand
	self._camera:SetEyeAnchor(function(): Vector3
		local s = self._fw.State
		local feetY = s.position.Y - halfStand
		return Vector3.new(s.position.X, feetY + self._eyeAboveFeet, s.position.Z)
	end)

	if player.Character then
		bindCharacter(self, player.Character)
	end
	table.insert(self._conns, player.CharacterAdded:Connect(function(character: Model)
		bindCharacter(self, character)
	end))
	table.insert(self._conns, player.CharacterRemoving:Connect(function()
		-- Death/despawn: stop simulating and writing CFrames into a corpse;
		-- CharacterAdded rebinds on respawn.
		self._bound = false
		self._adapter:Unbind()
	end))

	-- FIXED STEP: the deterministic pipeline.
	self._fw.Scheduler:RegisterFixed(100, function(tick: number, dt: number)
		-- UI-layer toggles must run even while the sim is disabled: replay
		-- playback calls fw:Disable() and the player still needs mouse (G)
		-- and debug (F3) control to operate the panel.
		if self._input:GetDebugToggled() then
			self._fw:SetDebug(not self._fw:IsDebug())
			if self._debug then
				self._debug:SetVisible(self._fw:IsDebug())
			end
		end
		if self._input:GetMouseToggled() then
			self._camera:ToggleMouseLock()
		end

		if not self._fw:IsEnabled() or not self._bound then
			return
		end
		local t0 = os.clock()

		-- 1. Input Collection
		self._input:BuildCommand(self._cmd, tick, dt, self._camera:GetYaw(), self._camera:GetPitch())

		-- Quantize through the wire format BEFORE simulating: the command we
		-- predict with must be bit-identical to the one the server will
		-- deserialize (i8 axes, f32 angles), or every tick drifts slightly and
		-- reconciliation never settles. dt keeps the exact f64 fixed step -
		-- the server enforces the same constant on its side.
		InputCommand.serialize(self._cmd, self._scratch, 0)
		InputCommand.deserialize(self._cmd, self._scratch, 0)
		self._cmd.dt = dt
		self._strafeInput = self._cmd.moveX

		-- 2/3/4. Simulation + Physics + Resolution
		self._fw.Simulator:Step(self._fw.State, self._cmd)

		-- Modifiers (jump pads, zones) run after the deterministic core.
		self._fw:ApplyModifiers(dt)

		-- Prediction bookkeeping + replication (unreliable input up).
		self._prediction:Record(self._cmd, self._fw.State)
		if self._recorder:IsRecording() then
			self._recorder:Record(self._cmd)
		end

		-- Redundant input: slide the window (oldest drops, newest quantized
		-- command enters at the end), then ship all N. The server's monotonic
		-- tick gate discards the overlap for free, so a dropped packet is
		-- healed by the next one instead of costing a tick.
		local hist = self._inputHistory
		local n = self._redundancy
		local oldest = hist[1]
		table.move(hist, 2, n, 1)
		hist[n] = oldest
		InputCommand.copyInto(oldest, self._cmd)
		buffer.writeu8(self._inputPacket, 0, n)
		-- Echo the server's newest stamp (lag-comp RTT; see packet framing).
		buffer.writeu32(self._inputPacket, 1, self._serverStampEcho)
		for i = 1, n do
			InputCommand.serialize(hist[i], self._inputPacket, InputCommand.commandOffset(i))
		end
		-- Net-graph RTT: stamp send-time (ms, u32 wrap) into the newest
		-- command's reserved field; the server echoes it after the snapshot.
		-- Transport metadata only - never part of the simulated command.
		local nowMs = math.floor(os.clock() * 1000) % 4294967296
		buffer.writeu32(self._inputPacket, InputCommand.commandOffset(n) + 19, nowMs)
		self._transport:SendInput(self._inputPacket)

		self._adapter:OnTickCommitted(self._fw.State)

		-- Net-graph: convert accumulated counts to per-second rates once a
		-- second (a stable readout instead of a flickering per-tick number).
		local elapsed = os.clock() - self._netWindowStart
		if elapsed >= 1 then
			self._snapsPerSec = self._snapshotCount / elapsed
			self._corrPerSec = self._correctionCount / elapsed
			self._snapshotCount = 0
			self._correctionCount = 0
			self._netWindowStart = os.clock()
		end

		if self._debug and self._fw:IsDebug() then
			self._debug:SetSimTime(math.round((os.clock() - t0) * 1e6))
			self._debug:SetNetworkStats(self._rttMs, self._prediction:GetLastError(), self._snapsPerSec, self._corrPerSec)
			self._debug:Update(self._fw.State)
		end
	end)

	-- RENDER: camera + visual interpolation. Never mutates simulation state.
	self._fw.Scheduler:RegisterRender(100, function(dt: number, alpha: number)
		if not self._bound then
			return
		end
		-- Damp the feet-relative eye height so ducking reads as a smooth dip:
		-- the sim's centre jump is invisible because the anchor is feet-based.
		local targetEye = if self._fw.State.crouching then self._eyeCrouch else self._eyeStand
		self._eyeAboveFeet += (targetEye - self._eyeAboveFeet) * (1 - math.exp(-14 * dt))
		-- 5. Camera Update / 6. Visual Effects
		self._camera:Render(dt, alpha, self._fw.State, self._strafeInput)
		self._adapter:Render(dt, alpha, self._camera:GetYaw())
	end)

	-- Authoritative snapshots: rollback + input replay + correction smoothing.
	self._transport:OnSnapshot(function(packet: buffer)
		MoveState.deserialize(self._serverState, packet, 0)
		self._snapshotCount += 1
		-- Net-graph RTT: the server echoed our send-stamp in the snapshot
		-- tail; the second u32 is the SERVER's stamp we must echo back.
		if buffer.len(packet) >= MoveState.SNAPSHOT_BYTES + InputCommand.SNAPSHOT_TAIL_BYTES then
			local stamp = buffer.readu32(packet, MoveState.SNAPSHOT_BYTES)
			local nowMs = math.floor(os.clock() * 1000) % 4294967296
			local rtt = (nowMs - stamp) % 4294967296
			if rtt < 60000 then -- ignore absurd values (clock reset / stale)
				-- EMA smooths the jitter into a readable number.
				self._rttMs += (rtt - self._rttMs) * 0.2
			end
			self._serverStampEcho = buffer.readu32(packet, MoveState.SNAPSHOT_BYTES + 4)
		end
		local before = self._fw.State.position
		local err =
			self._prediction:Reconcile(self._serverState, self._fw.State, self._fw.Simulator, self._applyModifiers)
		if err > 0 then
			self._correctionCount += 1
			-- Resync interpolation targets to the corrected state, then hand
			-- the adapter the visual delta so it can decay the pop instead of
			-- snapping the character.
			self._adapter:OnTickCommitted(self._fw.State)
			self._adapter:AbsorbCorrection(before - self._fw.State.position)
			if self._debugDraw then
				self._debugDraw:NotifyCorrection(before, self._fw.State.position)
			end
		end
	end)
end

function MovementController.Destroy(self: ControllerInternal)
	for _, conn in self._conns do
		conn:Disconnect()
	end
	table.clear(self._conns)
	self._transport:Destroy()
end

local function new(fw: Framework.MovementFramework, transport: Types.ITransport): MovementController
	local net = NetworkConfig.Default
	local self: ControllerInternal = setmetatable({
		Name = "MovementController",
		Dependencies = { "InputService", "CameraService", "CharacterAdapter" },
		_fw = fw,
		_input = nil,
		_camera = nil,
		_adapter = nil,
		_debug = nil,
		_debugDraw = nil,
		_transport = transport,
		_cmd = InputCommand.new(),
		_prediction = PredictionBuffer.new(net.PredictionCapacity, net.PositionTolerance),
		_recorder = Replay.newRecorder(net.ReplayCapacity),
		_applyModifiers = nil :: any,
		_inputHistory = (function()
			local n = math.clamp(net.InputRedundancy, 1, 4)
			local hist = table.create(n)
			for i = 1, n do
				hist[i] = InputCommand.new()
			end
			return hist
		end)(),
		_redundancy = math.clamp(net.InputRedundancy, 1, 4),
		_inputPacket = buffer.create(InputCommand.packetSize(math.clamp(net.InputRedundancy, 1, 4))),
		_scratch = buffer.create(InputCommand.WIRE_BYTES),
		_serverState = MoveState.new(Vector3.zero),
		_bound = false,
		_strafeInput = 0,
		_conns = {},
		_rttMs = 0,
		_snapshotCount = 0,
		_snapsPerSec = 0,
		_correctionCount = 0,
		_corrPerSec = 0,
		_netWindowStart = os.clock(),
		_serverStampEcho = 0,
		_eyeAboveFeet = 0, -- set from the profile in Start
		_eyeStand = 0,
		_eyeCrouch = 0,
	}, MovementController) :: any
	-- One closure for the whole session: reconciliation replays modifiers
	-- through it without allocating per-snapshot.
	self._applyModifiers = function(dt: number)
		self._fw:ApplyModifiers(dt)
	end
	return self
end

return { new = new }
