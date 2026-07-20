--!strict
--[[
	MoveState.luau
	Purpose: Construction, copying and (de)serialization of the simulation state.
	Performance: copyInto reuses the destination table - the prediction ring buffer
	holds pre-allocated snapshots and never allocates during gameplay.
	Wire format v2: 86 bytes per snapshot. Every field that AFFECTS the
	simulation travels on the wire - reconciliation adopts server state
	wholesale, and any omitted field would corrupt the rollback replay:
	  0  u32 tick
	  4  3xf32 position          16 3xf32 velocity
	  28 u8 flags [0x80 grounded, 0x40 jumpHeldPrev, 0x20 onLadder,
	              0x10 crouching, low 4 bits stateId]
	  29 3xf32 groundNormal
	  41 f32 coyote  45 f32 jumpBuffer  49 f32 landing  53 f32 slide
	  57 f32 wallRunTimer  61 i8 wallRunSide  62 3xf32 wallNormal
	  74 3xf32 ladderNormal
]]

local Types = require(script.Parent.Parent.Core.Types)

local MoveState = {}

function MoveState.new(position: Vector3): Types.MoveState
	return {
		tick = 0,
		position = position,
		velocity = Vector3.zero,
		grounded = false,
		groundNormal = Vector3.yAxis,
		surfaceAngle = 0,
		stateId = Types.MoveStates.Idle,
		prevStateId = Types.MoveStates.Idle,
		coyoteTimer = 0,
		jumpBufferTimer = 0,
		landingTimer = 0,
		slideTimer = 0,
		jumpHeldPrev = false,
		wallRunTimer = 0,
		wallRunSide = 0,
		wallNormal = Vector3.yAxis,
		onLadder = false,
		ladderNormal = Vector3.yAxis,
		crouching = false,
		jumpedThisTick = false,
		landedThisTick = false,
		landingSpeed = 0,
		collisionCount = 0,
		wishDir = Vector3.zero,
		wishSpeed = 0,
		lastAcceleration = 0,
	}
end

function MoveState.copyInto(dst: Types.MoveState, src: Types.MoveState)
	dst.tick = src.tick
	dst.position = src.position
	dst.velocity = src.velocity
	dst.grounded = src.grounded
	dst.groundNormal = src.groundNormal
	dst.surfaceAngle = src.surfaceAngle
	dst.stateId = src.stateId
	dst.prevStateId = src.prevStateId
	dst.coyoteTimer = src.coyoteTimer
	dst.jumpBufferTimer = src.jumpBufferTimer
	dst.landingTimer = src.landingTimer
	dst.slideTimer = src.slideTimer
	dst.jumpHeldPrev = src.jumpHeldPrev
	dst.wallRunTimer = src.wallRunTimer
	dst.wallRunSide = src.wallRunSide
	dst.wallNormal = src.wallNormal
	dst.onLadder = src.onLadder
	dst.ladderNormal = src.ladderNormal
	dst.crouching = src.crouching
	dst.jumpedThisTick = src.jumpedThisTick
	dst.landedThisTick = src.landedThisTick
	dst.landingSpeed = src.landingSpeed
	dst.collisionCount = src.collisionCount
	dst.wishDir = src.wishDir
	dst.wishSpeed = src.wishSpeed
	dst.lastAcceleration = src.lastAcceleration
end

MoveState.SNAPSHOT_BYTES = 86

function MoveState.serialize(state: Types.MoveState, buf: buffer, offset: number)
	buffer.writeu32(buf, offset, state.tick)
	buffer.writef32(buf, offset + 4, state.position.X)
	buffer.writef32(buf, offset + 8, state.position.Y)
	buffer.writef32(buf, offset + 12, state.position.Z)
	buffer.writef32(buf, offset + 16, state.velocity.X)
	buffer.writef32(buf, offset + 20, state.velocity.Y)
	buffer.writef32(buf, offset + 24, state.velocity.Z)
	local flags = state.stateId -- low 5 bits (ids are <= 31 by contract)
	if state.grounded then
		flags += 0x80
	end
	if state.jumpHeldPrev then
		flags += 0x40
	end
	if state.onLadder then
		flags += 0x20
	end
	if state.crouching then
		flags += 0x10
	end
	buffer.writeu8(buf, offset + 28, flags)
	buffer.writef32(buf, offset + 29, state.groundNormal.X)
	buffer.writef32(buf, offset + 33, state.groundNormal.Y)
	buffer.writef32(buf, offset + 37, state.groundNormal.Z)
	buffer.writef32(buf, offset + 41, state.coyoteTimer)
	buffer.writef32(buf, offset + 45, state.jumpBufferTimer)
	buffer.writef32(buf, offset + 49, state.landingTimer)
	buffer.writef32(buf, offset + 53, state.slideTimer)
	buffer.writef32(buf, offset + 57, state.wallRunTimer)
	buffer.writei8(buf, offset + 61, state.wallRunSide)
	buffer.writef32(buf, offset + 62, state.wallNormal.X)
	buffer.writef32(buf, offset + 66, state.wallNormal.Y)
	buffer.writef32(buf, offset + 70, state.wallNormal.Z)
	buffer.writef32(buf, offset + 74, state.ladderNormal.X)
	buffer.writef32(buf, offset + 78, state.ladderNormal.Y)
	buffer.writef32(buf, offset + 82, state.ladderNormal.Z)
end

function MoveState.deserialize(state: Types.MoveState, buf: buffer, offset: number)
	state.tick = buffer.readu32(buf, offset)
	state.position = Vector3.new(
		buffer.readf32(buf, offset + 4),
		buffer.readf32(buf, offset + 8),
		buffer.readf32(buf, offset + 12)
	)
	state.velocity = Vector3.new(
		buffer.readf32(buf, offset + 16),
		buffer.readf32(buf, offset + 20),
		buffer.readf32(buf, offset + 24)
	)
	local flags = buffer.readu8(buf, offset + 28)
	state.grounded = bit32.band(flags, 0x80) ~= 0
	state.jumpHeldPrev = bit32.band(flags, 0x40) ~= 0
	state.onLadder = bit32.band(flags, 0x20) ~= 0
	state.crouching = bit32.band(flags, 0x10) ~= 0
	state.stateId = bit32.band(flags, 0x0F)
	state.groundNormal = Vector3.new(
		buffer.readf32(buf, offset + 29),
		buffer.readf32(buf, offset + 33),
		buffer.readf32(buf, offset + 37)
	)
	state.coyoteTimer = buffer.readf32(buf, offset + 41)
	state.jumpBufferTimer = buffer.readf32(buf, offset + 45)
	state.landingTimer = buffer.readf32(buf, offset + 49)
	state.slideTimer = buffer.readf32(buf, offset + 53)
	state.wallRunTimer = buffer.readf32(buf, offset + 57)
	state.wallRunSide = buffer.readi8(buf, offset + 61)
	state.wallNormal = Vector3.new(
		buffer.readf32(buf, offset + 62),
		buffer.readf32(buf, offset + 66),
		buffer.readf32(buf, offset + 70)
	)
	state.ladderNormal = Vector3.new(
		buffer.readf32(buf, offset + 74),
		buffer.readf32(buf, offset + 78),
		buffer.readf32(buf, offset + 82)
	)
end

return table.freeze(MoveState)
