--!strict
--[[
	ShakeEffect.luau
	Purpose: Trauma-based procedural shake (Squirrel Eiserloh model): trauma^2 drives
	amplitude, decays linearly, and hard landings inject trauma. Uses value-noise
	over a moving seed so shake is smooth rather than jittery.
	API: AddTrauma is exposed so weapons/explosions can feed the same shake bus.
]]

local FrameworkModule = game:GetService("ReplicatedStorage"):WaitForChild("MovementFramework")
local Types = require(FrameworkModule:WaitForChild("Core"):WaitForChild("Types"))
local CameraConfig = require(FrameworkModule:WaitForChild("Config"):WaitForChild("CameraConfig"))

export type ShakeEffect = Types.ICameraEffect & {
	AddTrauma: (self: ShakeEffect, amount: number) -> (),
}

local ICameraEffect = {}
ICameraEffect.__index = ICameraEffect

type ShakeInternal = ShakeEffect & {
	_cfg: CameraConfig.ShakeConfig,
	_trauma: number,
	_time: number,
	_lastLandTick: number,
}

function ICameraEffect.AddTrauma(self: ShakeInternal, amount: number)
	self._trauma = math.clamp(self._trauma + amount, 0, 1)
end

function ICameraEffect.Update(self: ShakeInternal, ctx: Types.CameraContext, out: Types.CameraContribution)
	local cfg = self._cfg
	if not cfg.Enabled then
		return
	end
	local state = ctx.state
	if state.landedThisTick and state.tick ~= self._lastLandTick then
		self._lastLandTick = state.tick
		if state.landingSpeed > 28 then
			self:AddTrauma(math.min((state.landingSpeed - 28) / 40, 0.6))
		end
	end

	if self._trauma <= 1e-3 then
		self._trauma = 0
		return
	end
	self._time += ctx.dt * cfg.Frequency
	local shake = self._trauma * self._trauma
	-- Decorrelated axes via phase-shifted noise.
	local nx = (math.noise(self._time, 0.0) )
	local ny = (math.noise(0.0, self._time) )
	local nr = (math.noise(self._time, self._time) )
	out.positionOffset += Vector3.new(nx, ny, 0) * cfg.MaxOffset * shake
	out.rotationOffset += Vector3.new(0, 0, nr * cfg.MaxRoll * shake)

	self._trauma = math.max(self._trauma - cfg.TraumaDecay * ctx.dt, 0)
end

function ICameraEffect.Reset(self: ShakeInternal)
	self._trauma = 0
	self._time = 0
	self._lastLandTick = -1
end

local function new(cfg: CameraConfig.ShakeConfig): ShakeEffect
	return setmetatable({
		_cfg = cfg,
		_trauma = 0,
		_time = 0,
		_lastLandTick = -1,
	}, ICameraEffect) :: any
end

return { new = new }
