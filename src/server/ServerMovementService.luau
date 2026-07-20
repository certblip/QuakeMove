--!strict
--[[
	ServerMovementService.luau
	Purpose: Authoritative server-side movement. Receives client input packets,
	re-simulates each player's movement with the SAME deterministic Simulator and
	the same collision world, then streams authoritative snapshots back. This is the
	server half of the client-prediction contract; because both sides run identical
	code over identical InputCommands, predictions match the server barring packet
	loss or tampering.
	Architecture notes: One Simulator + Collision world per session (stateless
	between players via SetTrace/SetIgnoreCharacter swap before each step). Per-player
	MoveState lives in a table keyed by Player. No RemoteEvent knowledge leaks past
	the Transport abstraction.
	Networking: redundant input (last N commands per packet, healed by the tick
	gate), a 30 Hz pose broadcast for remote-player interpolation, bidirectional
	RTT echo, and lag-compensated pose history for fair hit registration.
	Performance: Steps run on the shared fixed scheduler; snapshot buffers are
	pooled per player. Input is validated (dt clamp, tick monotonicity) to reject
	speed-hack style malformed commands.
]]

local Players = game:GetService("Players")

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Framework = require(ReplicatedStorage:WaitForChild("MovementFramework"))
local Types = require(ReplicatedStorage.MovementFramework.Core.Types)
local MovementConfig = require(ReplicatedStorage.MovementFramework.Config.MovementConfig)

local Collision = require(ReplicatedStorage.MovementFramework.Simulation.Collision)
local Simulator = require(ReplicatedStorage.MovementFramework.Simulation.Simulator)
local MoveState = require(ReplicatedStorage.MovementFramework.Simulation.MoveState)
local InputCommand = require(ReplicatedStorage.MovementFramework.Networking.InputCommand)
local RingBuffer = require(ReplicatedStorage.MovementFramework.Networking.RingBuffer)
local LagCompensation = require(ReplicatedStorage.MovementFramework.Networking.LagCompensation)
local Transport = require(ReplicatedStorage.MovementFramework.Networking.Transport)
local NetworkConfig = require(ReplicatedStorage.MovementFramework.Config.NetworkConfig)

export type ServerMovementService = {
	Name: string,
	Dependencies: { string }?,
	Init: (self: ServerMovementService, registry: any) -> (),
	Start: (self: ServerMovementService) -> (),
	Destroy: (self: ServerMovementService) -> (),
	-- Lag compensation (fair hit registration). A weapon system calls
	-- RewindRaycast; the service rewinds every OTHER player to where the
	-- shooter saw them (interp delay + half their measured RTT, capped) and
	-- intersects the ray against the pose-correct hull.
	RewindRaycast: (
		self: ServerMovementService,
		shooter: Player,
		origin: Vector3,
		direction: Vector3,
		maxDistance: number
	) -> (Player?, Vector3?, number?),
	-- Lower-level hooks for custom hit logic / tests.
	GetRewindTick: (self: ServerMovementService, shooter: Player) -> number,
	GetPositionAt: (self: ServerMovementService, player: Player, atTick: number) -> (Vector3?, boolean),
	GetRttMs: (self: ServerMovementService, player: Player) -> number,
}

type PlayerSim = {
	state: Types.MoveState,
	scratch: Types.InputCommand, -- deserialize target; rejected packets never corrupt the queue
	queue: RingBuffer.RingBuffer<Types.InputCommand>, -- validated commands awaiting simulation
	free: { Types.InputCommand }, -- recycled command tables (zero steady-state allocation)
	snapshot: buffer,
	lastTick: number, -- newest simulated tick
	newestQueued: number, -- newest accepted tick (monotonicity gate)
	lastYaw: number, -- last simulated view yaw (broadcast to other clients)
	lastClientStamp: number, -- newest client send-time stamp (ms) to echo back
	rttMs: number, -- SERVER-measured smoothed RTT (drives lag-comp rewind depth)
	character: Model?,
}

-- Broadcast packet: u8 playerCount, then per player 25 bytes
-- [f64 userId][3xf32 pos][f32 yaw][u8 stateId]. Capped so the packet stays
-- comfortably under the unreliable MTU (~900B): 35 * 25 + 1 = 876 bytes.
local BROADCAST_STRIDE = 25
local MAX_BROADCAST_PLAYERS = 35
local BROADCAST_HZ = 30

