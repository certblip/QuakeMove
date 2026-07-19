--!strict
--[[
	Modifiers/JumpPad.luau
	Purpose: Example gameplay modifier. Detects the player standing on a tagged jump
	pad and launches them with a fixed vertical impulse (Quake-style trigger_push).
	Architecture notes: Modifiers run post-simulation via Framework:AddModifier. They
	mutate MoveState only - no engine ownership - so they replay correctly through
	prediction rollback as long as the trigger volume is deterministic.
	Extension: Swap the CollectionService lookup for a spatial hash to scale past a
	few hundred pads without per-tick tag scans.
]]

local CollectionService = game:GetService("CollectionService")

-- Static relative requires: this module lives inside the framework, so the
-- root ModuleScript is simply script.Parent.Parent (no service lookup needed).
local Framework = require(script.Parent.Parent)
local Types = require(script.Parent.Parent.Core.Types)
local MovementConfig = require(script.Parent.Parent.Config.MovementConfig)

export type JumpPad = Framework.Modifier

local TAG = "MovementJumpPad"
local DEFAULT_POWER = 60
local PAD_RADIUS_SQ = 16 -- studs^2, cheap broadphase

local function build(power: number?): JumpPad
	local launch = power or DEFAULT_POWER
	return {
		Name = "JumpPad",
		Priority = 10,
		Apply = function(state: Types.MoveState, _profile: MovementConfig.MovementProfile, _dt: number)
			if not state.grounded then
				return
			end
			local pads = CollectionService:GetTagged(TAG)
			local pos = state.position
			for _, pad in pads do
				if pad:IsA("BasePart") then
					local d = pad.Position - pos
					local flatDistSq = d.X * d.X + d.Z * d.Z
					if flatDistSq < PAD_RADIUS_SQ and math.abs(d.Y) < 4 then
						state.velocity = Vector3.new(state.velocity.X, launch, state.velocity.Z)
						state.grounded = false
						state.jumpedThisTick = true
						break
					end
				end
			end
		end,
	}
end

return { new = build, Tag = TAG }
