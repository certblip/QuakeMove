--!strict
--[[ Simulator.spec.luau - integration tests over the deterministic kernel with
     analytic traces. Verifies gravity, jumping, momentum preservation across a
     bhop, air-strafe speed gain, non-autojump edge buffering, the slide-boost
     cap and determinism. ]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local FrameworkModule = ReplicatedStorage:WaitForChild("MovementFramework")
local Types = require(FrameworkModule:WaitForChild("Core"):WaitForChild("Types"))
local Simulator = require(FrameworkModule:WaitForChild("Simulation"):WaitForChild("Simulator"))
local MoveState = require(FrameworkModule:WaitForChild("Simulation"):WaitForChild("MoveState"))
local InputCommand = require(FrameworkModule:WaitForChild("Networking"):WaitForChild("InputCommand"))
local MovementConfig = require(FrameworkModule:WaitForChild("Config"):WaitForChild("MovementConfig"))
local TestTraces = require(script.Parent:WaitForChild("TestTraces"))

local Buttons = Types.Buttons

local function newCmd(tick: number, moveX: number, moveZ: number, yaw: number, buttons: number): Types.InputCommand
	local c = InputCommand.new()
	c.tick = tick; c.dt = 1 / 60
	c.moveX = moveX; c.moveZ = moveZ; c.yaw = yaw; c.buttons = buttons
	return c
end

return function(t: any)
	local profile = MovementConfig.Default
	local halfH = profile.ColliderSize.Y * 0.5

	t:describe("Simulator gravity & ground", function()
		t:it("falls under gravity when airborne then lands grounded", function()
			local sim = Simulator.new(profile, TestTraces.flatFloor(0, halfH))
			local state = MoveState.new(Vector3.new(0, halfH + 20, 0))
			for tick = 1, 240 do
				sim:Step(state, newCmd(tick, 0, 0, 0, 0))
			end
			t:expect(state.grounded):toBeTrue()
			t:expect(state.position.Y):toBeCloseTo(halfH, 0.2)
		end)
	end)

	t:describe("Simulator jump", function()
		t:it("applies upward velocity and leaves the ground", function()
			local sim = Simulator.new(profile, TestTraces.flatFloor(0, halfH))
			local state = MoveState.new(Vector3.new(0, halfH, 0))
			state.grounded = true
			sim:Step(state, newCmd(1, 0, 0, 0, Buttons.Jump))
			t:expect(state.velocity.Y):toBeGreaterThan(10)
			t:expect(state.grounded):toBeFalse()
		end)

		t:it("non-autojump: rising edge buffers exactly one jump", function()
			local noAuto = table.clone(profile)
			noAuto.AutoJump = false
			local sim = Simulator.new(noAuto, TestTraces.flatFloor(0, halfH))
			local state = MoveState.new(Vector3.new(0, halfH, 0))
			state.grounded = true
			-- Press and hold: first tick jumps...
			sim:Step(state, newCmd(1, 0, 0, 0, Buttons.Jump))
			t:expect(state.jumpedThisTick):toBeTrue()
			-- ...then land again while STILL holding: no re-jump without re-press.
			for tick = 2, 120 do
				sim:Step(state, newCmd(tick, 0, 0, 0, Buttons.Jump))
			end
			t:expect(state.grounded):toBeTrue()
			-- Release, press again: jumps again.
			sim:Step(state, newCmd(121, 0, 0, 0, 0))
			sim:Step(state, newCmd(122, 0, 0, 0, Buttons.Jump))
			t:expect(state.jumpedThisTick):toBeTrue()
		end)
	end)

	t:describe("Bunny hop momentum", function()
		t:it("preserves horizontal speed across an autojump landing", function()
			local sim = Simulator.new(profile, TestTraces.flatFloor(0, halfH))
			local state = MoveState.new(Vector3.new(0, halfH, 0))
			state.grounded = true
			for tick = 1, 60 do
				sim:Step(state, newCmd(tick, 0, 1, 0, 0))
			end
			local groundSpeed = Vector3.new(state.velocity.X, 0, state.velocity.Z).Magnitude
			t:expect(groundSpeed):toBeGreaterThan(15)
			for tick = 61, 180 do
				sim:Step(state, newCmd(tick, 0, 1, 0, Buttons.Jump))
			end
			local hopSpeed = Vector3.new(state.velocity.X, 0, state.velocity.Z).Magnitude
			t:expect(hopSpeed):toBeGreaterThan(14)
		end)
	end)

	t:describe("Air strafing", function()
		t:it("gains speed beyond ground cap by turning while strafing in air", function()
			local sim = Simulator.new(profile, TestTraces.flatFloor(0, halfH))
			local state = MoveState.new(Vector3.new(0, halfH + 5000, 0))
			state.velocity = Vector3.new(0, 0, -profile.GroundSpeed)
			local yaw = 0
			local startSpeed = Vector3.new(state.velocity.X, 0, state.velocity.Z).Magnitude
			for tick = 1, 240 do
				yaw += 0.02
				sim:Step(state, newCmd(tick, 1, 0, yaw, 0))
			end
			local speed = Vector3.new(state.velocity.X, 0, state.velocity.Z).Magnitude
			t:expect(speed):toBeGreaterThan(startSpeed + 1.5)
		end)
	end)

	t:describe("Slide boost cap", function()
		t:it("re-pressing slide cannot compound speed past the cap", function()
			local sim = Simulator.new(profile, TestTraces.flatFloor(0, halfH))
			local state = MoveState.new(Vector3.new(0, halfH, 0))
			state.grounded = true
			-- Build sprint speed.
			for tick = 1, 90 do
				sim:Step(state, newCmd(tick, 0, 1, 0, Buttons.Sprint))
			end
			-- Pump the slide button on alternating ticks for 4 seconds.
			local cap = profile.GroundSpeed * profile.SprintMultiplier * profile.SlideMultiplier
			local tick = 90
			for _ = 1, 120 do
				tick += 1
				sim:Step(state, newCmd(tick, 0, 1, 0, Buttons.Slide))
				tick += 1
				sim:Step(state, newCmd(tick, 0, 1, 0, 0))
			end
			local hSpeed = Vector3.new(state.velocity.X, 0, state.velocity.Z).Magnitude
			t:expect(hSpeed):toBeLessThan(cap + 1)
		end)
	end)

	t:describe("Determinism", function()
		t:it("identical command streams produce identical final state", function()
			local function run(): Vector3
				local sim = Simulator.new(profile, TestTraces.flatFloor(0, halfH))
				local state = MoveState.new(Vector3.new(0, halfH, 0))
				state.grounded = true
				local yaw = 0
				for tick = 1, 300 do
					yaw += 0.017
					sim:Step(state, newCmd(tick, 1, 1, yaw, Buttons.Jump))
				end
				return state.position
			end
			local a = run()
			local b = run()
			t:expect((a - b).Magnitude):toBeCloseTo(0, 1e-6)
		end)
	end)
end
