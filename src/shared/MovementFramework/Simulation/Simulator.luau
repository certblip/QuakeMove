--!strict
--[[
	Simulator.luau
	Purpose: The deterministic movement kernel. step(state, cmd) advances one fixed
	tick: timers -> jump resolution -> friction/acceleration -> slide-move solve ->
	ground trace -> state classification. Identical (state, cmd) always produces an
	identical result, on client and server - the contract prediction depends on.
	Architecture notes: Owns no engine objects; collision arrives as a TraceFn. The
	kernel routes to per-mode solvers (ladder/wallrun/ground/air) but never contains
	engine, camera, input, networking or rendering code.
	Crouch: state.position is always the CURRENT box centre. Entering the crouch
	stance drops the centre by half the height difference (feet stay planted);
	standing up first probes the full hull for headroom (Source ceiling lock).
	Performance: All working storage is pre-allocated; the bound trace closure is
	created once. The tick performs zero heap allocations.
]]

local Types = require(script.Parent.Parent.Core.Types)
local VectorMath = require(script.Parent.Parent.Math.VectorMath)
local QuakeMath = require(script.Parent.QuakeMath)
local AirPhysics = require(script.Parent.AirPhysics)
local SlideMove = require(script.Parent.SlideMove)
local GroundTracer = require(script.Parent.GroundTracer)
local WallRun = require(script.Parent.WallRun)
local LadderMove = require(script.Parent.LadderMove)
local StateMachine = require(script.Parent.StateMachine)
local MovementConfig = require(script.Parent.Parent.Config.MovementConfig)

local Buttons = Types.Buttons
local MoveStates = Types.MoveStates

export type Simulator = {
	Step: (self: Simulator, state: Types.MoveState, cmd: Types.InputCommand) -> (),
	SetProfile: (self: Simulator, profile: MovementConfig.MovementProfile) -> (),
	GetProfile: (self: Simulator) -> MovementConfig.MovementProfile,
	SetTrace: (self: Simulator, trace: Types.TraceFn) -> (),
	GetLastSlideOutput: (self: Simulator) -> SlideMove.SlideOutput,
}

type SimulatorInternal = Simulator & {
	_profile: MovementConfig.MovementProfile,
	_trace: Types.TraceFn,
	_slideOut: SlideMove.SlideOutput,
	_crouched: boolean, -- pose flag the bound trace reads (no per-tick allocation)
	_boundTrace: Types.TraceFn,
}

local Simulator = {}
Simulator.__index = Simulator

function Simulator.SetProfile(self: SimulatorInternal, profile: MovementConfig.MovementProfile)
	self._profile = profile
end

function Simulator.GetProfile(self: SimulatorInternal): MovementConfig.MovementProfile
	return self._profile
end

function Simulator.SetTrace(self: SimulatorInternal, trace: Types.TraceFn)
	self._trace = trace
end

function Simulator.GetLastSlideOutput(self: SimulatorInternal): SlideMove.SlideOutput
	return self._slideOut
end

local function hasButton(cmd: Types.InputCommand, flag: number): boolean
	return bit32.band(cmd.buttons, flag) ~= 0
end

-- Headroom the standing hull needs on top of the crouched one.
local function missingHeadroom(p: MovementConfig.MovementProfile): number
	return p.ColliderSize.Y - p.CrouchColliderHeight
end

-- Ground movement: friction -> accelerate -> clip velocity onto the ground plane
-- so ramp ascent/descent follows the surface without vertical popping.
local function groundMove(
	self: SimulatorInternal,
	state: Types.MoveState,
	cmd: Types.InputCommand,
	wishDir: Vector3,
	sprinting: boolean,
	sliding: boolean
)
	local p = self._profile
	local dt = cmd.dt

	local friction = if sliding then p.SlideFriction else p.Friction
	state.velocity = QuakeMath.applyFriction(state.velocity, friction, p.StopSpeed, dt)

	local wishSpeed = p.GroundSpeed
	if sprinting then
		wishSpeed *= p.SprintMultiplier
	end
	if state.crouching then
		wishSpeed *= p.CrouchSpeedMultiplier
	end
	state.wishSpeed = wishSpeed

	if not sliding and wishDir ~= VectorMath.ZERO then
		local newVel, accel = QuakeMath.accelerate(state.velocity, wishDir, wishSpeed, p.GroundAcceleration, dt)
		state.velocity = newVel
		state.lastAcceleration = accel
	else
		state.lastAcceleration = 0
	end

	-- Follow the ground plane (walk up/down slopes, ride ramps).
	if state.groundNormal.Y < 0.999 then
		local speed = state.velocity.Magnitude
		local clipped = VectorMath.clipVelocity(state.velocity, state.groundNormal, 1.0)
		local clippedUnit = VectorMath.safeUnit(clipped)
		state.velocity = clippedUnit * speed
	end
