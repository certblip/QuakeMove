--!strict
--[[ InputPacket.spec.luau - redundant-input framing: the
     [u8 count][u32 serverStampEcho][cmd*N] layout round-trips, offsets are
     stable, and simulating overlapping packet windows through a monotonic
     gate applies every tick exactly once even when a datagram is dropped. ]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local FrameworkModule = ReplicatedStorage:WaitForChild("MovementFramework")
local Types = require(FrameworkModule:WaitForChild("Core"):WaitForChild("Types"))
local InputCommand = require(FrameworkModule:WaitForChild("Networking"):WaitForChild("InputCommand"))

return function(t: any)
	t:describe("InputCommand packet framing", function()
		t:it("size + offsets are consistent", function()
			local header = InputCommand.PACKET_HEADER_BYTES
			t:expect(header):toBe(5) -- u8 count + u32 serverStampEcho (RTT for lag comp)
			t:expect(InputCommand.packetSize(1)):toBe(header + InputCommand.WIRE_BYTES)
			t:expect(InputCommand.packetSize(3)):toBe(header + 3 * InputCommand.WIRE_BYTES)
			t:expect(InputCommand.commandOffset(1)):toBe(header)
			t:expect(InputCommand.commandOffset(3)):toBe(header + 2 * InputCommand.WIRE_BYTES)
		end)

		t:it("round-trips N commands oldest->newest", function()
			local n = 3
			local buf = buffer.create(InputCommand.packetSize(n))
			buffer.writeu8(buf, 0, n)
			for i = 1, n do
				local c = InputCommand.new()
				c.tick = 100 + i
				c.buttons = i
				c.yaw = i * 0.1
				InputCommand.serialize(c, buf, InputCommand.commandOffset(i))
			end
			for i = 1, n do
				local out = InputCommand.new()
				InputCommand.deserialize(out, buf, InputCommand.commandOffset(i))
				t:expect(out.tick):toBe(100 + i)
				t:expect(out.buttons):toBe(i)
				t:expect(out.yaw):toBeCloseTo(i * 0.1, 1e-4)
			end
		end)
	end)

	t:describe("Redundant input heals a dropped packet", function()
		-- Minimal replica of the server's monotonic gate.
		local function makeGate()
			local applied: { number } = {}
			local newest = 0
			return function(tick: number)
				if tick <= newest then
					return -- duplicate / reorder: dropped for free
				end
				newest = tick
				table.insert(applied, tick)
			end, applied
		end

		-- Each "packet" carries the last 3 ticks (oldest->newest).
		local function windows(lastTick: number): { number }
			local w = {}
			for i = math.max(1, lastTick - 2), lastTick do
				table.insert(w, i)
			end
			return w
		end

		t:it("applies every tick once when all packets arrive", function()
			local gate, applied = makeGate()
			for tickN = 1, 6 do
				for _, tk in windows(tickN) do
					gate(tk)
				end
			end
			t:expect(#applied):toBe(6)
			for i = 1, 6 do
				t:expect(applied[i]):toBe(i)
			end
		end)

		t:it("recovers a tick whose original packet was lost", function()
			local gate, applied = makeGate()
			for tickN = 1, 6 do
				if tickN ~= 3 then -- packet for tick 3 is DROPPED
					for _, tk in windows(tickN) do
						gate(tk)
					end
				end
			end
			-- Packet 4 carries [2,3,4] and packet 5 carries [3,4,5]: tick 3 is
			-- re-delivered, so nothing is lost despite the drop.
			t:expect(#applied):toBe(6)
			for i = 1, 6 do
				t:expect(applied[i]):toBe(i)
			end
		end)

		t:it("loses a tick only when redundancy cannot cover the gap", function()
			-- Drop three consecutive packets (4,5,6): tick 4 is never re-sent
			-- because the window is only 3 wide - the honest failure mode.
			local gate, applied = makeGate()
			for tickN = 1, 8 do
				if tickN ~= 4 and tickN ~= 5 and tickN ~= 6 then
					for _, tk in windows(tickN) do
						gate(tk)
					end
				end
			end
			-- 7 carries [5,6,7], 8 carries [6,7,8]: 5,6,7,8 recovered; 4 lost.
			local has4 = false
			for _, tk in applied do
				if tk == 4 then
					has4 = true
				end
			end
			t:expect(has4):toBeFalse()
			local _ = Types
		end)
	end)
end
