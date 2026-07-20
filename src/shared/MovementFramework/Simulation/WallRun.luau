--!strict
--[[
	WallRun.luau
	Purpose: Modular wall-running solver (Titanfall-flavoured). Probes for a
	vertical wall beside the player, clips velocity onto the wall plane
	(momentum preservation), applies scaled-down gravity and exposes the wall
	side/normal through MoveState for camera tilt and wall jumps.
	Architecture notes: Pure over TraceFn + MoveState + profile. Every scrap of
	wall-run state lives in MoveState - never in this module - so prediction
	rollback replays runs bit-identically and the snapshot can carry them.
	Budget model: wallRunTimer is a resource refilled by the simulator on
	ground contact and drained while attached; when it empties the player peels
	off and cannot re-attach until they touch ground. This is what prevents
	infinite corridor climbing without needing per-wall bookkeeping.
]]

local Types = require(script.Parent.Parent.Core.Types)
local VectorMath = require(script.Parent.Parent.Math.VectorMath)
local MovementConfig = require(script.Parent.Parent.Config.MovementConfig)

local WallRun = {}

-- Walls must be near-vertical: anything flatter is ground/ramp territory and
-- belongs to the ground tracer, not to us.
local MAX_WALL_NORMAL_Y = 0.3
-- Constant lateral pull that keeps the collider pressed through the SKIN gap;
-- the slide solver clips it against the wall every tick so it never accumulates.
local WALL_STICK_SPEED = 1.5

-- Advances one tick of wall running. Returns true when this solver owned the
-- tick's acceleration phase (the simulator then skips ground/air move).
function WallRun.step(
	trace: Types.TraceFn,
	state: Types.MoveState,
	wishForward: boolean,
	profile: MovementConfig.MovementProfile,
	dt: number
): boolean
	-- Wall jump first: a buffered press must fire even on the tick the run
	-- would otherwise end, or bunny-timed wall jumps eat inputs.
	if state.wallRunSide ~= 0 and state.jumpBufferTimer > 0 then
		local n = state.wallNormal
		local vy = math.max(state.velocity.Y, 0) + profile.WallRunJumpBoost
		state.velocity = Vector3.new(
			state.velocity.X + n.X * profile.WallRunJumpKick,
			vy,
			state.velocity.Z + n.Z * profile.WallRunJumpKick
		)
		state.jumpBufferTimer = 0
		state.jumpedThisTick = true
		state.wallRunSide = 0
		state.wallRunTimer = 0 -- jump consumes the remaining budget
		return false -- fall through to airMove: gravity resumes this tick
	end

	if not wishForward or state.wallRunTimer <= 0 then
		state.wallRunSide = 0
		return false
	end

	local flat = VectorMath.flatten(state.velocity)
	local speed = flat.Magnitude
	if speed < profile.WallRunMinSpeed then
		state.wallRunSide = 0
		return false
	end
	local dir = flat / speed
	-- Right vector relative to travel direction: cross(dir, up).
	local rightDir = Vector3.new(-dir.Z, 0, dir.X)
	local reach = profile.ColliderSize.X * 0.5 + profile.WallRunStickDistance

	-- Probe the side we are already attached to first: in corners both sides
	-- can hit, and preferring the current wall prevents side flip-flop.
	local firstSide = if state.wallRunSide ~= 0 then state.wallRunSide else 1
	local side = firstSide
	local tr = trace(state.position, rightDir * (reach * firstSide))
	local found = tr.hit and math.abs(tr.normal.Y) < MAX_WALL_NORMAL_Y
	if not found then
		side = -firstSide
		tr = trace(state.position, rightDir * (reach * side))
		found = tr.hit and math.abs(tr.normal.Y) < MAX_WALL_NORMAL_Y
	end
	if not found then
		state.wallRunSide = 0
		return false
	end

	-- Copy the normal immediately: TraceResult is pooled by the collision layer.
	local wallNormal = tr.normal
	state.wallRunSide = side
	state.wallNormal = wallNormal
	state.wallRunTimer = math.max(state.wallRunTimer - dt, 0)

	-- Momentum preservation: remove only the into-wall component, keep every
	-- stud of tangential speed, then apply the reduced gravity that sells the run.
	local vel = VectorMath.clipVelocity(state.velocity, wallNormal, 1.0)
	vel += Vector3.new(0, -profile.Gravity * profile.WallRunGravityScale * dt, 0)
	vel -= wallNormal * WALL_STICK_SPEED
	state.velocity = vel
	return true
end

return table.freeze(WallRun)
