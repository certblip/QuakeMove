--!strict
--[[
	Modifiers/SpeedZone.luau
	Purpose: Example modifier: tagged world volumes that scale horizontal
	velocity while the player is inside (boost strips, slow fields).
	Architecture notes: Zones are BaseParts tagged "MovementSpeedZone" with an
	optional "SpeedMultiplier" number attribute (default 2). State is read from
	the WORLD, not from per-client flags, so the client's prediction, the
	rollback replay and the authoritative server all see the same answer - the
	requirement for any modifier that ships in a networked game.
	Determinism: overlapping zones resolve via max(multiplier), which is
	order-independent (CollectionService:GetTagged order differs across peers).
]]

local CollectionService = game:GetService("CollectionService")

local Framework = require(script.Parent.Parent)
local Types = require(script.Parent.Parent.Core.Types)
local MovementConfig = require(script.Parent.Parent.Config.MovementConfig)
local VectorMath = require(script.Parent.Parent.Math.VectorMath)

export type SpeedZone = Framework.Modifier

local TAG = "MovementSpeedZone"
local MULTIPLIER_ATTRIBUTE = "SpeedMultiplier"
local DEFAULT_MULTIPLIER = 2

local function build(): SpeedZone
	return {
		Name = "SpeedZone",
		Priority = 20,
		Apply = function(state: Types.MoveState, profile: MovementConfig.MovementProfile, dt: number)
			-- Pick the strongest containing zone (order-independent).
			local strongest = 1.0
			local pos = state.position
			for _, zone in CollectionService:GetTagged(TAG) do
				if zone:IsA("BasePart") then
					local localPos = zone.CFrame:PointToObjectSpace(pos)
					local half = zone.Size * 0.5
					if
						math.abs(localPos.X) <= half.X
						and math.abs(localPos.Y) <= half.Y
						and math.abs(localPos.Z) <= half.Z
					then
						local mult = zone:GetAttribute(MULTIPLIER_ATTRIBUTE)
						local m = if typeof(mult) == "number" then mult else DEFAULT_MULTIPLIER
						if m > strongest then
							strongest = m
						end
					end
				end
			end
			if strongest <= 1.0 then
				return
			end

			-- Frame-rate independent compounding: mult^dt per tick means the
			-- horizontal speed multiplies by `strongest` per SECOND inside the
			-- zone, identical at any fixed rate.
			local scale = strongest ^ dt
			local hv = VectorMath.flatten(state.velocity)
			local boosted = hv * scale
			local maxH = profile.MaxVelocity
			if boosted.Magnitude > maxH then
				local unit = VectorMath.safeUnit(boosted)
				boosted = unit * maxH
			end
			state.velocity = VectorMath.withY(boosted, state.velocity.Y)
		end,
	}
end

return { new = build, Tag = TAG, MultiplierAttribute = MULTIPLIER_ATTRIBUTE }
