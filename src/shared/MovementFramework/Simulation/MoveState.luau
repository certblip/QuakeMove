--!strict
--[[
	MoveState.luau
	Purpose: Construction, copying and (de)serialization of the simulation state.
	Performance: copyInto reuses the destination table - the prediction ring buffer
	holds pre-allocated snapshots and never allocates during gameplay.
	Wire format: 41 bytes per snapshot (u32 tick, 6xf32 pos/vel, u8 flags
	[0x80 grounded, 0x40 jumpHeldPrev, low 6 bits stateId], 3xf32 normal)
	written with the buffer library.
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
	dst.jumpedThisTick = src.jumpedThisTick
	dst.landedThisTick = src.landedThisTick
	dst.landingSpeed = src.landingSpeed
	dst.collisionCount = src.collisionCount
	dst.wishDir = src.wishDir
	dst.wishSpeed = src.wishSpeed
	dst.lastAcceleration = src.lastAcceleration
end

MoveState.SNAPSHOT_BYTES = 41

function MoveState.serialize(state: Types.MoveState, buf: buffer, offset: number)
	buffer.writeu32(buf, offset, state.tick)
	buffer.writef32(buf, offset + 4, state.position.X)
	buffer.writef32(buf, offset + 8, state.position.Y)
	buffer.writef32(buf, offset + 12, state.position.Z)
	buffer.writef32(buf, offset + 16, state.velocity.X)
	buffer.writef32(buf, offset + 20, state.velocity.Y)
	buffer.writef32(buf, offset + 24, state.velocity.Z)
	local flags = state.stateId -- stateId occupies the low 6 bits (values 1..9)
	if state.grounded then
		flags += 0x80
	end
	if state.jumpHeldPrev then
		flags += 0x40
	end
	buffer.writeu8(buf, offset + 28, flags)
	buffer.writef32(buf, offset + 29, state.groundNormal.X)
	buffer.writef32(buf, offset + 33, state.groundNormal.Y)
	buffer.writef32(buf, offset + 37, state.groundNormal.Z)
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
	state.stateId = bit32.band(flags, 0x3F)
	state.groundNormal = Vector3.new(
		buffer.readf32(buf, offset + 29),
		buffer.readf32(buf, offset + 33),
		buffer.readf32(buf, offset + 37)
	)
end

return table.freeze(MoveState)
