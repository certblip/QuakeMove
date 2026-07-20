--!strict
--[[ Crouch.spec.luau - Source-style duck. In this model the collision hull
     shrinks from the TOP, so state.position stays the standing-box centre and
     never moves on a stance change. Verified: crouched speed scaling, the
     ceiling lock on stand-up, slide->crouch flow, and wire replication. ]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local FrameworkModule = ReplicatedStorage:WaitForChild("MovementFramework")
local Types = require(FrameworkModule:WaitForChild("Core"):WaitForChild("Types"))
local Simulator = require(FrameworkModule:WaitForChild("Simulation"):WaitForChild("Simulator"))
local MoveState = require(FrameworkModule:WaitForChild("Simulation"):WaitForChild("MoveState"))
local InputCommand = require(FrameworkModule:WaitForChild("Networking"):WaitForChild("InputCommand"))
local MovementConfig = require(FrameworkModule:WaitForChild("Config"):WaitForChild("MovementConfig"))
local TestTraces = require(script.Parent:WaitForChild("TestTraces"))

local Buttons = Types.Buttons

local function newCmd(tick: number, moveZ: number, buttons: number): Types.InputCommand
	local c = InputCommand.new()
	c.tick = tick; c.dt = 1 / 60
	c.moveX = 0; c.moveZ = moveZ; c.yaw = 0; c.buttons = buttons
	return c
end

return function(t: any)
	local p = MovementConfig.Default
	local halfStand = p.ColliderSize.Y * 0.5 -- 2.5
	-- Ceiling between the crouched top (origin+0.5) and standing top (origin+2.5)
	-- so the crouched hull fits but the standing hull never does; corridor x>=10.
	local CEIL_Y = halfStand + 1.5 -- 4.0
	local function world(): Types.TraceFn
		return TestTraces.lowCorridor(0, halfStand, p.CrouchColliderHeight, CEIL_Y, 10)
	end

	t:describe("Crouch stance", function()
		t:it("ducks from a standstill without triggering a slide", function()
			local sim = Simulator.new(p, world())
			local state = MoveState.new(Vector3.new(0, halfStand, 0))
			state.grounded = true
			sim:Step(state, newCmd(1, 0, Buttons.Slide))
			t:expect(state.crouching):toBeTrue()
			t:expect(state.slideTimer):toBeCloseTo(0, 1e-4)
			-- Position is the standing centre and does not move on ducking.
			t:expect(state.position.Y):toBeCloseTo(halfStand, 0.05)
			t:expect(state.stateId):toBe(Types.MoveStates.Crouching)
		end)

		t:it("crouched ground speed obeys the multiplier", function()
			local sim = Simulator.new(p, world())
			local state = MoveState.new(Vector3.new(0, halfStand, 0))
			state.grounded = true
			for tick = 1, 150 do
				sim:Step(state, newCmd(tick, 1, Buttons.Slide))
			end
			local hSpeed = Vector3.new(state.velocity.X, 0, state.velocity.Z).Magnitude
			local cap = p.GroundSpeed * p.CrouchSpeedMultiplier
			t:expect(hSpeed):toBeLessThan(cap + 1)
			t:expect(hSpeed):toBeGreaterThan(cap * 0.5)
		end)

		t:it("cannot stand up under a low ceiling; stands when clear", function()
			local sim = Simulator.new(p, world())
			local state = MoveState.new(Vector3.new(0, halfStand, 0))
			state.grounded = true
			sim:Step(state, newCmd(1, 0, Buttons.Slide)) -- duck in the open
			t:expect(state.crouching):toBeTrue()
			-- Crawl into the corridor and release: headroom probe hits -> stays.
			state.position = Vector3.new(20, halfStand, 0)
			sim:Step(state, newCmd(2, 0, 0))
			t:expect(state.crouching):toBeTrue()
			-- Back out in the open: release now stands up.
			state.position = Vector3.new(0, halfStand, 0)
			sim:Step(state, newCmd(3, 0, 0))
			t:expect(state.crouching):toBeFalse()
		end)

		t:it("slide takes priority; crouch flows in when the slide ends", function()
			local sim = Simulator.new(p, world())
			local state = MoveState.new(Vector3.new(0, halfStand, 0))
			state.grounded = true
			local tick = 0
			for _ = 1, 90 do
				tick += 1
				sim:Step(state, newCmd(tick, 1, Buttons.Sprint))
			end
			tick += 1
			sim:Step(state, newCmd(tick, 1, Buttons.Slide))
			t:expect(state.slideTimer):toBeGreaterThan(0)
			t:expect(state.crouching):toBeFalse() -- sliding, not ducked yet
			for _ = 1, math.ceil(p.SlideMaxTime * 60) + 10 do
				tick += 1
				sim:Step(state, newCmd(tick, 0, Buttons.Slide))
			end
			t:expect(state.slideTimer):toBeCloseTo(0, 1e-4)
			t:expect(state.crouching):toBeTrue()
		end)

		t:it("crouch flag survives the wire round-trip", function()
			local state = MoveState.new(Vector3.new(0, halfStand, 0))
			state.crouching = true
			state.stateId = Types.MoveStates.Crouching
			local buf = buffer.create(MoveState.SNAPSHOT_BYTES)
			MoveState.serialize(state, buf, 0)
			local out = MoveState.new(Vector3.zero)
			MoveState.deserialize(out, buf, 0)
			t:expect(out.crouching):toBeTrue()
			t:expect(out.stateId):toBe(Types.MoveStates.Crouching)
		end)
	end)
end