end

-- Air movement: gravity + pluggable air acceleration (airstrafing lives here).
local function airMove(
	self: SimulatorInternal,
	state: Types.MoveState,
	cmd: Types.InputCommand,
	wishDir: Vector3,
	surfing: boolean
)
	local p = self._profile
	local dt = cmd.dt

	if surfing and p.SurfFriction > 0 then
		state.velocity = QuakeMath.applyFriction(state.velocity, p.SurfFriction, p.StopSpeed, dt)
	end

	local wishSpeed = math.min(p.GroundSpeed, p.MaxAirWishSpeed)
	state.wishSpeed = wishSpeed

	if wishDir ~= VectorMath.ZERO then
		local newVel, accel =
			AirPhysics.airAccelerate(state.velocity, wishDir, wishSpeed, cmd.moveX, cmd.moveZ, p, dt)
		state.velocity = newVel
		state.lastAcceleration = accel
	else
		state.lastAcceleration = 0
	end

	state.velocity += Vector3.new(0, -p.Gravity * dt, 0)
end

local function tryJump(self: SimulatorInternal, state: Types.MoveState): boolean
	local p = self._profile
	local canJump = state.grounded or state.coyoteTimer > 0
	if not canJump then
		return false
	end
	-- Preserve horizontal momentum entirely; only replace vertical (bhop core).
	local vy = math.max(state.velocity.Y, 0) + p.JumpPower
	state.velocity = Vector3.new(state.velocity.X, vy, state.velocity.Z)
	state.grounded = false
	state.coyoteTimer = 0
	state.jumpBufferTimer = 0
	state.jumpedThisTick = true
	state.slideTimer = 0
	return true
end

-- Resolve the crouch stance. The slide key doubles as crouch: while a slide runs
-- crouch waits, and when the slide ends with the key still held the player flows
-- into the duck. Standing up is gated by a headroom probe (Source ceiling lock).
-- The hull shrinks from the TOP inside the collision layer - state.position is
-- ALWAYS the standing-box centre and never moves on stance changes, which keeps
-- ducking teleport-free for prediction, camera and networking alike.
local function resolveStance(self: SimulatorInternal, state: Types.MoveState, cmd: Types.InputCommand, sliding: boolean)
	local p = self._profile
	if not p.CrouchEnabled then
		if state.crouching then
			state.crouching = false
		end
		self._crouched = false
		return
	end
	local wantCrouch = hasButton(cmd, Buttons.Slide) and not sliding

	if wantCrouch and not state.crouching then
		state.crouching = true
	elseif not wantCrouch and state.crouching then
		-- Probe the missing headroom with the CURRENT (crouched) hull: sweeping
		-- it up by the height difference covers exactly the volume the standing
		-- hull adds. A hit = a ceiling occupies that space -> stay ducked.
		local headroom = self._boundTrace(state.position, Vector3.new(0, missingHeadroom(p), 0))
		if not headroom.hit then
			state.crouching = false
		end
	end
	self._crouched = state.crouching
end

