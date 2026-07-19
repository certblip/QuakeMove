--!strict
--[[
	HeadBob.luau
	Purpose: Sinusoidal view bob whose frequency and amplitude scale with horizontal
	ground speed and fade out in the air. Contributes an additive positional offset;
	never touches the camera.
	Performance: A single phase accumulator; two sin calls per frame, no allocation.
]]

local FrameworkModule = game:GetService("ReplicatedStorage"):WaitForChild("MovementFramework")
local Types = require(FrameworkModule:WaitForChild("Core"):WaitForChild("Types"))
local CameraConfig = require(FrameworkModule:WaitForChild("Config"):WaitForChild("CameraConfig"))

local ICameraEffect = {}
ICameraEffect.__index = ICameraEffect

type HeadBobInternal = Types.ICameraEffect & {
	_cfg: CameraConfig.HeadBobConfig,
	_phase: number,
	_intensity: number,
}

function ICameraEffect.Update(self: HeadBobInternal, ctx: Types.CameraContext, out: Types.CameraContribution)
	local cfg = self._cfg
	if not cfg.Enabled then
		return
	end
	local grounded = ctx.state.grounded
	local speedRatio = math.clamp(ctx.horizontalSpeed / cfg.ReferenceSpeed, 0, 1.6)

	-- Fade bob intensity toward speedRatio on ground, toward 0 in air.
	local target = if grounded then speedRatio else 0
	self._intensity += (target - self._intensity) * (1 - math.exp(-cfg.AirFade * ctx.dt))

	if self._intensity > 1e-3 then
		self._phase += ctx.dt * cfg.Frequency * math.pi * 2 * (0.6 + speedRatio)
		if self._phase > math.pi * 4 then
			self._phase -= math.pi * 4
		end
		local vert = math.sin(self._phase) * cfg.Amplitude * self._intensity
		local lateral = math.cos(self._phase * 0.5) * cfg.LateralAmplitude * self._intensity
		out.positionOffset += Vector3.new(lateral, vert, 0)
	end
end

function ICameraEffect.Reset(self: HeadBobInternal)
	self._phase = 0
	self._intensity = 0
end

local function new(cfg: CameraConfig.HeadBobConfig): Types.ICameraEffect
	return setmetatable({ _cfg = cfg, _phase = 0, _intensity = 0 }, ICameraEffect) :: any
end

return { new = new }
