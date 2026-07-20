--!strict
--[[
	DebugOverlay.luau
	Purpose: In-game diagnostic HUD. Displays velocity, speeds, wish direction,
	ground normal, state, acceleration, surface angle, FPS, sim time, network /
	prediction placeholders, movement mode, collision count, ground/air flags,
	jump queue, buffer + coyote timers.
	Performance: One TextLabel updated from a pre-sized string buffer built with
	table.concat; text is only pushed when the debug flag is on. Rows are a fixed
	array reused every frame - no per-frame table growth.
	Extension: NetworkDelay / PredictionError read live from PredictionBuffer once a
	full client-prediction loop is wired; today they surface the buffer's values.
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local FrameworkModule = game:GetService("ReplicatedStorage"):WaitForChild("MovementFramework")
local Types = require(FrameworkModule:WaitForChild("Core"):WaitForChild("Types"))
local StateMachine = require(FrameworkModule:WaitForChild("Simulation"):WaitForChild("StateMachine"))
local VectorMath = require(FrameworkModule:WaitForChild("Math"):WaitForChild("VectorMath"))

export type DebugOverlay = {
	Name: string,
	Dependencies: { string }?,
	SetVisible: (self: DebugOverlay, visible: boolean) -> (),
	SetNetworkStats: (
		self: DebugOverlay,
		delayMs: number,
		predictionError: number,
		snapshotsPerSec: number,
		correctionsPerSec: number
	) -> (),
	SetSimTime: (self: DebugOverlay, micros: number) -> (),
	Update: (self: DebugOverlay, state: Types.MoveState) -> (),
	Init: (self: DebugOverlay, registry: any) -> (),
	Start: ((self: DebugOverlay) -> ())?, -- optional per Service contract
	Destroy: (self: DebugOverlay) -> (),
}

type OverlayInternal = DebugOverlay & {
	_gui: ScreenGui?,
	_label: TextLabel?,
	_visible: boolean,
	_rows: { string },
	_delayMs: number,
	_predErr: number,
	_snapsPerSec: number,
	_corrPerSec: number,
	_simMicros: number,
	_frameTimes: { number },
	_frameIndex: number,
	_lastClock: number,
}

local DebugOverlay = {}
DebugOverlay.__index = DebugOverlay

local FPS_SAMPLES = 30

local function fmtVec(v: Vector3): string
	return string.format("%6.1f %6.1f %6.1f", v.X, v.Y, v.Z)
end

function DebugOverlay.SetVisible(self: OverlayInternal, visible: boolean)
	self._visible = visible
	if self._gui then
		(self._gui :: ScreenGui).Enabled = visible
	end
end

function DebugOverlay.SetNetworkStats(
	self: OverlayInternal,
	delayMs: number,
	predictionError: number,
	snapshotsPerSec: number,
	correctionsPerSec: number
)
	self._delayMs = delayMs
	self._predErr = predictionError
	self._snapsPerSec = snapshotsPerSec
	self._corrPerSec = correctionsPerSec
end

function DebugOverlay.SetSimTime(self: OverlayInternal, micros: number)
	self._simMicros = micros
end

local function computeFps(self: OverlayInternal): number
	local now = os.clock()
	local dt = now - self._lastClock
	self._lastClock = now
	self._frameTimes[self._frameIndex] = dt
	self._frameIndex += 1
	if self._frameIndex > FPS_SAMPLES then
		self._frameIndex = 1
	end
	local sum = 0
	for i = 1, FPS_SAMPLES do
		sum += self._frameTimes[i]
	end
	local avg = sum / FPS_SAMPLES
	return if avg > 0 then 1 / avg else 0
end

function DebugOverlay.Update(self: OverlayInternal, state: Types.MoveState)
	local label = self._label
	if not self._visible or not label then
		return
	end
	local rows = self._rows
	local vel = state.velocity
	local hSpeed = VectorMath.horizontalLength(vel)

	rows[1] = string.format("STATE        %s", StateMachine.name(state.stateId))
	rows[2] = string.format("VELOCITY     %s", fmtVec(vel))
	rows[3] = string.format("H-SPEED      %7.2f", hSpeed)
	rows[4] = string.format("V-SPEED      %7.2f", vel.Y)
	rows[5] = string.format("WISH DIR     %s", fmtVec(state.wishDir))
	rows[6] = string.format("WISH SPEED   %7.2f", state.wishSpeed)
	rows[7] = string.format("GROUND NORM  %s", fmtVec(state.groundNormal))
	rows[8] = string.format("SURF ANGLE   %6.1f deg", state.surfaceAngle)
	rows[9] = string.format("ACCEL        %7.2f", state.lastAcceleration)
	rows[10] = string.format("GROUNDED     %s", tostring(state.grounded))
	rows[11] = string.format("AIRBORNE     %s", tostring(not state.grounded))
	rows[12] = string.format("COLLISIONS   %d", state.collisionCount)
	rows[13] = string.format("JUMP QUEUE   %s", if state.jumpBufferTimer > 0 then "QUEUED" else "-")
	rows[14] = string.format("BUFFER       %5.3f", state.jumpBufferTimer)
	rows[15] = string.format("COYOTE       %5.3f", state.coyoteTimer)
	rows[16] = string.format("SLIDE        %5.3f", state.slideTimer)
	rows[17] = string.format("TICK         %d", state.tick)
	rows[18] = string.format("SIM TIME     %d us", self._simMicros)
	rows[19] = string.format("FPS          %6.1f", computeFps(self))
	rows[20] = string.format("NET RTT      %6.1f ms", self._delayMs)
	rows[21] = string.format("PRED ERROR   %7.3f", self._predErr)
	-- Snapshots arrive per processed input tick (60/s ideal); a sustained
	-- lower rate = upstream/downstream loss or server-side throttling.
	rows[22] = string.format("SNAPSHOTS    %5.1f /s", self._snapsPerSec)
	rows[23] = string.format("CORRECTIONS  %5.1f /s", self._corrPerSec)

	label.Text = table.concat(rows, "\n")
end

function DebugOverlay.Init(self: OverlayInternal, _registry: any)
	local player = Players.LocalPlayer
	local gui = Instance.new("ScreenGui")
	gui.Name = "MovementDebugOverlay"
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = true
	gui.Enabled = self._visible

	local label = Instance.new("TextLabel")
	label.Size = UDim2.fromOffset(340, 460)
	label.Position = UDim2.fromOffset(12, 12)
	label.BackgroundColor3 = Color3.new(0, 0, 0)
	label.BackgroundTransparency = 0.35
	label.TextColor3 = Color3.fromRGB(120, 255, 140)
	label.Font = Enum.Font.Code
	label.TextSize = 15
	label.TextXAlignment = Enum.TextXAlignment.Left
	label.TextYAlignment = Enum.TextYAlignment.Top
	label.Text = ""
	label.Parent = gui

	gui.Parent = player:WaitForChild("PlayerGui")
	self._gui = gui
	self._label = label
end

function DebugOverlay.Destroy(self: OverlayInternal)
	if self._gui then
		self._gui:Destroy()
		self._gui = nil
	end
	self._label = nil
end

local function new(startVisible: boolean): DebugOverlay
	local frameTimes = table.create(FPS_SAMPLES, 1 / 60)
	return setmetatable({
		Name = "DebugOverlay",
		Dependencies = nil,
		_gui = nil,
		_label = nil,
		_visible = startVisible,
		_rows = table.create(23, ""),
		_delayMs = 0,
		_predErr = 0,
		_snapsPerSec = 0,
		_corrPerSec = 0,
		_simMicros = 0,
		_frameTimes = frameTimes,
		_frameIndex = 1,
		_lastClock = os.clock(),
	}, DebugOverlay) :: any
end

local _ = RunService
return { new = new }