local NET = NetworkConfig.Default
local FIXED_DT = 1 / 60 -- server-dictated timestep; the wire dt is never trusted
local MAX_COMMANDS_PER_TICK = NET.MaxCommandsPerTick
local SNAPSHOT_BYTES = MoveState.SNAPSHOT_BYTES + InputCommand.SNAPSHOT_TAIL_BYTES

type ServiceInternal = ServerMovementService & {
	_fw: Framework.MovementFramework,
	_profile: MovementConfig.MovementProfile,
	_simulator: Simulator.Simulator,
	_collision: Collision.CollisionWorld,
	_transport: Transport.ServerTransport,
	_players: { [Player]: PlayerSim },
	_byUserId: { [number]: Player }, -- reverse map for lag-comp hit results
	_lagComp: LagCompensation.LagCompensation,
	_conns: { RBXScriptConnection },
	_broadcastBuf: buffer,
	_packetScratch: { [number]: buffer },
}

local ServerMovementService = {}
ServerMovementService.__index = ServerMovementService

local function onPlayerAdded(self: ServiceInternal, player: Player)
	local sim: PlayerSim = {
		state = MoveState.new(Vector3.new(0, 10, 0)),
		scratch = InputCommand.new(),
		queue = RingBuffer.new(NET.InputQueueCapacity),
		free = {},
		snapshot = buffer.create(SNAPSHOT_BYTES),
		lastTick = 0,
		newestQueued = 0,
		lastYaw = 0,
		lastClientStamp = 0,
		rttMs = 0,
		character = nil,
	}
	self._players[player] = sim
	self._byUserId[player.UserId] = player

	player.CharacterAdded:Connect(function(character: Model)
		sim.character = character
		local root = character:WaitForChild("HumanoidRootPart") :: BasePart
		local humanoid = character:WaitForChild("Humanoid") :: Humanoid
		-- The server owns the truth: freezing engine physics on the container
		-- lets per-tick CFrame writes replicate cleanly to every other client
		-- instead of fighting the Humanoid state machine between snapshots.
		humanoid.EvaluateStateMachine = false
		root.Anchored = true
		sim.state = MoveState.new(root.Position)
		sim.lastTick = 0
		sim.newestQueued = 0
		sim.queue:Clear()
		-- Stale poses from the previous life must never validate a hit.
		self._lagComp:Remove(player.UserId)
	end)
	player.CharacterRemoving:Connect(function()
		sim.character = nil
		-- A despawned body is not shootable; drop its timeline immediately.
		self._lagComp:Remove(player.UserId)
	end)
end

local function onPlayerRemoving(self: ServiceInternal, player: Player)
	self._players[player] = nil
	self._byUserId[player.UserId] = nil
	self._lagComp:Remove(player.UserId)
end

local function isFinite(n: number): boolean
	-- NaN fails self-equality; the explicit huge checks reject +/-Inf.
	return n == n and n ~= math.huge and n ~= -math.huge
end

-- Validates + enqueues ONE command already deserialized into sim.scratch.
local function acceptStaged(sim: PlayerSim)
	local staged = sim.scratch
	if not (isFinite(staged.yaw) and isFinite(staged.pitch)) then
		return
	end
	-- Monotonicity gate: rejects duplicates and UDP reordering in one check.
	-- It is ALSO what makes redundant input free: the overlapping copies
	-- re-sent in every packet fail this test, and only genuinely new ticks
	-- (including ones whose original packet was lost) get through.
	if staged.tick <= sim.newestQueued or staged.tick <= sim.lastTick then
		return
	end
	sim.newestQueued = staged.tick
	staged.dt = FIXED_DT

	local cmd = table.remove(sim.free) or InputCommand.new()
	InputCommand.copyInto(cmd, staged)
	local evicted = sim.queue:Push(cmd)
	if evicted then
		table.insert(sim.free, evicted)
	end
end

