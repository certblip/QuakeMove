--!strict
--[[
	DebugRenderer.luau
	Purpose: In-world debug visualization: velocity / wish direction vectors,
	ground / wall / ladder / surf normals, slide-move clip planes, every
	collision trace of the current tick, prediction corrections and the
	movement state color. Toggled by the framework debug flag (F3).
	Architecture notes: Read-only consumer of MoveState + Simulator's last
	slide output; traces arrive through CollisionWorld's debug hook so the
	simulation itself stays observation-free. Rendering uses a pool of
	LineHandleAdornments adorned to Terrain - handle adornments are the
	cheapest world-space lines Roblox has, and pooling means zero instance
	churn per frame.
]]

local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local FrameworkModule = ReplicatedStorage:WaitForChild("MovementFramework")
local Framework = require(FrameworkModule)
local Types = require(FrameworkModule:WaitForChild("Core"):WaitForChild("Types"))
local StateMachine = require(FrameworkModule:WaitForChild("Simulation"):WaitForChild("StateMachine"))

export type DebugRenderer = {
	Name: string,
	Dependencies: { string }?,
	NotifyCorrection: (self: DebugRenderer, from: Vector3, to: Vector3) -> (),
	Init: (self: DebugRenderer, registry: any) -> (),
	Start: (self: DebugRenderer) -> (),
	Destroy: (self: DebugRenderer) -> (),
}

type TraceRecord = { origin: Vector3, endPos: Vector3, hit: boolean }
type Correction = { from: Vector3, to: Vector3, life: number }

type RendererInternal = DebugRenderer & {
	_fw: Framework.MovementFramework,
	_pool: { LineHandleAdornment },
	_used: number,
	_traces: { TraceRecord },
	_traceCount: number,
	_corrections: { Correction },
	_enabled: boolean,
	_hooked: boolean,
}

local RENDER_PRIORITY = 170
local CLEAR_PRIORITY = 1 -- before the simulation (100) so we capture one tick's traces
local MAX_LINES = 128
local MAX_TRACES = 48
local CORRECTION_LIFETIME = 1.0

local COLOR_VELOCITY = Color3.fromRGB(255, 255, 255)
local COLOR_WISH = Color3.fromRGB(255, 220, 60)
local COLOR_GROUND = Color3.fromRGB(90, 255, 120)
local COLOR_WALL = Color3.fromRGB(90, 200, 255)
local COLOR_LADDER = Color3.fromRGB(255, 140, 255)
local COLOR_PLANE = Color3.fromRGB(255, 80, 80)
local COLOR_TRACE_HIT = Color3.fromRGB(255, 160, 60)
local COLOR_TRACE_MISS = Color3.fromRGB(120, 120, 120)
local COLOR_CORRECTION = Color3.fromRGB(255, 0, 200)

local DebugRenderer = {}
DebugRenderer.__index = DebugRenderer

local function acquireLine(self: RendererInternal): LineHandleAdornment?
	local index = self._used + 1
	if index > MAX_LINES then
		return nil
	end
	self._used = index
	-- Explicit optional: array indexing past the filled prefix yields nil.
	local existing: LineHandleAdornment? = self._pool[index]
	local line: LineHandleAdornment
	if existing == nil then
		line = Instance.new("LineHandleAdornment")
		line.Adornee = Workspace.Terrain -- identity adornee => CFrame is world space
		line.Thickness = 3
		line.AlwaysOnTop = true
		line.ZIndex = 1
		line.Parent = Workspace.Terrain
		self._pool[index] = line
	else
		line = existing
	end
	line.Visible = true
	return line
end

local function drawLine(self: RendererInternal, from: Vector3, to: Vector3, color: Color3)
	local delta = to - from
	local length = delta.Magnitude
	if length < 1e-4 then
		return
	end
	local line = acquireLine(self)
	if line == nil then
		return
	end
	line.Color3 = color
	line.Length = length
	line.CFrame = CFrame.lookAt(from, to)
end

local function drawVector(self: RendererInternal, origin: Vector3, vec: Vector3, color: Color3, scale: number)
	drawLine(self, origin, origin + vec * scale, color)
end

