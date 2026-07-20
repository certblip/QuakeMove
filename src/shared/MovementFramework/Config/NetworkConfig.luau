--!strict
--[[
	NetworkConfig.luau
	Purpose: Typed tunables for prediction, reconciliation, replay and lag
	compensation - the knobs a shipped game turns when its latency profile
	differs from ours.
	Notes: Thresholds trade correction visibility against cheat/desync
	tolerance; the defaults favour invisible corrections at < 150ms RTT.
]]

export type NetworkProfile = {
	PredictionCapacity: number, -- ticks of prediction history (128 = ~2.1s @ 60Hz)
	PositionTolerance: number, -- studs of drift accepted before a rollback fires
	CorrectionLambda: number, -- exponential decay rate of the visual correction offset
	InputQueueCapacity: number, -- server-side buffered commands per player
	MaxCommandsPerTick: number, -- server drain rate: absorbs jitter bursts without time skew
	InputRedundancy: number, -- commands per input packet (1..4); >1 heals UDP loss
	ReplayCapacity: number, -- max recorded ticks (36000 = 10 minutes @ 60Hz)
	RemoteInterpDelay: number, -- seconds remote players render behind real time
	LagCompHistoryTicks: number, -- server pose-history depth (64 = ~1.06s @ 60Hz)
	MaxRewindSeconds: number, -- rewind cap: bounds the "shot around a corner" window
}

local Default: NetworkProfile = {
	PredictionCapacity = 128,
	PositionTolerance = 2.0,
	CorrectionLambda = 14,
	InputQueueCapacity = 16,
	MaxCommandsPerTick = 4,
	InputRedundancy = 3,
	ReplayCapacity = 36000,
	RemoteInterpDelay = 0.1,
	LagCompHistoryTicks = 64,
	MaxRewindSeconds = 0.25,
}

return table.freeze({
	Default = table.freeze(Default) :: NetworkProfile,
})
