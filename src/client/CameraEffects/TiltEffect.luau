--!strict
--[[
	TiltEffect.luau
	Purpose: Camera roll while strafing (Quake/Source cl_rollangle) plus a velocity
	based roll component, damped for smooth blend in/out.
	Notes: Contributes rotationOffset.Z (roll); pitch/yaw untouched so view control
	stays fully with the player.
]]

local FrameworkModule = game:GetService("ReplicatedStorage"):WaitForChild("MovementFramework")
local Types = require(FrameworkModule:WaitForChild("Core"):WaitForChild("Types"))
local CameraConfig = require(FrameworkModule:WaitForChild("Config"):WaitForChild("CameraConfig"))

local ICameraEffect = {}
ICameraEffect.__index = ICameraEffect

type TiltInternal = Types.ICameraEffect & {
	_cfg: CameraConfig.TiltConfig,
	_roll: number,
}

function ICameraEffect.Update(self: TiltInternal, ctx: Types.CameraContext, out: Types.CameraContribution)
	local cfg = self._cfg
	if not cfg.Enabled then
		return
	end
	-- Lateral velocity relative to look direction. True right = forward x up
	-- = (-z, 0, x); the flipped variant inverts velocity tilt so it fights
	-- the strafe tilt instead of reinforcing it.
	local look = ctx.lookVector
	local right = Vector3.new(-look.Z, 0, look.X)
	local lateralVel = ctx.state.velocity:Dot(right)

	local target = -ctx.strafeInput * cfg.StrafeTilt - lateralVel * cfg.VelocityTilt
	-- Wall-run hook: lean away from the wall. The simulator exposes the wall
	-- side through MoveState precisely so camera feel needs zero coupling to
	-- the wall-run solver.
	local state = ctx.state
	if state.wallRunSide ~= 0 and not state.grounded then
		target += state.wallRunSide * cfg.WallRunTilt
	end
	self._roll += (target - self._roll) * (1 - math.exp(-cfg.Responsiveness * ctx.dt))
	out.rotationOffset += Vector3.new(0, 0, self._roll)
end

function ICameraEffect.Reset(self: TiltInternal)
	self._roll = 0
end

local function new(cfg: CameraConfig.TiltConfig): Types.ICameraEffect
	return setmetatable({ _cfg = cfg, _roll = 0 }, ICameraEffect) :: any
end

return { new = new }
