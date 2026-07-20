--!strict
--[[
	SlideEffect.luau
	Purpose: Crouch-pose camera animation for the slide: the eye smoothly drops
	toward EyeDrop and the view gains a slight roll while state.slideTimer is
	running, then blends back out on exit. Damped (framerate-independent), so
	enter/exit reads as a pose change, not a teleport.
	Architecture notes: Reads ONLY MoveState - the simulator owns the slide
	mechanic, this effect just renders it. Contributes additive offsets like
	every other ICameraEffect; the viewmodel follows automatically because it
	is camera-relative.
]]

local FrameworkModule = game:GetService("ReplicatedStorage"):WaitForChild("MovementFramework")
local Types = require(FrameworkModule:WaitForChild("Core"):WaitForChild("Types"))
local CameraConfig = require(FrameworkModule:WaitForChild("Config"):WaitForChild("CameraConfig"))

local ICameraEffect = {}
ICameraEffect.__index = ICameraEffect

type SlideInternal = Types.ICameraEffect & {
	_cfg: CameraConfig.SlideConfig,
	_lowBlend: number, -- 0 standing .. 1 low stance (slide OR crouch)
	_rollBlend: number, -- 0 .. 1 slide-only (roll pose)
}

function ICameraEffect.Update(self: SlideInternal, ctx: Types.CameraContext, out: Types.CameraContribution)
	local cfg = self._cfg
	if not cfg.Enabled then
		return
	end
	local state = ctx.state
	local sliding = state.slideTimer > 0
	-- Both slide and crouch lower the eye; only the slide gets the roll pose.
	local lowTarget = if (sliding or state.crouching) then 1 else 0
	local rollTarget = if sliding then 1 else 0
	local k = 1 - math.exp(-cfg.Responsiveness * ctx.dt)
	self._lowBlend += (lowTarget - self._lowBlend) * k
	self._rollBlend += (rollTarget - self._rollBlend) * k
	if self._lowBlend < 1e-3 then
		self._lowBlend = 0
	end
	if self._rollBlend < 1e-3 then
		self._rollBlend = 0
	end
	if self._lowBlend > 0 then
		out.positionOffset += Vector3.new(0, -cfg.EyeDrop * self._lowBlend, 0)
	end
	if self._rollBlend > 0 then
		out.rotationOffset += Vector3.new(0, 0, cfg.Roll * self._rollBlend)
	end
end

function ICameraEffect.Reset(self: SlideInternal)
	self._lowBlend = 0
	self._rollBlend = 0
end

local function new(cfg: CameraConfig.SlideConfig): Types.ICameraEffect
	return setmetatable({ _cfg = cfg, _lowBlend = 0, _rollBlend = 0 }, ICameraEffect) :: any
end

return { new = new }