function DebugRenderer.NotifyCorrection(self: RendererInternal, from: Vector3, to: Vector3)
	table.insert(self._corrections, { from = from, to = to, life = CORRECTION_LIFETIME })
end

local function render(self: RendererInternal, dt: number)
	self._used = 0
	local debugOn = self._fw:IsDebug()

	-- Corrections decay in real time whether or not the overlay is visible,
	-- so stale lines never greet you when toggling debug back on.
	for i = #self._corrections, 1, -1 do
		local c = self._corrections[i]
		c.life -= dt
		if c.life <= 0 then
			table.remove(self._corrections, i)
		elseif debugOn then
			drawLine(self, c.from, c.to, COLOR_CORRECTION)
		end
	end

	if debugOn then
		local state = self._fw.State
		local pos = state.position
		local eye = pos + Vector3.new(0, 1, 0)

		drawVector(self, eye, state.velocity, COLOR_VELOCITY, 0.15)
		drawVector(self, eye, state.wishDir, COLOR_WISH, 4)
		if state.grounded or state.stateId == Types.MoveStates.Surfing then
			drawVector(self, pos, state.groundNormal, COLOR_GROUND, 4)
		end
		if state.wallRunSide ~= 0 then
			drawVector(self, eye, state.wallNormal, COLOR_WALL, 4)
		end
		if state.onLadder then
			drawVector(self, eye, state.ladderNormal, COLOR_LADDER, 4)
		end

		-- Clip planes touched by the last slide solve (walls, ramps, ceilings).
		local slideOut = self._fw.Simulator:GetLastSlideOutput()
		for i = 1, slideOut.planeCount do
			drawVector(self, pos, slideOut.planes[i], COLOR_PLANE, 3)
		end

		-- Every collision trace of the current tick (from the collision hook).
		for i = 1, self._traceCount do
			local tr = self._traces[i]
			drawLine(self, tr.origin, tr.endPos, if tr.hit then COLOR_TRACE_HIT else COLOR_TRACE_MISS)
		end

		local _ = StateMachine.name(state.stateId) -- state text lives in DebugOverlay
	end

	-- Hide the tail of the pool that this frame did not use.
	for i = self._used + 1, #self._pool do
		local line = self._pool[i]
		if line.Visible then
			line.Visible = false
		end
	end
end

function DebugRenderer.Init(self: RendererInternal, _registry: any) end

function DebugRenderer.Start(self: RendererInternal)
	-- Capture traces: reset at the top of each fixed tick (priority 1 runs
	-- before the simulation at 100), record every trace the tick performs.
	self._fw.Scheduler:RegisterFixed(CLEAR_PRIORITY, function(_tick: number, _dt: number)
		self._traceCount = 0
	end)

	self._fw.CollisionWorld:SetDebugHook(function(origin: Vector3, delta: Vector3, result: Types.TraceResult)
		if not self._fw:IsDebug() then
			return
		end
		local index = self._traceCount + 1
		if index > MAX_TRACES then
			return
		end
		self._traceCount = index
		local slot = self._traces[index]
		if slot == nil then
			slot = { origin = origin, endPos = result.position, hit = result.hit }
			self._traces[index] = slot
		else
			slot.origin = origin
			slot.endPos = result.position
			slot.hit = result.hit
		end
		local _ = delta
	end)

	self._fw.Scheduler:RegisterRender(RENDER_PRIORITY, function(dt: number, _alpha: number)
		if self._enabled then
			render(self, dt)
		end
	end)
end

function DebugRenderer.Destroy(self: RendererInternal)
	self._enabled = false
	self._fw.CollisionWorld:SetDebugHook(nil)
	for _, line in self._pool do
		line:Destroy()
	end
	table.clear(self._pool)
	table.clear(self._corrections)
end

local function new(fw: Framework.MovementFramework): DebugRenderer
	return setmetatable({
		Name = "DebugRenderer",
		Dependencies = nil,
		_fw = fw,
		_pool = {},
		_used = 0,
		_traces = table.create(MAX_TRACES),
		_traceCount = 0,
		_corrections = {},
		_enabled = true,
		_hooked = false,
	}, DebugRenderer) :: any
end

return { new = new }
