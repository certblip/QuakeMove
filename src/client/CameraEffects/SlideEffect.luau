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
	_blend: number, -- 0 standing .. 1 fully slid
}

function ICameraEffect.Update(self: SlideInternal, ctx: Types.CameraContext, out: Types.CameraContribution)
	local cfg = self._cfg
	if not cfg.Enabled then
		return
	end
	local sliding = ctx.state.slideTimer > 0
	local target = if sliding then 1 else 0
	self._blend += (target - self._blend) * (1 - math.exp(-cfg.Responsiveness * ctx.dt))
	if self._blend < 1e-3 then
		self._blend = 0
		return
	end
	out.positionOffset += Vector3.new(0, -cfg.EyeDrop * self._blend, 0)
	-- Constant-side roll sells the "one shoulder down" slide pose.
	out.rotationOffset += Vector3.new(0, 0, cfg.Roll * self._blend)
end

function ICameraEffect.Reset(self: SlideInternal)
	self._blend = 0
end

local function new(cfg: CameraConfig.SlideConfig): Types.ICameraEffect
	return setmetatable({ _cfg = cfg, _blend = 0 }, ICameraEffect) :: any
end

return { new = new }
