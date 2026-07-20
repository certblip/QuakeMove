--!strict
--[[
	SwayEffect.luau
	Purpose: Velocity-based positional sway (weapon/viewmodel drag). Lags the camera
	origin opposite to acceleration, damped back to centre - the subtle "weight"
	that separates a AAA viewmodel from a rigid one.
]]

local FrameworkModule = game:GetService("ReplicatedStorage"):WaitForChild("MovementFramework")
local Types = require(FrameworkModule:WaitForChild("Core"):WaitForChild("Types"))
local CameraConfig = require(FrameworkModule:WaitForChild("Config"):WaitForChild("CameraConfig"))

local ICameraEffect = {}
ICameraEffect.__index = ICameraEffect

type SwayInternal = Types.ICameraEffect & {
	_cfg: CameraConfig.SwayConfig,
	_offset: Vector3,
	_prevVel: Vector3,
}

function ICameraEffect.Update(self: SwayInternal, ctx: Types.CameraContext, out: Types.CameraContribution)
	local cfg = self._cfg
	if not cfg.Enabled then
		return
	end
	local vel = ctx.state.velocity
	local accel = (vel - self._prevVel)
	self._prevVel = vel

	-- True right vector: forward x up = (-z, 0, x). See TiltEffect note.
	local look = ctx.lookVector
	local right = Vector3.new(-look.Z, 0, look.X)
	local target = right * (-accel:Dot(right) * cfg.VelocityScale)
		+ Vector3.new(0, -accel.Y * cfg.VelocityScale * 0.5, 0)

	local maxS = cfg.MaxSway
	target = Vector3.new(
		math.clamp(target.X, -maxS, maxS),
		math.clamp(target.Y, -maxS, maxS),
		math.clamp(target.Z, -maxS, maxS)
	)
	self._offset = self._offset:Lerp(target, 1 - math.exp(-cfg.Responsiveness * ctx.dt))
	out.positionOffset += self._offset
end

function ICameraEffect.Reset(self: SwayInternal)
	self._offset = Vector3.zero
	self._prevVel = Vector3.zero
end

local function new(cfg: CameraConfig.SwayConfig): Types.ICameraEffect
	return setmetatable({
		_cfg = cfg,
		_offset = Vector3.zero,
		_prevVel = Vector3.zero,
	}, ICameraEffect) :: any
end

return { new = new }
