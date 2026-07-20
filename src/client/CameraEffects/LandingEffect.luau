--!strict
--[[
	LandingEffect.luau
	Purpose: Spring-driven camera dip on landing, scaled by impact speed. Hard
	landings dip further and recover with a slight overshoot.
	Architecture notes: Reads state.landedThisTick / state.landingSpeed produced by
	the simulator - the movement code signals the event, this effect renders it.
]]

local FrameworkModule = game:GetService("ReplicatedStorage"):WaitForChild("MovementFramework")
local Types = require(FrameworkModule:WaitForChild("Core"):WaitForChild("Types"))
local CameraConfig = require(FrameworkModule:WaitForChild("Config"):WaitForChild("CameraConfig"))
local Spring = require(FrameworkModule:WaitForChild("Math"):WaitForChild("Spring"))

local ICameraEffect = {}
ICameraEffect.__index = ICameraEffect

type LandingInternal = Types.ICameraEffect & {
	_cfg: CameraConfig.LandingConfig,
	_spring: Spring.Spring3,
	_lastLandTick: number,
}

function ICameraEffect.Update(self: LandingInternal, ctx: Types.CameraContext, out: Types.CameraContribution)
	local cfg = self._cfg
	if not cfg.Enabled then
		return
	end
	local state = ctx.state
	if state.landedThisTick and state.tick ~= self._lastLandTick then
		self._lastLandTick = state.tick
		local dip = math.min(state.landingSpeed * cfg.DipPerSpeed, cfg.MaxDip)
		-- Fixed velocity-per-dip scale: dividing by the RENDER dt made the
		-- impulse framerate-dependent (4x harder at 240fps than at 60).
		local IMPULSE_PER_DIP = 62.5 -- studs/s of spring velocity per stud of dip
		self._spring:Impulse(Vector3.new(0, -dip * IMPULSE_PER_DIP, 0))
	end
	self._spring.Stiffness = cfg.Stiffness
	self._spring.Damping = cfg.Damping
	local p = self._spring:Update(ctx.dt)
	out.positionOffset += p
end

function ICameraEffect.Reset(self: LandingInternal)
	self._spring:Reset()
	self._lastLandTick = -1
end

local function new(cfg: CameraConfig.LandingConfig): Types.ICameraEffect
	return setmetatable({
		_cfg = cfg,
		_spring = Spring.new(cfg.Stiffness, cfg.Damping),
		_lastLandTick = -1,
	}, ICameraEffect) :: any
end

return { new = new }
