--!strict
--[[
	LadderMove.luau
	Purpose: Source-style ladder movement. While attached, velocity is the view
	direction mapped onto the ladder plane times climb speed - looking up +
	forward climbs, looking down descends, strafing shimmies. Gravity is fully
	suppressed; jumping kicks away from the ladder.
	Architecture notes: Detection is trace-driven: the collision layer marks
	climbable surfaces on TraceResult.ladder (CollectionService tag), so this
	module stays engine-free and unit-testable with analytic traces.
	Determinism: attachment state (onLadder + ladderNormal) lives in MoveState
	and replicates in the snapshot, keeping rollback replays exact.
]]

local Types = require(script.Parent.Parent.Core.Types)
local VectorMath = require(script.Parent.Parent.Math.VectorMath)
local MovementConfig = require(script.Parent.Parent.Config.MovementConfig)

local LadderMove = {}

-- Ladders are near-vertical surfaces; flatter climbable geometry would fight
-- the ground tracer.
local MAX_LADDER_NORMAL_Y = 0.5
-- Constant pull toward the ladder so the collider keeps contact through the
-- collision SKIN; clipped by the slide solver every tick, never accumulates.
local LADDER_STICK_SPEED = 1.5

local function probeReach(profile: MovementConfig.MovementProfile): number
	return profile.ColliderSize.Z * 0.5 + 0.6
end

-- Attempts to attach: traces along the wish direction (players climb what
-- they push into, matching Source's "+forward onto ladder" feel).
local function tryAttach(
	trace: Types.TraceFn,
	state: Types.MoveState,
	wishDir: Vector3,
	profile: MovementConfig.MovementProfile
): boolean
	if wishDir == VectorMath.ZERO then
		return false
	end
	local tr = trace(state.position, wishDir * probeReach(profile))
	if tr.hit and tr.ladder and math.abs(tr.normal.Y) < MAX_LADDER_NORMAL_Y then
		state.onLadder = true
		state.ladderNormal = tr.normal -- copy now: TraceResult is pooled
		state.wallRunSide = 0 -- ladders take priority over wall runs
		return true
	end
	return false
end

-- Advances one tick of ladder movement. Returns true when attached and the
-- solver owned this tick's acceleration phase.
function LadderMove.step(
	trace: Types.TraceFn,
	state: Types.MoveState,
	cmd: Types.InputCommand,
	wishDir: Vector3,
	profile: MovementConfig.MovementProfile,
	dt: number
): boolean
	if not state.onLadder then
		if not tryAttach(trace, state, wishDir, profile) then
			return false
		end
	end

	-- Jump-off: buffered press kicks away from the ladder plane.
	if state.jumpBufferTimer > 0 then
		local n = state.ladderNormal
		state.velocity = Vector3.new(
			n.X * profile.LadderJumpKick,
			math.max(state.velocity.Y, 0) + profile.WallRunJumpBoost * 0.5,
			n.Z * profile.LadderJumpKick
		)
		state.jumpBufferTimer = 0
		state.jumpedThisTick = true
		state.onLadder = false
		return false -- airMove resumes gravity this tick
	end

	-- Still touching? Re-probe INTO the ladder; letting go the moment the
	-- surface ends is what makes ladder tops feel like Source (you pop over
	-- the lip via residual velocity instead of sticking).
	local tr = trace(state.position, -state.ladderNormal * probeReach(profile))
	if not (tr.hit and tr.ladder) then
		state.onLadder = false
		return false
	end
	state.ladderNormal = tr.normal

	-- Source climb: full 3D look vector scaled by input, then flattened onto
	-- the ladder plane. Looking up + W climbs; looking down + W descends.
	local cosPitch = math.cos(cmd.pitch)
	local look = Vector3.new(
		-math.sin(cmd.yaw) * cosPitch,
		math.sin(cmd.pitch),
		-math.cos(cmd.yaw) * cosPitch
	)
	local right = Vector3.new(-look.Z, 0, look.X)
	local climb = (look * cmd.moveZ + right * cmd.moveX) * profile.LadderClimbSpeed
	climb = VectorMath.clipVelocity(climb, state.ladderNormal, 1.0)

	state.velocity = climb - state.ladderNormal * LADDER_STICK_SPEED
	state.wishSpeed = profile.LadderClimbSpeed
	state.lastAcceleration = 0
	local _ = dt
	return true
end

return table.freeze(LadderMove)
