--!strict
--[[
	AirPhysics.luau
	Purpose: Pluggable air-acceleration strategies - Quake (Q3 pmove), Source
	(HL2 gamemovement) and CPM (Challenge ProMode) - selected per movement
	profile. The simulator delegates ALL airborne acceleration here so the
	kernel never branches on game feel.
	Architecture notes: Pure functions of (velocity, input, profile, dt); no
	state, no engine types. Adding a new mode = one new branch here plus a
	profile value - nothing else in the framework changes.
	Determinism: identical inputs yield identical outputs on client and server,
	which keeps every mode prediction-safe.
]]

local VectorMath = require(script.Parent.Parent.Math.VectorMath)
local QuakeMath = require(script.Parent.QuakeMath)
local MovementConfig = require(script.Parent.Parent.Config.MovementConfig)

local AirPhysics = {}

-- Source's CGameMovement::AirAccelerate. The asymmetry vs Quake is subtle but
-- decisive: addspeed is measured against the CAPPED wishspeed, while the accel
-- increment scales with the UNCAPPED one. That is why Source surf keeps
-- gaining speed along ramps where Q3 air accel would have saturated.
local function sourceAirAccelerate(
	velocity: Vector3,
	wishDir: Vector3,
	wishSpeed: number,
	speedCap: number,
	accel: number,
	dt: number
): (Vector3, number)
	local capped = if wishSpeed > speedCap then speedCap else wishSpeed
	local currentSpeed = velocity.X * wishDir.X + velocity.Z * wishDir.Z
	local addSpeed = capped - currentSpeed
	if addSpeed <= 0 then
		return velocity, 0
	end
	local accelSpeed = accel * wishSpeed * dt -- uncapped: the Source signature
	if accelSpeed > addSpeed then
		accelSpeed = addSpeed
	end
	return velocity + wishDir * accelSpeed, accelSpeed / dt
end

-- CPM air control (CPM_PM_Aircontrol): rotates the horizontal velocity toward
-- the wish direction WITHOUT adding speed. dot^2 falloff means control is
-- strongest when already flying roughly where you look - it tightens turns,
-- it never accelerates. Vertical velocity is untouched.
local function cpmAirControl(velocity: Vector3, wishDir: Vector3, airControl: number, dt: number): Vector3
	local vy = velocity.Y
	local flat = Vector3.new(velocity.X, 0, velocity.Z)
	local speed = flat.Magnitude
	if speed < 1e-4 then
		return velocity
	end
	local dir = flat / speed
	local dot = dir:Dot(wishDir)
	if dot > 0 then
		-- 32 is the classic CPMA constant; keeping it matches community tuning
		-- tables for the profile's AirControl value.
		local k = 32 * airControl * dot * dot * dt
		local newDir = VectorMath.safeUnit(dir * speed + wishDir * k)
		if newDir ~= VectorMath.ZERO then
			flat = newDir * speed -- turn only: magnitude preserved exactly
		end
	end
	return Vector3.new(flat.X, vy, flat.Z)
end

-- Single dispatch point consumed by the simulator's airMove.
function AirPhysics.airAccelerate(
	velocity: Vector3,
	wishDir: Vector3,
	wishSpeed: number,
	moveX: number,
	moveZ: number,
	profile: MovementConfig.MovementProfile,
	dt: number
): (Vector3, number)
	local mode = profile.AirAccelMode

	if mode == "Source" then
		return sourceAirAccelerate(velocity, wishDir, wishSpeed, profile.AirSpeedCap, profile.AirAcceleration, dt)
	end

	if mode == "CPM" then
		-- Pure strafe (A/D only): Q3-style capped accel at the dedicated high
		-- strafe constant - the CPM "double-beat" strafe jump.
		if moveX ~= 0 and moveZ == 0 then
			return QuakeMath.airAccelerate(
				velocity,
				wishDir,
				wishSpeed,
				profile.CPMStrafeSpeedCap,
				profile.CPMStrafeAcceleration,
				dt
			)
		end
		-- Wishing against current travel brakes harder (air stop), matching
		-- CPM's instant direction changes.
		local accel = profile.AirAcceleration
		if velocity.X * wishDir.X + velocity.Z * wishDir.Z < 0 then
			accel *= profile.CPMAirStopAcceleration
		end
		local newVel, gained =
			QuakeMath.airAccelerate(velocity, wishDir, wishSpeed, profile.AirSpeedCap, accel, dt)
		-- Air control only engages on pure forward/back input, exactly like CPMA.
		if moveZ ~= 0 and moveX == 0 and profile.CPMAirControl > 0 then
			newVel = cpmAirControl(newVel, wishDir, profile.CPMAirControl, dt)
		end
		return newVel, gained
	end

	return QuakeMath.airAccelerate(velocity, wishDir, wishSpeed, profile.AirSpeedCap, profile.AirAcceleration, dt)
end

return table.freeze(AirPhysics)
