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
	Performance: Steps run on the shared fixed scheduler; snapshot buffers are
	pooled per player. Input is validated (dt clamp, tick monotonicity) to reject
	speed-hack style malformed commands.
	Extension: Anti-cheat position/velocity bounds and lag-compensated hit
	registration hook in at ProcessInput without touching movement math.
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
local Transport = require(ReplicatedStorage.MovementFramework.Networking.Transport)
local NetworkConfig = require(ReplicatedStorage.MovementFramework.Config.NetworkConfig)

export type ServerMovementService = {
	Name: string,
	Dependencies: { string }?,
	Init: (self: ServerMovementService, registry: any) -> (),
	Start: (self: ServerMovementService) -> (),
	Destroy: (self: ServerMovementService) -> (),
}

type PlayerSim = {
	state: Types.MoveState,
	scratch: Types.InputCommand, -- deserialize target; rejected packets never corrupt the queue
	queue: RingBuffer.RingBuffer<Types.InputCommand>, -- validated commands awaiting simulation
	free: { Types.InputCommand }, -- recycled command tables (zero steady-state allocation)
	snapshot: buffer,
	lastTick: number, -- newest simulated tick
	newestQueued: number, -- newest accepted tick (monotonicity gate)
	character: Model?,
}

type ServiceInternal = ServerMovementService & {
	_fw: Framework.MovementFramework,
	_profile: MovementConfig.MovementProfile,
	_simulator: Simulator.Simulator,
	_collision: Collision.CollisionWorld,
	_transport: Transport.ServerTransport,
	_players: { [Player]: PlayerSim },
	_conns: { RBXScriptConnection },
}

local ServerMovementService = {}
ServerMovementService.__index = ServerMovementService

-- The server dictates the simulation timestep. The wire dt is never trusted:
-- honouring a client-supplied dt is a time-dilation (speed hack) vector.
-- Must match the FixedRate the bootstraps pass to Framework.create (60).
local FIXED_DT = 1 / 60

local function onPlayerAdded(self: ServiceInternal, player: Player)
	local sim: PlayerSim = {
		state = MoveState.new(Vector3.new(0, 10, 0)),
		scratch = InputCommand.new(),
		queue = RingBuffer.new(NetworkConfig.Default.InputQueueCapacity),
		free = {},
		snapshot = buffer.create(MoveState.SNAPSHOT_BYTES),
		lastTick = 0,
		newestQueued = 0,
		character = nil,
	}
	self._players[player] = sim

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
	end)
end

local function onPlayerRemoving(self: ServiceInternal, player: Player)
	self._players[player] = nil
end

local function isFinite(n: number): boolean
	-- NaN fails self-equality; the explicit huge checks reject +/-Inf.
	return n == n and n ~= math.huge and n ~= -math.huge
end

-- Validate + enqueue. Buffering (instead of keep-latest) is what makes the
-- reconciliation loop stable under jitter: two packets arriving in one
-- heartbeat both simulate, so the server tick never falls behind the client's.
local function processInput(self: ServiceInternal, player: Player, packet: buffer)
	local sim = self._players[player]
	if not sim then
		return
	end
	if buffer.len(packet) < InputCommand.WIRE_BYTES then
		return
	end
	-- Deserialize into a scratch command first: a rejected packet (stale,
	-- reordered, tampered) must never corrupt already-validated commands.
	local staged = sim.scratch
	InputCommand.deserialize(staged, packet, 0)

	-- Reject tampered view angles. A single NaN yaw poisons wishDir ->
	-- position -> Blockcast and would error the shared fixed-step loop.
	-- (moveX/moveZ/buttons/tick decode from i8/u8/u32 and are always finite.)
	if not (isFinite(staged.yaw) and isFinite(staged.pitch)) then
		return
	end

	-- Monotonicity gate: rejects duplicates and UDP reordering in one check.
	if staged.tick <= sim.newestQueued or staged.tick <= sim.lastTick then
		return
	end
	sim.newestQueued = staged.tick

	staged.dt = FIXED_DT -- server-dictated timestep; never trust the wire

	local cmd = table.remove(sim.free) or InputCommand.new()
	InputCommand.copyInto(cmd, staged)
	local evicted = sim.queue:Push(cmd)
	if evicted then
		-- Queue overflow (client bursting faster than we drain): drop the
		-- oldest command and recycle its table.
		table.insert(sim.free, evicted)
	end
end

local MAX_COMMANDS_PER_TICK = NetworkConfig.Default.MaxCommandsPerTick

local function stepPlayer(self: ServiceInternal, player: Player, sim: PlayerSim)
	if not sim.character then
		return
	end
	-- Point the shared collision world at this player's world (ignore own body).
	self._collision:SetIgnoreCharacter(sim.character)

	-- Drain a bounded burst: 1 command in the steady state, more only to
	-- absorb network jitter. The cap prevents a hoarding client from
	-- simulating faster than real time (time-dilation exploit).
	local processed = false
	local lastYaw = 0
	for _ = 1, MAX_COMMANDS_PER_TICK do
		local cmd = sim.queue:Pop()
		if cmd == nil then
			break
		end
		sim.lastTick = cmd.tick
		lastYaw = cmd.yaw
		self._simulator:Step(sim.state, cmd)
		-- Modifier parity: the client applies modifiers after every predicted
		-- tick, so the authoritative sim must run the SAME ordered list here
		-- (register identical modifiers on both bootstraps).
		self._fw:ApplyModifiersTo(sim.state, FIXED_DT)
		table.insert(sim.free, cmd)
		processed = true
	end
	if not processed then
		return
	end

	-- Reflect authoritative transform onto the server character container.
	local root = sim.character:FindFirstChild("HumanoidRootPart") :: BasePart?
	if root then
		root.CFrame = CFrame.new(sim.state.position) * CFrame.Angles(0, lastYaw, 0)
	end

	-- Reply with authoritative snapshot (reconciliation input for the client).
	MoveState.serialize(sim.state, sim.snapshot, 0)
	self._transport:SendSnapshot(player, sim.snapshot)
end

function ServerMovementService.Init(self: ServiceInternal, _registry: any)
	self._collision = Collision.new(self._profile.ColliderSize)
	self._simulator = Simulator.new(self._profile, self._collision.Trace)
	self._transport = Transport.newServer()
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

	-- Single fixed-step callback drains every player's staged command.
	self._fw.Scheduler:RegisterFixed(50, function(_tick: number, _dt: number)
		for player, sim in self._players do
			stepPlayer(self, player, sim)
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
		_conns = {},
	}, ServerMovementService) :: any
end

return { new = new }
