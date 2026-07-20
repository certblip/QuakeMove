--!strict
--[[
	Simulator.luau
	Purpose: The deterministic movement kernel. step(state, cmd) advances one fixed
	tick: timers -> jump resolution -> friction/acceleration -> slide-move solve ->
	ground trace -> state classification. Identical (state, cmd) always produces an
	identical result, on client and server - the contract prediction depends on.
	Architecture notes: Owns no engine objects; collision arrives as a TraceFn.
	Never touches camera, input devices, networking or rendering.
	Performance: All working storage (slide output, ground info) is pre-allocated.
	Vector3 math is value-type; the tick performs zero heap allocations.
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
	-- Read-only view of the last solve's clip planes (debug visualization).
	GetLastSlideOutput: (self: Simulator) -> SlideMove.SlideOutput,
}

type SimulatorInternal = Simulator & {
	_profile: MovementConfig.MovementProfile,
	_trace: Types.TraceFn,
	_slideOut: SlideMove.SlideOutput,
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
		-- Preserve speed along the plane (Quake keeps magnitude when walking slopes).
		state.velocity = clippedUnit * speed
	end
end

-- Air movement: gravity + capped-wishspeed air acceleration (airstrafing lives here).
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
		-- Strategy dispatch (Quake / Source / CPM) lives in AirPhysics so the
		-- kernel stays feel-agnostic; the profile alone decides the mode.
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
	-- On upward ramps keep positive Y (additive ramp jump).
	local vy = math.max(state.velocity.Y, 0) + p.JumpPower
	state.velocity = Vector3.new(state.velocity.X, vy, state.velocity.Z)
	state.grounded = false
	state.coyoteTimer = 0
	state.jumpBufferTimer = 0
	state.jumpedThisTick = true
	state.slideTimer = 0
	return true
end

function Simulator.Step(self: SimulatorInternal, state: Types.MoveState, cmd: Types.InputCommand)
	local p = self._profile
	local dt = cmd.dt
	local trace = self._trace

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
			-- Auto-jump: holding jump re-queues every tick => frame-perfect bhop.
			state.jumpBufferTimer = p.JumpBufferTime
		elseif not state.jumpHeldPrev then
			-- Rising edge without autojump: buffer exactly once per press.
			-- Holding must not extend the buffer, so only the not-held -> held
			-- transition arms it. The edge lives in MoveState, making it a pure
			-- function of (state, cmd) - prediction rollback replays it exactly.
			state.jumpBufferTimer = p.JumpBufferTime
		end
	end
	state.jumpHeldPrev = jumpHeld

	-- 3. Slide start (requires ground + sprint-speed + button edge)
	if p.SlideEnabled and hasButton(cmd, Buttons.Slide) and state.grounded and state.slideTimer <= 0 then
		local hSpeed = VectorMath.horizontalLength(state.velocity)
		if hSpeed > p.GroundSpeed * 0.9 and state.prevStateId ~= MoveStates.Sliding then
			state.slideTimer = p.SlideMaxTime
			local flat = VectorMath.safeUnit(VectorMath.flatten(state.velocity))
			-- The boost is capped at sprint*multiplier and never stacks: each
			-- re-press used to multiply current speed, letting key-pumping
			-- compound to MaxVelocity. Above the cap the slide keeps (never
			-- gains) speed, preserving momentum runs without the exploit.
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
	-- Each solver fully owns its tick (velocity in, velocity out); the kernel
	-- only routes, so adding a movement mode never touches the math below.
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

	-- 7. Solve movement against the world
	local impactVelY = state.velocity.Y -- impact speed BEFORE the solver clips it
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
		-- Ground contact refills the wall-run budget and clears attachment -
		-- the resource model that stops infinite corridor climbing.
		state.wallRunTimer = p.WallRunMaxTime
		state.wallRunSide = 0
		if ground.snapPosition and preLandVelY <= 0 then
			state.position = ground.snapPosition :: Vector3
		end
		if not wasGrounded then
			state.landedThisTick = true
			-- Use the PRE-solve vertical speed: the slide solver has already
			-- clipped velocity against the floor plane by now, so the
			-- post-solve value would always read ~0 and mute landing effects.
			state.landingSpeed = math.max(-impactVelY, 0)
			state.landingTimer = p.LandingRecoveryTime
			-- Kill downward velocity into the plane; keep the tangential part
			-- (momentum preservation on landing - critical for bhop chains).
			state.velocity = VectorMath.clipVelocity(state.velocity, ground.normal, 1.0)
		end
	end

	-- 9. Classify
	state.stateId = StateMachine.evaluate(state, p, surfing, sprinting)
end

local function new(profile: MovementConfig.MovementProfile, trace: Types.TraceFn): Simulator
	return setmetatable({
		_profile = profile,
		_trace = trace,
		_slideOut = SlideMove.newOutput(),
	}, Simulator) :: any
end

return { new = new }
