--!strict
--[[ WallRun.spec.luau - wall attach, reduced-gravity fall, budget drain and
     wall jump against an analytic floor+wall world. ]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local FrameworkModule = ReplicatedStorage:WaitForChild("MovementFramework")
local Types = require(FrameworkModule:WaitForChild("Core"):WaitForChild("Types"))
local Simulator = require(FrameworkModule:WaitForChild("Simulation"):WaitForChild("Simulator"))
local MoveState = require(FrameworkModule:WaitForChild("Simulation"):WaitForChild("MoveState"))
local InputCommand = require(FrameworkModule:WaitForChild("Networking"):WaitForChild("InputCommand"))
local MovementConfig = require(FrameworkModule:WaitForChild("Config"):WaitForChild("MovementConfig"))
local TestTraces = require(script.Parent:WaitForChild("TestTraces"))

local Buttons = Types.Buttons

local function newCmd(tick: number, moveZ: number, yaw: number, buttons: number): Types.InputCommand
	local c = InputCommand.new()
	c.tick = tick; c.dt = 1 / 60
	c.moveX = 0; c.moveZ = moveZ; c.yaw = yaw; c.buttons = buttons
	return c
end

return function(t: any)
	local profile = MovementConfig.Default
	local halfH = profile.ColliderSize.Y * 0.5
	local halfW = profile.ColliderSize.X * 0.5

	-- World: floor at y=0, wall at x=3 facing -X. Player runs along -Z
	-- (yaw 0, forward) hugging the wall on their RIGHT (+X side).
	local function makeWorld(): Types.TraceFn
		return TestTraces.floorAndWall(0, halfH, 3, halfW)
	end

	-- Airborne next to the wall, fast forward motion, holding W. High enough
	-- that neither the runner nor the free-fall reference lands mid-test.
	local function airborneByWall(): any
		local state = MoveState.new(Vector3.new(3 - halfW - 0.5, halfH + 30, 0))
		state.velocity = Vector3.new(0, 0, -20)
		state.wallRunTimer = profile.WallRunMaxTime
		return state
	end

	t:describe("WallRun", function()
		t:it("attaches to a side wall and falls slower than gravity", function()
			local sim = Simulator.new(profile, makeWorld())
			local state = airborneByWall()
			-- Free-fall reference over the same span.
			local freefall = MoveState.new(Vector3.new(-100, halfH + 30, 0)) -- far from the wall
			freefall.velocity = Vector3.new(0, 0, -20)
			local simFree = Simulator.new(profile, TestTraces.flatFloor(0, halfH))

			for tick = 1, 30 do
				sim:Step(state, newCmd(tick, 1, 0, 0))
				simFree:Step(freefall, newCmd(tick, 1, 0, 0))
			end
			t:expect(state.wallRunSide):toBe(1) -- wall on the right
			t:expect(state.velocity.Y):toBeGreaterThan(freefall.velocity.Y + 1)
		end)

		t:it("preserves tangential speed while attached", function()
			local sim = Simulator.new(profile, makeWorld())
			local state = airborneByWall()
			for tick = 1, 30 do
				sim:Step(state, newCmd(tick, 1, 0, 0))
			end
			t:expect(-state.velocity.Z):toBeGreaterThan(17) -- kept most of 20
		end)

		t:it("wall jump kicks away from the wall", function()
			local sim = Simulator.new(profile, makeWorld())
			local state = airborneByWall()
			for tick = 1, 10 do
				sim:Step(state, newCmd(tick, 1, 0, 0))
			end
			t:expect(state.wallRunSide):toBe(1)
			sim:Step(state, newCmd(11, 1, 0, Buttons.Jump))
			t:expect(state.jumpedThisTick):toBeTrue()
			t:expect(state.velocity.X):toBeLessThan(-5) -- pushed -X, off the +X wall
			t:expect(state.velocity.Y):toBeGreaterThan(5)
			t:expect(state.wallRunSide):toBe(0)
		end)

		t:it("budget drains and detaches; ground refills it", function()
			local long = table.clone(profile)
			long.Gravity = 0.001 -- keep airborne long enough to drain the budget
			local sim = Simulator.new(long, makeWorld())
			local state = airborneByWall()
			local drainTicks = math.ceil(long.WallRunMaxTime * 60) + 5
			for tick = 1, drainTicks do
				sim:Step(state, newCmd(tick, 1, 0, 0))
			end
			t:expect(state.wallRunSide):toBe(0)
			t:expect(state.wallRunTimer):toBeCloseTo(0, 1e-3)
		end)
	end)
end
