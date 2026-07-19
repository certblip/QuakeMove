--!strict
--[[ Simulator.spec.luau - integration tests over the deterministic kernel with an
     analytic flat-ground + ramp trace. Verifies gravity, jumping, momentum
     preservation across a bhop, air-strafe speed gain, and determinism. ]]

local Types = require(script.Parent.Parent.shared.MovementFramework.Core.Types)
local Simulator = require(script.Parent.Parent.shared.MovementFramework.Simulation.Simulator)
local MoveState = require(script.Parent.Parent.shared.MovementFramework.Simulation.MoveState)
local InputCommand = require(script.Parent.Parent.shared.MovementFramework.Networking.InputCommand)
local MovementConfig = require(script.Parent.Parent.shared.MovementFramework.Config.MovementConfig)

local Buttons = Types.Buttons
local FLOOR_Y = 0

-- Analytic trace: an infinite flat floor at y=FLOOR_Y. The swept box (height 5)
-- rests when its centre reaches FLOOR_Y + halfHeight.
local function makeFlatTrace(halfHeight: number): Types.TraceFn
	return function(origin: Vector3, delta: Vector3): Types.TraceResult
		local endPos = origin + delta
		local floorCentre = FLOOR_Y + halfHeight
		if delta.Y < 0 and endPos.Y <= floorCentre and origin.Y >= floorCentre - 1e-3 then
			local travel = origin.Y - floorCentre
			local frac = if delta.Y ~= 0 then math.clamp(travel / -delta.Y, 0, 1) else 0
			return {
				fraction = frac,
				hit = true,
				normal = Vector3.yAxis,
				position = Vector3.new(endPos.X, floorCentre, endPos.Z),
				instance = nil,
				startSolid = false,
			}
		end
		return {
			fraction = 1, hit = false, normal = Vector3.yAxis,
			position = endPos, instance = nil, startSolid = false,
		}
	end
end

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
			local sim = Simulator.new(profile, makeFlatTrace(halfH))
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
			local sim = Simulator.new(profile, makeFlatTrace(halfH))
			local state = MoveState.new(Vector3.new(0, halfH, 0))
			state.grounded = true
			sim:Step(state, newCmd(1, 0, 0, 0, Buttons.Jump)) -- buffered by autojump default
			t:expect(state.velocity.Y):toBeGreaterThan(10)
			t:expect(state.grounded):toBeFalse()
		end)
	end)

	t:describe("Bunny hop momentum", function()
		t:it("preserves horizontal speed across an autojump landing", function()
			local sim = Simulator.new(profile, makeFlatTrace(halfH))
			local state = MoveState.new(Vector3.new(0, halfH, 0))
			state.grounded = true
			-- Build ground speed running forward.
			for tick = 1, 60 do
				sim:Step(state, newCmd(tick, 0, 1, 0, 0))
			end
			local groundSpeed = Vector3.new(state.velocity.X, 0, state.velocity.Z).Magnitude
			t:expect(groundSpeed):toBeGreaterThan(15)
			-- Now hold jump (autojump) + forward for a while: speed must not collapse.
			for tick = 61, 180 do
				sim:Step(state, newCmd(tick, 0, 1, 0, Buttons.Jump))
			end
			local hopSpeed = Vector3.new(state.velocity.X, 0, state.velocity.Z).Magnitude
			t:expect(hopSpeed):toBeGreaterThan(14)
		end)
	end)

	t:describe("Air strafing", function()
		t:it("gains speed beyond ground cap by turning while strafing in air", function()
			local sim = Simulator.new(profile, makeFlatTrace(halfH))
			local state = MoveState.new(Vector3.new(0, halfH + 5000, 0)) -- high up: never lands during the test
			state.velocity = Vector3.new(0, 0, -profile.GroundSpeed) -- moving forward at cap
			local yaw = 0
			-- Optimal air strafe: turn the view at the rate that keeps wishdir just
			-- ahead of velocity, holding one strafe key. Speed should climb past the
			-- ground cap purely from the capped air-accel projection.
			local startSpeed = Vector3.new(state.velocity.X, 0, state.velocity.Z).Magnitude
			for tick = 1, 240 do
				yaw += 0.02
				sim:Step(state, newCmd(tick, 1, 0, yaw, 0))
			end
			local speed = Vector3.new(state.velocity.X, 0, state.velocity.Z).Magnitude
			-- Must have gained speed above where it started (airstrafe acceleration).
			t:expect(speed):toBeGreaterThan(startSpeed + 1.5)
		end)
	end)

	t:describe("Determinism", function()
		t:it("identical command streams produce identical final state", function()
			local function run(): Vector3
				local sim = Simulator.new(profile, makeFlatTrace(halfH))
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
