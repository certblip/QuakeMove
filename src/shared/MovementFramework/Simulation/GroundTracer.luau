--!strict
--[[
	GroundTracer.luau
	Purpose: Determines ground contact, surface normal, slope classification and
	performs ground snapping - while deliberately NOT snapping when the player has
	upward velocity above the ramp-boost threshold (this preserves ramp launches
	and knee-high ramp jumps exactly like Quake's PM_GroundTrace).
	Architecture notes: Pure over TraceFn; writes into the caller's MoveState.
]]

local Types = require(script.Parent.Parent.Core.Types)
local VectorMath = require(script.Parent.Parent.Math.VectorMath)
local MovementConfig = require(script.Parent.Parent.Config.MovementConfig)

local GroundTracer = {}

export type GroundInfo = {
	grounded: boolean,
	surfing: boolean,
	normal: Vector3,
	angle: number,
	snapPosition: Vector3?,
}

local info: GroundInfo = {
	grounded = false,
	surfing = false,
	normal = Vector3.yAxis,
	angle = 0,
	snapPosition = nil,
}

function GroundTracer.trace(
	traceFn: Types.TraceFn,
	position: Vector3,
	velocity: Vector3,
	profile: MovementConfig.MovementProfile
): GroundInfo
	info.grounded = false
	info.surfing = false
	info.normal = Vector3.yAxis
	info.angle = 0
	info.snapPosition = nil

	local tr = traceFn(position, Vector3.new(0, -profile.GroundSnapDistance, 0))
	if not tr.hit then
		return info
	end

	-- Ramp-launch rule (Q3 PM_GroundTrace / Source CategorizePosition): refuse
	-- ground only when moving AWAY from the surface fast enough. Raw upward
	-- speed alone must NOT unground you - running up a walkable ramp gives a
	-- large velocity.Y that is TANGENT to the plane, and snapping out there
	-- would flicker the ascent airborne and bleed momentum. dot(velocity,
	-- normal) isolates the true separation speed, which both preserves ramp
	-- launches (leaving the lip) and keeps uphill sprints grounded.
	if velocity.Y > profile.RampBoostThreshold and velocity:Dot(tr.normal) > profile.RampBoostThreshold then
		return info
	end

	local angle = VectorMath.surfaceAngle(tr.normal)
	info.normal = tr.normal
	info.angle = angle

	if angle <= profile.SlopeLimit then
		info.grounded = true
		info.snapPosition = tr.position
	else
		-- Too steep to stand: surf surface. Contact, but never grounded, never
		-- snapped, gravity keeps pressing us into the ramp.
		info.surfing = tr.fraction < 0.6
	end
	return info
end

return table.freeze(GroundTracer)
