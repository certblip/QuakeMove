--!strict
--[[
	NetworkConfig.luau
	Purpose: Typed tunables for prediction, reconciliation and replay - the
	knobs a shipped game turns when its latency profile differs from ours.
	Notes: Thresholds trade correction visibility against cheat/desync
	tolerance; the defaults favour invisible corrections at < 150ms RTT.
]]

export type NetworkProfile = {
	PredictionCapacity: number, -- ticks of prediction history (128 = ~2.1s @ 60Hz)
	PositionTolerance: number, -- studs of drift accepted before a rollback fires
	CorrectionLambda: number, -- exponential decay rate of the visual correction offset
	InputQueueCapacity: number, -- server-side buffered commands per player
	MaxCommandsPerTick: number, -- server drain rate: absorbs jitter bursts without time skew
	ReplayCapacity: number, -- max recorded ticks (36000 = 10 minutes @ 60Hz)
}

local Default: NetworkProfile = {
	PredictionCapacity = 128,
	PositionTolerance = 2.0,
	CorrectionLambda = 14,
	InputQueueCapacity = 16,
	MaxCommandsPerTick = 4,
	ReplayCapacity = 36000,
}

return table.freeze({
	Default = table.freeze(Default) :: NetworkProfile,
})