function Simulator.Step(self: SimulatorInternal, state: Types.MoveState, cmd: Types.InputCommand)
	local p = self._profile
	local dt = cmd.dt
	local trace = self._boundTrace
	self._crouched = state.crouching -- sync pose after any reconciliation rollback

	state.tick = cmd.tick
	state.prevStateId = state.stateId
	state.jumpedThisTick = false
	state.landedThisTick = false
	local wasGrounded = state.grounded

	-- 1. Timers
	state.coyoteTimer = math.max(state.coyoteTimer - dt, 0)
	state.jumpBufferTimer = math.max(state.jumpBufferTimer - dt, 0)
	state.landingTimer = math.max(state.landingTimer - dt, 0)
	if state.slideTimer > 0 then
		state.slideTimer = math.max(state.slideTimer - dt, 0)
	end

	-- 2. Intent
	local wishDir = VectorMath.wishDirection(cmd.yaw, cmd.moveX, cmd.moveZ)
	state.wishDir = wishDir
	local sprinting = hasButton(cmd, Buttons.Sprint)
	local jumpHeld = hasButton(cmd, Buttons.Jump)
	local autoJump = p.AutoJump or hasButton(cmd, Buttons.AutoJump)

	if jumpHeld then
		if autoJump then
			state.jumpBufferTimer = p.JumpBufferTime
		elseif not state.jumpHeldPrev then
			state.jumpBufferTimer = p.JumpBufferTime
		end
	end
	state.jumpHeldPrev = jumpHeld

	-- 3. Slide start (ground + sprint-speed + button, and not already ducked)
	if
		p.SlideEnabled
		and hasButton(cmd, Buttons.Slide)
		and state.grounded
		and state.slideTimer <= 0
		and not state.crouching
	then
		local hSpeed = VectorMath.horizontalLength(state.velocity)
		if hSpeed > p.GroundSpeed * 0.9 and state.prevStateId ~= MoveStates.Sliding then
			state.slideTimer = p.SlideMaxTime
			local flat = VectorMath.safeUnit(VectorMath.flatten(state.velocity))
			-- Capped, non-stacking boost (see H3): re-pressing cannot compound.
			local cap = p.GroundSpeed * p.SprintMultiplier * p.SlideMultiplier
			local boosted = math.min(hSpeed * p.SlideMultiplier, math.max(cap, hSpeed))
			state.velocity = VectorMath.withY(flat * boosted, state.velocity.Y)
		end
	end
	local sliding = state.slideTimer > 0
	if sliding and VectorMath.horizontalLength(state.velocity) < p.SlideMinSpeed then
		state.slideTimer = 0
		sliding = false
	end
	if not hasButton(cmd, Buttons.Slide) then
		state.slideTimer = 0
		sliding = false
	end

	-- 3b. Crouch stance (also drives the collision hull height via _crouched).
	resolveStance(self, state, cmd, sliding)

	-- 4. Jump (buffered)
	if state.jumpBufferTimer > 0 then
		tryJump(self, state)
	end

	-- 5. Ground contact BEFORE the move (Quake order: friction uses last tick's ground)
	local ground = GroundTracer.trace(trace, state.position, state.velocity, p)
	local surfing = ground.surfing

	if state.grounded then
		state.groundNormal = ground.normal
		state.surfaceAngle = ground.angle
	end

	-- 6. Accelerate. Dispatch priority: ladder > wall run > ground > air.
	local laddered = false
	if p.LadderEnabled then
		laddered = LadderMove.step(trace, state, cmd, wishDir, p, dt)
	end
	local wallRunning = false
	if not laddered and not state.onLadder and not state.grounded and p.WallRunEnabled then
		wallRunning = WallRun.step(trace, state, cmd.moveZ > 0, p, dt)
	end
	if laddered or wallRunning then
		-- Velocity fully resolved by the dedicated solver this tick.
	elseif state.grounded and not state.jumpedThisTick then
		groundMove(self, state, cmd, wishDir, sprinting, sliding)
	else
		airMove(self, state, cmd, wishDir, surfing)
	end

	state.velocity = QuakeMath.clampVelocity(state.velocity, p.MaxVelocity)

	-- 7. Solve movement against the world (bound trace carries the pose hull)
	local impactVelY = state.velocity.Y
	local out = self._slideOut
	SlideMove.stepSlide(
		trace,
		state.position,
		state.velocity,
		dt,
		state.grounded,
		p.StepHeight,
		p.MaxBumps,
		p.MaxClipPlanes,
		p.Overbounce,
		out
	)
	state.position = out.position
	state.velocity = out.velocity
	state.collisionCount = out.collisionCount

	-- 8. Ground contact AFTER the move: landing detection + snapping
	local preLandVelY = state.velocity.Y
	ground = GroundTracer.trace(trace, state.position, state.velocity, p)
	state.grounded = ground.grounded
	state.groundNormal = ground.normal
	state.surfaceAngle = ground.angle

	if state.grounded then
		state.coyoteTimer = p.CoyoteTime
		state.wallRunTimer = p.WallRunMaxTime
		state.wallRunSide = 0
		if ground.snapPosition and preLandVelY <= 0 then
			state.position = ground.snapPosition :: Vector3
		end
		if not wasGrounded then
			state.landedThisTick = true
			state.landingSpeed = math.max(-impactVelY, 0)
			state.landingTimer = p.LandingRecoveryTime
			state.velocity = VectorMath.clipVelocity(state.velocity, ground.normal, 1.0)
		end
	end

	-- 9. Classify
	state.stateId = StateMachine.evaluate(state, p, surfing, sprinting)
end

local function new(profile: MovementConfig.MovementProfile, trace: Types.TraceFn): Simulator
	local self: SimulatorInternal = setmetatable({
		_profile = profile,
		_trace = trace,
		_slideOut = SlideMove.newOutput(),
		_crouched = false,
		_boundTrace = nil :: any,
	}, Simulator) :: any
	-- One closure for the session: forwards the current pose to the raw trace so
	-- every probe this tick uses the correct (standing vs crouched) hull.
	self._boundTrace = function(origin: Vector3, delta: Vector3, _crouched: boolean?): Types.TraceResult
		return self._trace(origin, delta, self._crouched)
	end
	return self
end

return { new = new }
