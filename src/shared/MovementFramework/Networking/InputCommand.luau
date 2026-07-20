--!strict
--[[
	InputCommand.luau
	Purpose: Construction, pooling and binary (de)serialization of InputCommands.
	Wire format: 23 bytes - u32 tick, i8 moveX, i8 moveZ, f32 yaw, f32 pitch,
	u8 buttons, f32 dt (dt travels so the server can validate the client's
	timestep, plus 4 reserved bytes for future redundancy counts).
	Performance: Commands are pooled through the ring buffer's eviction return -
	steady-state gameplay recycles the same N tables forever.
]]

local Types = require(script.Parent.Parent.Core.Types)

local InputCommand = {}

InputCommand.WIRE_BYTES = 23

-- Redundant-input packet framing: [u8 count][u32 serverStampEcho]
-- [InputCommand * count], ordered oldest -> newest. Shipping the last N
-- commands every tick means a dropped datagram no longer drops a simulation
-- tick: the next packet re-delivers the missing command(s), and the server's
-- monotonic tick gate discards the duplicates for free.
-- serverStampEcho returns the newest server-time stamp received in a snapshot
-- tail, giving the SERVER an authoritative per-player RTT for lag-compensated
-- rewind (never trust a client-reported latency).
-- Both peers derive offsets from here so the layout can never drift.
InputCommand.PACKET_HEADER_BYTES = 5

-- Snapshot tail (transport metadata appended after MoveState.SNAPSHOT_BYTES):
-- [u32 clientStampEcho][u32 serverStampMs].
InputCommand.SNAPSHOT_TAIL_BYTES = 8

function InputCommand.packetSize(count: number): number
	return InputCommand.PACKET_HEADER_BYTES + count * InputCommand.WIRE_BYTES
end

function InputCommand.commandOffset(index: number): number
	return InputCommand.PACKET_HEADER_BYTES + (index - 1) * InputCommand.WIRE_BYTES
end

function InputCommand.new(): Types.InputCommand
	return {
		tick = 0,
		moveX = 0,
		moveZ = 0,
		yaw = 0,
		pitch = 0,
		buttons = 0,
		dt = 1 / 60,
	}
end

function InputCommand.copyInto(dst: Types.InputCommand, src: Types.InputCommand)
	dst.tick = src.tick
	dst.moveX = src.moveX
	dst.moveZ = src.moveZ
	dst.yaw = src.yaw
	dst.pitch = src.pitch
	dst.buttons = src.buttons
	dst.dt = src.dt
end

function InputCommand.serialize(cmd: Types.InputCommand, buf: buffer, offset: number)
	buffer.writeu32(buf, offset, cmd.tick)
	buffer.writei8(buf, offset + 4, math.round(math.clamp(cmd.moveX, -1, 1) * 127))
	buffer.writei8(buf, offset + 5, math.round(math.clamp(cmd.moveZ, -1, 1) * 127))
	buffer.writef32(buf, offset + 6, cmd.yaw)
	buffer.writef32(buf, offset + 10, cmd.pitch)
	buffer.writeu8(buf, offset + 14, cmd.buttons)
	buffer.writef32(buf, offset + 15, cmd.dt)
	buffer.writeu32(buf, offset + 19, 0) -- reserved
end

function InputCommand.deserialize(cmd: Types.InputCommand, buf: buffer, offset: number)
	cmd.tick = buffer.readu32(buf, offset)
	cmd.moveX = buffer.readi8(buf, offset + 4) / 127
	cmd.moveZ = buffer.readi8(buf, offset + 5) / 127
	cmd.yaw = buffer.readf32(buf, offset + 6)
	cmd.pitch = buffer.readf32(buf, offset + 10)
	cmd.buttons = buffer.readu8(buf, offset + 14)
	cmd.dt = buffer.readf32(buf, offset + 15)
end

return table.freeze(InputCommand)
