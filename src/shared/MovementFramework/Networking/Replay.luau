--!strict
--[[
	Replay.luau
	Purpose: Deterministic replay. Records ONLY the starting MoveState plus the
	per-tick InputCommand stream; playback re-simulates through the same
	Simulator, so 23 bytes per tick reproduce an entire run bit-identically.
	Positions are never stored - determinism IS the storage format.
	Architecture notes: Engine-free (plain tables + the buffer library), so
	replays record on client or server and validate in unit tests. Command
	slots are pooled: re-recording over an old replay allocates nothing.
	Wire format: [u32 commandCount][MoveState snapshot][InputCommand * count].
]]

local Types = require(script.Parent.Parent.Core.Types)
local MoveState = require(script.Parent.Parent.Simulation.MoveState)
local Simulator = require(script.Parent.Parent.Simulation.Simulator)
local InputCommand = require(script.Parent.InputCommand)

export type Replay = {
	startState: Types.MoveState,
	commands: { Types.InputCommand },
	count: number,
}

export type ReplayRecorder = {
	Begin: (self: ReplayRecorder, state: Types.MoveState) -> (),
	Record: (self: ReplayRecorder, cmd: Types.InputCommand) -> (),
	IsRecording: (self: ReplayRecorder) -> boolean,
	Finish: (self: ReplayRecorder) -> Replay?,
	Capacity: (self: ReplayRecorder) -> number,
}

export type ReplayPlayer = {
	Begin: (self: ReplayPlayer, replay: Replay, outState: Types.MoveState) -> (),
	-- Advances one tick; returns false when the stream is exhausted.
	Advance: (self: ReplayPlayer, simulator: Simulator.Simulator, state: Types.MoveState) -> boolean,
	-- The command consumed by the last Advance (view angles / buttons for
	-- camera + HUD playback). Read-only; aliases the replay's storage.
	GetCurrentCommand: (self: ReplayPlayer) -> Types.InputCommand?,
	IsPlaying: (self: ReplayPlayer) -> boolean,
	Stop: (self: ReplayPlayer) -> (),
}

local Replay = {}

--------------------------------------------------------------------------------
-- Recorder
--------------------------------------------------------------------------------

type RecorderInternal = ReplayRecorder & {
	_start: Types.MoveState,
	_commands: { Types.InputCommand },
	_count: number,
	_capacity: number,
	_recording: boolean,
	_view: Replay,
}

local Recorder = {}
Recorder.__index = Recorder

function Recorder.Begin(self: RecorderInternal, state: Types.MoveState)
	MoveState.copyInto(self._start, state)
	self._count = 0
	self._recording = true
end

function Recorder.Record(self: RecorderInternal, cmd: Types.InputCommand)
	if not self._recording or self._count >= self._capacity then
		return -- full: silently stop growing; Finish still yields the head
	end
	self._count += 1
	local slot = self._commands[self._count]
	if slot == nil then
		slot = InputCommand.new() -- lazily grown once, recycled forever after
		self._commands[self._count] = slot
	end
	InputCommand.copyInto(slot, cmd)
end

function Recorder.IsRecording(self: RecorderInternal): boolean
	return self._recording
end

function Recorder.Capacity(self: RecorderInternal): number
	return self._capacity
end

function Recorder.Finish(self: RecorderInternal): Replay?
	if not self._recording then
		return nil
	end
	self._recording = false
	if self._count == 0 then
		return nil
	end
	-- The view aliases the recorder's pooled storage: starting a new recording
	-- invalidates it. Serialize (below) to persist beyond that.
	local view = self._view
	view.count = self._count
	return view
end

function Replay.newRecorder(capacity: number): ReplayRecorder
	assert(capacity > 0, "capacity must be positive")
	local start = MoveState.new(Vector3.zero)
	local commands: { Types.InputCommand } = table.create(capacity)
	local self: RecorderInternal = setmetatable({
		_start = start,
		_commands = commands,
		_count = 0,
		_capacity = capacity,
		_recording = false,
		_view = { startState = start, commands = commands, count = 0 } :: Replay,
	}, Recorder) :: any
	return self
end

--------------------------------------------------------------------------------
-- Player
--------------------------------------------------------------------------------

type PlayerInternal = ReplayPlayer & {
	_replay: Replay?,
	_cursor: number,
}

local Player = {}
Player.__index = Player

function Player.Begin(self: PlayerInternal, replay: Replay, outState: Types.MoveState)
	self._replay = replay
	self._cursor = 0
	-- Playback starts from the recorded state, NOT the live one - that is the
	-- entire determinism contract.
	MoveState.copyInto(outState, replay.startState)
end

function Player.Advance(self: PlayerInternal, simulator: Simulator.Simulator, state: Types.MoveState): boolean
	local replay = self._replay
	if replay == nil then
		return false
	end
	if self._cursor >= replay.count then
		self._replay = nil
		return false
	end
	self._cursor += 1
	simulator:Step(state, replay.commands[self._cursor])
	return true
end

function Player.GetCurrentCommand(self: PlayerInternal): Types.InputCommand?
	local replay = self._replay
	if replay == nil or self._cursor < 1 then
		return nil
	end
	return replay.commands[self._cursor]
end

function Player.IsPlaying(self: PlayerInternal): boolean
	return self._replay ~= nil
end

function Player.Stop(self: PlayerInternal)
	self._replay = nil
	self._cursor = 0
end

function Replay.newPlayer(): ReplayPlayer
	return setmetatable({ _replay = nil, _cursor = 0 }, Player) :: any
end

--------------------------------------------------------------------------------
-- Full-run helper (tests / validation) and serialization
--------------------------------------------------------------------------------

-- Runs the whole replay into `outState`. Returns outState for chaining.
function Replay.play(
	replay: Replay,
	simulator: Simulator.Simulator,
	outState: Types.MoveState,
	onTick: ((state: Types.MoveState, index: number) -> ())?
): Types.MoveState
	MoveState.copyInto(outState, replay.startState)
	for i = 1, replay.count do
		simulator:Step(outState, replay.commands[i])
		if onTick then
			onTick(outState, i)
		end
	end
	return outState
end

function Replay.serializedSize(replay: Replay): number
	return 4 + MoveState.SNAPSHOT_BYTES + replay.count * InputCommand.WIRE_BYTES
end

function Replay.serialize(replay: Replay): buffer
	local buf = buffer.create(Replay.serializedSize(replay))
	buffer.writeu32(buf, 0, replay.count)
	MoveState.serialize(replay.startState, buf, 4)
	local base = 4 + MoveState.SNAPSHOT_BYTES
	for i = 1, replay.count do
		InputCommand.serialize(replay.commands[i], buf, base + (i - 1) * InputCommand.WIRE_BYTES)
	end
	return buf
end

function Replay.deserialize(buf: buffer): Replay
	local count = buffer.readu32(buf, 0)
	local startState = MoveState.new(Vector3.zero)
	MoveState.deserialize(startState, buf, 4)
	local commands: { Types.InputCommand } = table.create(count)
	local base = 4 + MoveState.SNAPSHOT_BYTES
	for i = 1, count do
		local cmd = InputCommand.new()
		InputCommand.deserialize(cmd, buf, base + (i - 1) * InputCommand.WIRE_BYTES)
		commands[i] = cmd
	end
	return { startState = startState, commands = commands, count = count }
end

return table.freeze(Replay)
