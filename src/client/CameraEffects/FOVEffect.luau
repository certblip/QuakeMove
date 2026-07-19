--!strict
--[[
	FOVEffect.luau
	Purpose: Dynamic FOV that widens with speed (Titanfall/Apex speed-rush feel),
	damped so it never snaps.
	Notes: Contributes a FOV *offset*; the pipeline adds it to BaseFOV, so multiple
	FOV sources (e.g. an ADS modifier) can coexist.
]]

-- Direct module requires: Luau only propagates exported types through
-- require(), never through table fields (Framework.Types loses the types).
local FrameworkModule = game:GetService("ReplicatedStorage"):WaitForChild("MovementFramework")
local Types = require(FrameworkModule:WaitForChild("Core"):WaitForChild("Types"))
local CameraConfig = require(FrameworkModule:WaitForChild("Config"):WaitForChild("CameraConfig"))

local ICameraEffect = {}
ICameraEffect.__index = ICameraEffect

type FOVInternal = Types.ICameraEffect & {
	_cfg: CameraConfig.FOVConfig,
	_current: number,
}

function ICameraEffect.Update(self: FOVInternal, ctx: Types.CameraContext, out: Types.CameraContribution)
	local cfg = self._cfg
	if not cfg.Enabled then
		return
	end
	local excess = math.max(ctx.horizontalSpeed - cfg.ReferenceSpeed, 0)
	local target = math.min(excess * cfg.SpeedFOVScale, cfg.MaxFOVOffset)
	self._current += (target - self._current) * (1 - math.exp(-cfg.Responsiveness * ctx.dt))
	out.fovOffset += self._current
end

function ICameraEffect.Reset(self: FOVInternal)
	self._current = 0
end

local function new(cfg: CameraConfig.FOVConfig): Types.ICameraEffect
	return setmetatable({ _cfg = cfg, _current = 0 }, ICameraEffect) :: any
end

return { new = new }
