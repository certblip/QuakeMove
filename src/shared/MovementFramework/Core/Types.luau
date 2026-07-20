--!strict
--[[
	Types.luau
	Purpose: Canonical type definitions shared by every layer of the framework.
	Architecture notes: This module contains ONLY types and pure constant tables.
	It has zero dependencies and may be required from anywhere without creating cycles.
	Performance: Types are erased at runtime; the enum tables are frozen and reused.
]]

-- Deterministic movement state enum. Numeric values are stable and are what gets
-- replicated over the wire, so never reorder them.
export type MoveStateId = number

local MoveStates = table.freeze({
	Idle = 1,
	Walking = 2,
	Running = 3,
	Jumping = 4,
	Falling = 5,
	Landing = 6,
	Sliding = 7,
	Surfing = 8,
	Ramp = 9,
	-- Appended (never reorder: ids replicate). Ids must stay <= 15: the
	-- snapshot packs stateId into the low 4 bits of the flags byte.
	WallRunning = 10,
	Ladder = 11,
	Crouching = 12,
})

-- Bit flags packed into InputCommand.buttons.
local Buttons = table.freeze({
	Jump = 0b00000001,
	Sprint = 0b00000010,
	Slide = 0b00000100,
	AutoJump = 0b00001000,
})

-- One quantum of player intent. This is the ONLY thing the simulation is allowed
-- to read from the outside world, which is what makes prediction/rollback possible.
export type InputCommand = {
	tick: number, -- simulation tick index this command applies to
	moveX: number, -- strafe axis, -1..1
	moveZ: number, -- forward axis, -1..1
	yaw: number, -- view yaw in radians (wish direction basis)
	pitch: number, -- view pitch in radians (used for surf-look mechanics & camera)
	buttons: number, -- Buttons bit field
	dt: number, -- fixed timestep for this tick
}

-- Full simulation state. Mutated in place by the simulator; snapshotted (copied)
-- by the prediction buffer. All fields are value types => copying is allocation-cheap.
export type MoveState = {
	tick: number,
	position: Vector3,
	velocity: Vector3,
	grounded: boolean,
	groundNormal: Vector3,
	surfaceAngle: number, -- degrees from horizontal of the ground plane
	stateId: MoveStateId,
	prevStateId: MoveStateId,

	-- timers (seconds, counted down by the simulator)
	coyoteTimer: number,
	jumpBufferTimer: number,
	landingTimer: number,
	slideTimer: number,

	-- Jump button state on the previous tick. Enables deterministic
	-- rising-edge detection (non-autojump buffering) that survives
	-- prediction rollback/replay. Replicated via the snapshot flags byte.
	jumpHeldPrev: boolean,

	-- Wall running. All of it lives in MoveState (not in the solver) so that
	-- prediction rollback replays wall runs bit-identically.
	wallRunTimer: number, -- remaining wall-run budget; refilled on ground contact
	wallRunSide: number, -- -1 wall on the left, +1 on the right, 0 inactive
	wallNormal: Vector3, -- unit normal of the current wall

	-- Ladder movement (Source-style).
	onLadder: boolean,
	ladderNormal: Vector3,

	-- Crouch stance (Source-style duck). The Slide button doubles as crouch
	-- intent below slide speed. The collider shrinks from the TOP (feet stay
	-- planted) and standing up is blocked while a ceiling overlaps the full
	-- hull. Replicated via snapshot flag 0x10: the collider height depends on
	-- it, so rollback replay MUST restore the stance.
	crouching: boolean,

	-- bookkeeping for effects / debug (written by sim, read-only elsewhere)
	jumpedThisTick: boolean,
	landedThisTick: boolean,
	landingSpeed: number, -- vertical speed at the moment of landing (positive)
	collisionCount: number, -- planes clipped during the last slide-move
	wishDir: Vector3,
	wishSpeed: number,
	lastAcceleration: number,
}

-- Result of a collision trace. Pooled by Collision.luau; treat as read-only
-- and never retain beyond the current tick.
export type TraceResult = {
	fraction: number, -- 0..1 of the sweep completed
	hit: boolean,
	normal: Vector3,
	position: Vector3, -- safe end position of the swept box
	instance: Instance?,
	startSolid: boolean,
	-- Climbable surface flag. Filled by the collision layer (tag/attribute
	-- lookup) so the simulation stays engine-free while ladders remain
	-- level-authorable content.
	ladder: boolean,
}

-- The optional third argument selects the crouched hull (collider shrunk from
-- the top). The simulator binds it internally; solver modules keep calling
-- trace(origin, delta) and the bound flag rides along.
export type TraceFn = (origin: Vector3, delta: Vector3, crouched: boolean?) -> TraceResult

-- Camera effect contract. Effects contribute additive offsets which the
-- pipeline composes; no effect ever writes to the camera directly.
export type CameraContribution = {
	positionOffset: Vector3,
	rotationOffset: Vector3, -- pitch, yaw, roll in radians
	fovOffset: number,
}

export type CameraContext = {
	dt: number,
	state: MoveState,
	horizontalSpeed: number,
	lookVector: Vector3,
	strafeInput: number,
}

export type ICameraEffect = {
	Update: (self: ICameraEffect, ctx: CameraContext, out: CameraContribution) -> (),
	Reset: (self: ICameraEffect) -> (),
}

-- Networking transport abstraction; the simulation layer never touches
-- RemoteEvents. Implementations: RemoteTransport (live), NullTransport (tests/offline).
export type ITransport = {
	SendInput: (self: ITransport, packet: buffer) -> (),
	OnSnapshot: (self: ITransport, handler: (packet: buffer) -> ()) -> (),
	-- Down-only stream of every player's pose (remote-player interpolation).
	OnBroadcast: (self: ITransport, handler: (packet: buffer) -> ()) -> (),
	Destroy: (self: ITransport) -> (),
}

export type ServiceName = string

local Types = table.freeze({
	MoveStates = MoveStates,
	Buttons = Buttons,
})

return Types
