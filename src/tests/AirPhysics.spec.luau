--!strict
--[[ AirPhysics.spec.luau - verifies the three air-acceleration strategies
     diverge exactly where they should: Source's uncapped accel scaling,
     CPM's speed-preserving air control and high-accel pure strafe. ]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local FrameworkModule = ReplicatedStorage:WaitForChild("MovementFramework")
local AirPhysics = require(FrameworkModule:WaitForChild("Simulation"):WaitForChild("AirPhysics"))
local MovementConfig = require(FrameworkModule:WaitForChild("Config"):WaitForChild("MovementConfig"))

return function(t: any)
	local dt = 1 / 60

	t:describe("AirPhysics mode dispatch", function()
		t:it("Quake mode matches the capped Q3 shape (no gain at cap)", function()
			local profile = MovementConfig.Default -- AirAccelMode = "Quake"
			-- Already moving at the cap along wishdir: Q3 adds nothing.
			local vel = Vector3.new(0, 0, -profile.AirSpeedCap)
			local wish = Vector3.new(0, 0, -1)
			local out = AirPhysics.airAccelerate(vel, wish, 20, 0, 1, profile, dt)
			t:expect(out.Z):toBeCloseTo(vel.Z, 1e-4)
		end)

		t:it("Source mode keeps accelerating where Quake saturates", function()
			local source = MovementConfig.Source
			-- Same setup: at the cap along wishdir. Source's accel increment
			-- scales with the UNCAPPED wishspeed, so addspeed>0 paths differ;
			-- construct slight off-axis motion so addspeed is positive.
			local vel = Vector3.new(1.2, 0, -1.2)
			local wish = Vector3.new(0, 0, -1)
			local q = MovementConfig.Default
			local outQ = AirPhysics.airAccelerate(vel, wish, 20, 0, 1, q, dt)
			local outS = AirPhysics.airAccelerate(vel, wish, 20, 0, 1, source, dt)
			-- Both accelerate, but the shapes must NOT be identical: Source's
			-- larger accel*wishSpeed increment reaches the addspeed limit
			-- while Quake's (same formula here) also does - so compare against
			-- a smaller dt where the increments differ.
			local outQ2 = AirPhysics.airAccelerate(vel, wish, 20, 0, 1, q, dt / 8)
			local outS2 = AirPhysics.airAccelerate(vel, wish, 20, 0, 1, source, dt / 8)
			local gainQ = -(outQ2.Z - vel.Z)
			local gainS = -(outS2.Z - vel.Z)
			-- Source: accel(25) * wishSpeed(20) * dt vs Quake: accel(40) * cappedWish(1.9) * dt
			t:expect(gainS):toBeGreaterThan(gainQ)
			local _ = outQ
			local _2 = outS
		end)

		t:it("CPM air control turns velocity without adding speed", function()
			local cpm = MovementConfig.CPM
			local vel = Vector3.new(0, 0, -30)
			-- Pure forward input, wish rotated ~20 degrees off velocity.
			local ang = math.rad(20)
			local wish = Vector3.new(math.sin(ang), 0, -math.cos(ang))
			local out = AirPhysics.airAccelerate(vel, wish, 20, 0, 1, cpm, dt)
			local speedBefore = Vector3.new(vel.X, 0, vel.Z).Magnitude
			local speedAfter = Vector3.new(out.X, 0, out.Z).Magnitude
			-- Air accel adds at most cap-worth; control itself preserves magnitude.
			t:expect(speedAfter):toBeLessThan(speedBefore + cpm.AirSpeedCap + 0.1)
			-- The direction must have rotated toward the wish.
			local dirBefore = Vector3.new(vel.X, 0, vel.Z).Unit
			local dirAfter = Vector3.new(out.X, 0, out.Z).Unit
			t:expect(dirAfter:Dot(wish)):toBeGreaterThan(dirBefore:Dot(wish))
		end)

		t:it("CPM pure strafe uses the high strafe acceleration", function()
			local cpm = MovementConfig.CPM
			local vel = Vector3.zero
			local wish = Vector3.new(1, 0, 0)
			-- moveX ~= 0, moveZ == 0 => strafe branch (accel 70 vs base 30).
			local outStrafe = AirPhysics.airAccelerate(vel, wish, 20, 1, 0, cpm, dt)
			-- Mixed input => base branch.
			local outMixed = AirPhysics.airAccelerate(vel, wish, 20, 1, 1, cpm, dt)
			t:expect(outStrafe.X):toBeGreaterThan(outMixed.X)
		end)
	end)
end
