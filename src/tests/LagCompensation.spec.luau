--!strict
--[[ LagCompensation.spec.luau - server pose history + rewound ray-vs-AABB.
     Verifies exact per-tick lookups, the fair rewind clamp, that a shot hits
     where the target WAS (not is), shooter self-exclusion, and the crouched
     hitbox shrinking from the top. ]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local FrameworkModule = ReplicatedStorage:WaitForChild("MovementFramework")
local LagCompensation = require(FrameworkModule:WaitForChild("Networking"):WaitForChild("LagCompensation"))

local SIZE = Vector3.new(2.6, 5.0, 2.6)
local CROUCH_H = 3.0

local function it_hits_the_past(t: any)
	t:it("hits where the target WAS, misses where it now is", function()
		local lc = LagCompensation.new(32, 24, SIZE, CROUCH_H)
		-- Victim walks along +X: at tick 10 it was at x=10, by tick 30 at x=30.
		for tick = 1, 30 do
			lc:Record(99, tick, Vector3.new(tick, 0, 0), false)
		end
		-- A ray down the X axis at y=0 crossing x=10.
		local origin = Vector3.new(0, 0, 0)
		local dir = Vector3.new(1, 0, 0)
		-- Rewound to tick 10: hitbox centre x=10, half-width 1.3 => hit ~8.7.
		local id, point, dist = lc:RaycastAt(10, origin, dir, 100, nil)
		t:expect(id):toBe(99)
		t:expect((point :: Vector3).X):toBeCloseTo(8.7, 0.1)
		t:expect((dist :: number)):toBeCloseTo(8.7, 0.1)
		-- Same ray at tick 30 (x=30) still hits, but further away (~28.7).
		local _id2, _p2, dist2 = lc:RaycastAt(30, origin, dir, 100, nil)
		t:expect((dist2 :: number)):toBeCloseTo(28.7, 0.1)
	end)

	t:it("excludes the shooter", function()
		local lc = LagCompensation.new(32, 24, SIZE, CROUCH_H)
		lc:Record(5, 1, Vector3.new(10, 0, 0), false)
		local id = lc:RaycastAt(1, Vector3.zero, Vector3.new(1, 0, 0), 100, 5)
		t:expect(id):toBe(nil) -- only player is the shooter => no hit
	end)

	t:it("crouched hitbox shrinks from the top", function()
		local lc = LagCompensation.new(32, 24, SIZE, CROUCH_H)
		-- Standing top = centre + 2.5; crouched top = centre + (3.0-2.5)=+0.5.
		-- Fire a ray at y = centre + 1.5 (between the two tops), crossing x=10.
		lc:Record(1, 1, Vector3.new(10, 0, 0), true) -- crouched
		lc:Record(2, 2, Vector3.new(10, 0, 0), false) -- standing
		local ori = Vector3.new(0, 1.5, 0)
		local dir = Vector3.new(1, 0, 0)
		local crouchHit = lc:RaycastAt(1, ori, dir, 100, nil)
		t:expect(crouchHit):toBe(nil) -- 1.5 is above the crouched top (0.5)
		local standHit = lc:RaycastAt(2, ori, dir, 100, nil)
		t:expect(standHit):toBe(2) -- 1.5 is under the standing top (2.5)
	end)
end

return function(t: any)
	t:describe("LagCompensation history", function()
		t:it("returns the exact recorded position for a tick", function()
			local lc = LagCompensation.new(32, 24, SIZE, CROUCH_H)
			for tick = 1, 60 do
				lc:Record(7, tick, Vector3.new(tick, 0, 0), false)
			end
			local pos = lc:GetPositionAt(7, 55)
			t:expect(pos ~= nil):toBeTrue()
			t:expect((pos :: Vector3).X):toBe(55)
			-- Tick 20 is older than the 32-slot window from now(60): overwritten.
			t:expect(lc:GetPositionAt(7, 20)):toBe(nil)
		end)

		t:it("clamps a rewind target into the fair window", function()
			local lc = LagCompensation.new(32, 24, SIZE, CROUCH_H)
			for tick = 1, 100 do
				lc:Record(1, tick, Vector3.zero, false)
			end
			t:expect(lc:CurrentTick()):toBe(100)
			t:expect(lc:ClampTick(200)):toBe(100) -- future clamps to now
			t:expect(lc:ClampTick(50)):toBe(76) -- deeper than maxRewind(24) clamps
			t:expect(lc:ClampTick(90)):toBe(90) -- inside window is honoured
		end)
	end)

	t:describe("Rewound raycast", function()
		it_hits_the_past(t)
	end)
end