-- Redundant-input packet: [u8 count][u32 serverStampEcho][InputCommand * count],
-- oldest -> newest. Oldest-first lets the tick gate admit new ticks in order
-- while the redundant overlap dies at the gate.
local function processInput(self: ServiceInternal, player: Player, packet: buffer)
	local sim = self._players[player]
	if not sim then
		return
	end
	local len = buffer.len(packet)
	if len < InputCommand.packetSize(1) then
		return
	end
	local count = buffer.readu8(packet, 0)
	-- Clamp to what the buffer physically holds: a tampered oversized count
	-- must never read past the packet (that would error the event handler).
	local maxFit = math.floor((len - InputCommand.PACKET_HEADER_BYTES) / InputCommand.WIRE_BYTES)
	if count > maxFit then
		count = maxFit
	end
	if count < 1 then
		return
	end

	-- SERVER-measured RTT: the client echoed our newest server stamp in the
	-- packet header. now - echo = round trip, in server-clock ms. This is the
	-- authoritative latency for rewind depth - a client-reported ping is a
	-- cheat vector (inflate it to shoot further into the past).
	local echo = buffer.readu32(packet, 1)
	if echo ~= 0 then
		local nowMs = math.floor(os.clock() * 1000) % 4294967296
		local rtt = (nowMs - echo) % 4294967296
		if rtt < 60000 then
			sim.rttMs += (rtt - sim.rttMs) * 0.2 -- EMA
		end
	end

	for i = 1, count do
		InputCommand.deserialize(sim.scratch, packet, InputCommand.commandOffset(i))
		acceptStaged(sim)
	end
end

local function stepPlayer(self: ServiceInternal, player: Player, sim: PlayerSim, serverTick: number)
	if not sim.character then
		return
	end
	self._collision:SetIgnoreCharacter(sim.character)

	-- Drain a bounded burst: 1 command in the steady state, more only to
	-- absorb network jitter. The cap prevents a hoarding client from
	-- simulating faster than real time (time-dilation exploit).
	local processed = false
	local lastYaw = sim.lastYaw
	for _ = 1, MAX_COMMANDS_PER_TICK do
		local cmd = sim.queue:Pop()
		if cmd == nil then
			break
		end
		sim.lastTick = cmd.tick
		lastYaw = cmd.yaw
		self._simulator:Step(sim.state, cmd)
		-- Modifier parity: the client applies modifiers after every predicted
		-- tick, so the authoritative sim runs the SAME ordered list here.
		self._fw:ApplyModifiersTo(sim.state, FIXED_DT)
		table.insert(sim.free, cmd)
		processed = true
	end

	-- Record the authoritative pose EVERY server tick (dense, contiguous
	-- history => exact rewind sampling). Idle ticks simply re-record the
	-- unchanged pose so the rewind window has no gaps.
	self._lagComp:Record(player.UserId, serverTick, sim.state.position, sim.state.crouching)

	if not processed then
		return
	end
	sim.lastYaw = lastYaw

	-- Reflect authoritative transform onto the server character container.
	local root = sim.character:FindFirstChild("HumanoidRootPart") :: BasePart?
	if root then
		root.CFrame = CFrame.new(sim.state.position) * CFrame.Angles(0, lastYaw, 0)
	end

	-- Snapshot tail: [u32 clientStampEcho][u32 serverStampMs]. The first echoes
	-- the client's send time (its net-graph RTT); the second is our own clock,
	-- which the client echoes back so WE can measure RTT for lag comp.
	MoveState.serialize(sim.state, sim.snapshot, 0)
	buffer.writeu32(sim.snapshot, MoveState.SNAPSHOT_BYTES, sim.lastClientStamp)
	buffer.writeu32(sim.snapshot, MoveState.SNAPSHOT_BYTES + 4, math.floor(os.clock() * 1000) % 4294967296)
	self._transport:SendSnapshot(player, sim.snapshot)
end

local function broadcastPoses(self: ServiceInternal)
	local buf = self._broadcastBuf
	local count = 0
	for player, sim in self._players do
		if count >= MAX_BROADCAST_PLAYERS then
			break
		end
		if sim.character and sim.lastTick > 0 then
			local base = 1 + count * BROADCAST_STRIDE
			buffer.writef64(buf, base, player.UserId)
			local pos = sim.state.position
			buffer.writef32(buf, base + 8, pos.X)
			buffer.writef32(buf, base + 12, pos.Y)
			buffer.writef32(buf, base + 16, pos.Z)
			buffer.writef32(buf, base + 20, sim.lastYaw)
			buffer.writeu8(buf, base + 24, sim.state.stateId)
			count += 1
		end
	end
	if count == 0 then
		return
	end
	buffer.writeu8(buf, 0, count)
	local packetLen = 1 + count * BROADCAST_STRIDE
	local packet = self._packetScratch[count]
	if packet == nil then
		packet = buffer.create(packetLen)
		self._packetScratch[count] = packet
	end
	buffer.copy(packet, 0, buf, 0, packetLen)
	self._transport:Broadcast(packet)
end

--------------------------------------------------------------------------------
-- Lag compensation API
--------------------------------------------------------------------------------

