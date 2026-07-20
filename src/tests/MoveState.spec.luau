--!strict
--[[ MoveState.spec.luau - wire format round-trip: every sim-affecting field
     must survive serialize -> deserialize, or reconciliation rollback replays
     corrupted state. ]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local FrameworkModule = ReplicatedStorage:WaitForChild("MovementFramework")
local Types = require(FrameworkModule:WaitForChild("Core"):WaitForChild("Types"))
local MoveState = require(FrameworkModule:WaitForChild("Simulation"):WaitForChild("MoveState"))

return function(t: any)
	t:describe("MoveState wire round-trip", function()
		t:it("preserves every replicated field", function()
			local src = MoveState.new(Vector3.new(12.5, -3.25, 900))
			src.tick = 123456
			src.velocity = Vector3.new(-40.5, 17, 3.125)
			src.grounded = true
			src.jumpHeldPrev = true
			src.onLadder = true
			src.stateId = Types.MoveStates.Ladder
			src.groundNormal = Vector3.new(0, 1, 0)
			src.coyoteTimer = 0.05
			src.jumpBufferTimer = 0.12
			src.landingTimer = 0.18
			src.slideTimer = 0.9
			src.wallRunTimer = 1.25
			src.wallRunSide = -1
			src.wallNormal = Vector3.new(1, 0, 0)
			src.ladderNormal = Vector3.new(0, 0, 1)

			local buf = buffer.create(MoveState.SNAPSHOT_BYTES)
			MoveState.serialize(src, buf, 0)
			local dst = MoveState.new(Vector3.zero)
			MoveState.deserialize(dst, buf, 0)

			t:expect(dst.tick):toBe(123456)
			t:expect((dst.position - src.position).Magnitude):toBeCloseTo(0, 1e-3)
			t:expect((dst.velocity - src.velocity).Magnitude):toBeCloseTo(0, 1e-3)
			t:expect(dst.grounded):toBeTrue()
			t:expect(dst.jumpHeldPrev):toBeTrue()
			t:expect(dst.onLadder):toBeTrue()
			t:expect(dst.stateId):toBe(Types.MoveStates.Ladder)
			t:expect(dst.coyoteTimer):toBeCloseTo(0.05, 1e-4)
			t:expect(dst.jumpBufferTimer):toBeCloseTo(0.12, 1e-4)
			t:expect(dst.landingTimer):toBeCloseTo(0.18, 1e-4)
			t:expect(dst.slideTimer):toBeCloseTo(0.9, 1e-4)
			t:expect(dst.wallRunTimer):toBeCloseTo(1.25, 1e-4)
			t:expect(dst.wallRunSide):toBe(-1)
			t:expect((dst.wallNormal - src.wallNormal).Magnitude):toBeCloseTo(0, 1e-4)
			t:expect((dst.ladderNormal - src.ladderNormal).Magnitude):toBeCloseTo(0, 1e-4)
		end)

		t:it("flag bits are independent", function()
			local src = MoveState.new(Vector3.zero)
			src.grounded = false
			src.jumpHeldPrev = true
			src.onLadder = false
			src.stateId = Types.MoveStates.WallRunning
			local buf = buffer.create(MoveState.SNAPSHOT_BYTES)
			MoveState.serialize(src, buf, 0)
			local dst = MoveState.new(Vector3.zero)
			MoveState.deserialize(dst, buf, 0)
			t:expect(dst.grounded):toBeFalse()
			t:expect(dst.jumpHeldPrev):toBeTrue()
			t:expect(dst.onLadder):toBeFalse()
			t:expect(dst.stateId):toBe(Types.MoveStates.WallRunning)
		end)
	end)
end
