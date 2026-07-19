--!strict
--[[
	QuakeMath.luau
	Purpose: The mathematical heart - direct ports of id Software's pmove functions
	(PM_Friction, PM_Accelerate, PM_AirAccelerate) expressed over Vector3.
	Architecture notes: Pure functions of (velocity, params, dt). No state, no
	engine types, fully unit-testable off-platform.
	Non-obvious algorithm notes are inline; everything else is the canonical math.
]]

local VectorMath = require(script.Parent.Parent.Math.VectorMath)

local QuakeMath = {}

-- PM_Friction. `control = max(speed, stopSpeed)` is what makes low-speed stops
-- feel instant: friction is computed against an inflated speed near standstill.
function QuakeMath.applyFriction(
	velocity: Vector3,
	friction: number,
	stopSpeed: number,
	dt: number
): Vector3
	local speed = VectorMath.horizontalLength(velocity)
	if speed < 0.1 then
		return Vector3.new(0, velocity.Y, 0)
	end
	local control = if speed < stopSpeed then stopSpeed else speed
	local drop = control * friction * dt
	local newSpeed = math.max(speed - drop, 0) / speed
	return Vector3.new(velocity.X * newSpeed, velocity.Y, velocity.Z * newSpeed)
end

-- PM_Accelerate. The projection `currentSpeed = dot(velocity, wishDir)` is the
-- key: acceleration only fills the gap along the wish direction, which is exactly
-- why turning while accelerating gains speed (airstrafe) - the perpendicular
-- component of existing velocity is never counted against the cap.
function QuakeMath.accelerate(
	velocity: Vector3,
	wishDir: Vector3,
	wishSpeed: number,
	accel: number,
	dt: number
): (Vector3, number)
	local currentSpeed = velocity.X * wishDir.X + velocity.Z * wishDir.Z
	local addSpeed = wishSpeed - currentSpeed
	if addSpeed <= 0 then
		return velocity, 0
	end
	local accelSpeed = accel * wishSpeed * dt
	if accelSpeed > addSpeed then
		accelSpeed = addSpeed
	end
	return velocity + wishDir * accelSpeed, accelSpeed / dt
end

-- PM_AirAccelerate: identical shape, but wishSpeed is clamped to a tiny cap
-- (30ups in Quake). This clamp is what makes the mouse-wiggle strafe gain exist
-- at all - see accelerate() note above.
function QuakeMath.airAccelerate(
	velocity: Vector3,
	wishDir: Vector3,
	wishSpeed: number,
	speedCap: number,
	accel: number,
	dt: number
): (Vector3, number)
	local cappedWish = if wishSpeed > speedCap then speedCap else wishSpeed
	return QuakeMath.accelerate(velocity, wishDir, cappedWish, accel, dt)
end

-- Hard velocity ceiling; preserves direction.
function QuakeMath.clampVelocity(velocity: Vector3, maxVelocity: number): Vector3
	local m = velocity.Magnitude
	if m > maxVelocity then
		return velocity * (maxVelocity / m)
	end
	return velocity
end

return table.freeze(QuakeMath)
