--!strict
--[[
	Scheduler.luau
	Purpose: The single frame-loop owner. Nothing else in the framework connects to
	RunService directly.
	Architecture notes: Two phases -
	  FixedStep : deterministic accumulator-driven simulation ticks (Heartbeat)
	  Render    : per-frame camera/visual work with interpolation alpha (PreRender)
	Performance: Callback arrays are flat and iterated with numeric for; registering
	returns an index-based handle. No per-frame allocations.
]]

local RunService = game:GetService("RunService")

export type FixedCallback = (tick: number, dt: number) -> ()
export type RenderCallback = (dt: number, alpha: number) -> ()

export type Scheduler = {
	FixedRate: number,
	RegisterFixed: (self: Scheduler, priority: number, fn: FixedCallback) -> (),
	RegisterRender: (self: Scheduler, priority: number, fn: RenderCallback) -> (),
	Start: (self: Scheduler) -> (),
	Stop: (self: Scheduler) -> (),
	GetTick: (self: Scheduler) -> number,
	GetAlpha: (self: Scheduler) -> number,
}

type Entry<F> = { priority: number, fn: F }

type SchedulerInternal = Scheduler & {
	_fixed: { Entry<FixedCallback> },
	_render: { Entry<RenderCallback> },
	_accumulator: number,
	_tick: number,
	_alpha: number,
	_hbConn: RBXScriptConnection?,
	_prConn: RBXScriptConnection?,
	_maxSubSteps: number,
}

local Scheduler = {}
Scheduler.__index = Scheduler

local function sortEntries<F>(list: { Entry<F> })
	table.sort(list, function(a, b)
		return a.priority < b.priority
	end)
end

function Scheduler.RegisterFixed(self: SchedulerInternal, priority: number, fn: FixedCallback)
	table.insert(self._fixed, { priority = priority, fn = fn })
	sortEntries(self._fixed)
end

function Scheduler.RegisterRender(self: SchedulerInternal, priority: number, fn: RenderCallback)
	table.insert(self._render, { priority = priority, fn = fn })
	sortEntries(self._render)
end

function Scheduler.GetTick(self: SchedulerInternal): number
	return self._tick
end

function Scheduler.GetAlpha(self: SchedulerInternal): number
	return self._alpha
end

function Scheduler.Start(self: SchedulerInternal)
	if self._hbConn then
		return
	end
	local fixedDt = 1 / self.FixedRate

	self._hbConn = RunService.Heartbeat:Connect(function(dt: number)
		-- Clamp to avoid spiral-of-death after a hitch.
		self._accumulator += math.min(dt, fixedDt * self._maxSubSteps)
		local fixed = self._fixed
		while self._accumulator >= fixedDt do
			self._accumulator -= fixedDt
			self._tick += 1
			for i = 1, #fixed do
				fixed[i].fn(self._tick, fixedDt)
			end
		end
		self._alpha = self._accumulator / fixedDt
	end)

	if RunService:IsClient() then
		self._prConn = RunService.PreRender:Connect(function(dt: number)
			local render = self._render
			local alpha = self._alpha
			for i = 1, #render do
				render[i].fn(dt, alpha)
			end
		end)
	end
end

function Scheduler.Stop(self: SchedulerInternal)
	if self._hbConn then
		self._hbConn:Disconnect()
		self._hbConn = nil
	end
	if self._prConn then
		self._prConn:Disconnect()
		self._prConn = nil
	end
end

local function new(fixedRate: number): Scheduler
	return setmetatable({
		FixedRate = fixedRate,
		_fixed = {},
		_render = {},
		_accumulator = 0,
		_tick = 0,
		_alpha = 0,
		_maxSubSteps = 5,
	}, Scheduler) :: any
end

return { new = new }