-- Server tick the shooter "saw" the world at: now, minus the interpolation
-- delay remote bodies render behind, minus half their RTT (one-way trip),
-- clamped to the fair window. Fractional - GetPositionAt lerps between ticks.
function ServerMovementService.GetRewindTick(self: ServiceInternal, shooter: Player): number
	local sim = self._players[shooter]
	local rewindSeconds = NET.RemoteInterpDelay
	if sim then
		rewindSeconds += (sim.rttMs * 0.5) / 1000
	end
	local rewindTicks = math.min(rewindSeconds, NET.MaxRewindSeconds) / FIXED_DT
	return self._lagComp:ClampTick(self._lagComp:CurrentTick() - rewindTicks)
end

function ServerMovementService.GetPositionAt(
	self: ServiceInternal,
	player: Player,
	atTick: number
): (Vector3?, boolean)
	return self._lagComp:GetPositionAt(player.UserId, atTick)
end

function ServerMovementService.GetRttMs(self: ServiceInternal, player: Player): number
	local sim = self._players[player]
	return if sim then sim.rttMs else 0
end

-- Lag-compensated hitscan. Rewinds every OTHER player to the tick the shooter
-- aimed at and intersects the ray with the pose-correct hull (crouch-aware
-- AABB). Returns the nearest (player, point, distance).
function ServerMovementService.RewindRaycast(
	self: ServiceInternal,
	shooter: Player,
	origin: Vector3,
	direction: Vector3,
	maxDistance: number
): (Player?, Vector3?, number?)
	local atTick = self:GetRewindTick(shooter)
	local hitId, point, dist = self._lagComp:RaycastAt(atTick, origin, direction, maxDistance, shooter.UserId)
	if hitId == nil then
		return nil, nil, nil
	end
	return self._byUserId[hitId :: number], point, dist
end

--------------------------------------------------------------------------------

function ServerMovementService.Init(self: ServiceInternal, _registry: any)
	self._collision =
		Collision.new(self._profile.ColliderSize, self._profile.CrouchColliderHeight / self._profile.ColliderSize.Y)
	self._simulator = Simulator.new(self._profile, self._collision.Trace)
	self._transport = Transport.newServer()
	-- History must cover the deepest allowed rewind; the cap itself bounds how
	-- far a laggy shooter can drag everyone into the past.
	local maxRewindTicks = math.min(NET.LagCompHistoryTicks, math.ceil(NET.MaxRewindSeconds / FIXED_DT))
	self._lagComp = LagCompensation.new(
		NET.LagCompHistoryTicks,
		maxRewindTicks,
		self._profile.ColliderSize,
		self._profile.CrouchColliderHeight
	)
end

function ServerMovementService.Start(self: ServiceInternal)
	for _, player in Players:GetPlayers() do
		onPlayerAdded(self, player)
	end
	table.insert(self._conns, Players.PlayerAdded:Connect(function(player: Player)
		onPlayerAdded(self, player)
	end))
	table.insert(self._conns, Players.PlayerRemoving:Connect(function(player: Player)
		onPlayerRemoving(self, player)
	end))

	self._transport:OnInput(function(player: Player, packet: buffer)
		processInput(self, player, packet)
	end)

	local broadcastDivisor = math.max(1, math.floor(60 / BROADCAST_HZ))
	self._fw.Scheduler:RegisterFixed(50, function(tick: number, _dt: number)
		for player, sim in self._players do
			stepPlayer(self, player, sim, tick)
		end
		if tick % broadcastDivisor == 0 then
			broadcastPoses(self)
		end
	end)
end

function ServerMovementService.Destroy(self: ServiceInternal)
	for _, conn in self._conns do
		conn:Disconnect()
	end
	table.clear(self._conns)
	self._transport:Destroy()
	table.clear(self._players)
end

local function new(
	fw: Framework.MovementFramework,
	profile: MovementConfig.MovementProfile
): ServerMovementService
	return setmetatable({
		Name = "ServerMovementService",
		Dependencies = nil,
		_fw = fw,
		_profile = profile,
		_simulator = nil :: any,
		_collision = nil :: any,
		_transport = nil :: any,
		_players = {},
		_byUserId = {},
		_lagComp = nil :: any,
		_conns = {},
		_broadcastBuf = buffer.create(1 + MAX_BROADCAST_PLAYERS * BROADCAST_STRIDE),
		_packetScratch = {},
	}, ServerMovementService) :: any
end

return { new = new }
