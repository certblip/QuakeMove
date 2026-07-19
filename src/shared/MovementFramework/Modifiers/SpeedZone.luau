--!strict
--[[
	Modifiers/SpeedZone.luau
	Purpose: Example modifier that scales horizontal velocity while a boolean gate is
	active (speed boost pickups, conveyor strips). Demonstrates a modifier holding
	its own state and being toggled at runtime.
]]

local Framework = require(script.Parent.Parent)
local Types = require(script.Parent.Parent.Core.Types)
local MovementConfig = require(script.Parent.Parent.Config.MovementConfig)

export type SpeedZone = Framework.Modifier & {
	SetActive: (self: SpeedZone, active: boolean) -> (),
}

local function build(multiplier: number): SpeedZone
	local active = false
	local self = {
		Name = "SpeedZone",
		Priority = 20,
		SetActive = function(_self: any, value: boolean)
			active = value
		end,
		Apply = function(state: Types.MoveState, profile: MovementConfig.MovementProfile, _dt: number)
			if not active then
				return
			end
			local hv = Vector3.new(state.velocity.X, 0, state.velocity.Z)
			local boosted = hv * multiplier
			local maxH = profile.MaxVelocity
			if boosted.Magnitude > maxH then
				boosted = boosted.Unit * maxH
			end
			state.velocity = Vector3.new(boosted.X, state.velocity.Y, boosted.Z)
		end,
	}
	return self :: any
end

return { new = build }
