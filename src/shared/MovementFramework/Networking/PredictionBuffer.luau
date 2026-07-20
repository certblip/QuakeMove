--!strict
--[[
	PredictionBuffer.luau
	Purpose: Client-side prediction scaffolding. Stores (cmd, resulting state) pairs
	per tick; when an authoritative snapshot arrives, compares against the stored
	prediction and - if the error exceeds tolerance - rewinds to the server state
	and replays every unacknowledged command through the simulator (rollback).
	Architecture notes: The buffer drives the SAME Simulator instance used for live
	ticks, guaranteeing replay determinism. Interpolation/correction smoothing is
	the CharacterAdapter's job; this module only computes the corrected state and
	reports the error magnitude for the debug overlay.
	Performance: Snapshot tables are pre-allocated at construction (capacity ticks x
	fixed fields); Record/Reconcile allocate nothing.
]]

local Types = require(script.Parent.Parent.Core.Types)
local MoveState = require(script.Parent.Parent.Simulation.MoveState)
local InputCommand = require(script.Parent.InputCommand)
local Simulator = require(script.Parent.Parent.Simulation.Simulator)

export type PredictionBuffer = {
	Record: (self: PredictionBuffer, cmd: Types.InputCommand, state: Types.MoveState) -> (),
	Reconcile: (
		self: PredictionBuffer,
		authoritative: Types.MoveState,
		liveState: Types.MoveState,
		simulator: Simulator.Simulator,
		applyModifiers: ((dt: number) -> ())?
	) -> number, -- returns prediction error magnitude (0 when within tolerance)
	GetLastError: (self: PredictionBuffer) -> number,
	Clear: (self: PredictionBuffer) -> (),
}

type Slot = {
	used: boolean,
	cmd: Types.InputCommand,
	state: Types.MoveState,
}

type BufferInternal = PredictionBuffer & {
	_slots: { Slot },
	_capacity: number,
	_tolerance: number,
	_lastError: number,
}

local PredictionBuffer = {}
PredictionBuffer.__index = PredictionBuffer

local function slotFor(self: BufferInternal, tick: number): Slot
	return self._slots[(tick % self._capacity) + 1]
end

function PredictionBuffer.Record(self: BufferInternal, cmd: Types.InputCommand, state: Types.MoveState)
	local slot = slotFor(self, cmd.tick)
	slot.used = true
	InputCommand.copyInto(slot.cmd, cmd)
	MoveState.copyInto(slot.state, state)
end

function PredictionBuffer.Reconcile(
	self: BufferInternal,
	authoritative: Types.MoveState,
	liveState: Types.MoveState,
	simulator: Simulator.Simulator,
	applyModifiers: ((dt: number) -> ())?
): number
	local slot = slotFor(self, authoritative.tick)
	if not slot.used or slot.state.tick ~= authoritative.tick then
		return 0 -- too old / never predicted; nothing to compare against
	end

	local err = (slot.state.position - authoritative.position).Magnitude
	self._lastError = err
	if err <= self._tolerance then
		return 0
	end

	-- Rollback: adopt server truth at that tick...
	local replayFrom = authoritative.tick + 1
	local currentTick = liveState.tick
	MoveState.copyInto(liveState, authoritative)

	-- ...and replay every stored command up to the present. Modifiers must
	-- replay too: the live tick ran them, so omitting them here would make
	-- every reconciliation near a jump pad diverge by exactly one pad impulse.
	for tick = replayFrom, currentTick do
		local replay = slotFor(self, tick)
		if replay.used and replay.cmd.tick == tick then
			simulator:Step(liveState, replay.cmd)
			if applyModifiers then
				applyModifiers(replay.cmd.dt)
			end
			MoveState.copyInto(replay.state, liveState) -- re-record corrected history
		end
	end
	return err
end

function PredictionBuffer.GetLastError(self: BufferInternal): number
	return self._lastError
end

function PredictionBuffer.Clear(self: BufferInternal)
	for _, slot in self._slots do
		slot.used = false
	end
	self._lastError = 0
end

local function new(capacity: number, tolerance: number): PredictionBuffer
	local slots = table.create(capacity)
	for i = 1, capacity do
		slots[i] = {
			used = false,
			cmd = InputCommand.new(),
			state = MoveState.new(Vector3.zero),
		}
	end
	return setmetatable({
		_slots = slots,
		_capacity = capacity,
		_tolerance = tolerance,
		_lastError = 0,
	}, PredictionBuffer) :: any
end

return { new = new }
