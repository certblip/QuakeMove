--!strict
--[[ Replay.spec.luau - the determinism contract: a recorded command stream
     replayed through the simulator reproduces the exact final state, including
     across serialize/deserialize. ]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local FrameworkModule = ReplicatedStorage:WaitForChild("MovementFramework")
local Types = require(FrameworkModule:WaitForChild("Core"):WaitForChild("Types"))
local Simulator = require(FrameworkModule:WaitForChild("Simulation"):WaitForChild("Simulator"))
local MoveState = require(FrameworkModule:WaitForChild("Simulation"):WaitForChild("MoveState"))
local InputCommand = require(FrameworkModule:WaitForChild("Networking"):WaitForChild("InputCommand"))
local Replay = require(FrameworkModule:WaitForChild("Networking"):WaitForChild("Replay"))
local MovementConfig = require(FrameworkModule:WaitForChild("Config"):WaitForChild("MovementConfig"))
local TestTraces = require(script.Parent:WaitForChild("TestTraces"))

local Buttons = Types.Buttons

return function(t: any)
	local profile = MovementConfig.Default
	local halfH = profile.ColliderSize.Y * 0.5

	-- Runs a scripted 300-tick session while recording; returns recorder + live end position.
	local function recordSession(): (any, Vector3)
		local sim = Simulator.new(profile, TestTraces.flatFloor(0, halfH))
		local state = MoveState.new(Vector3.new(0, halfH, 0))
		state.grounded = true
		local rec = Replay.newRecorder(600)
		rec:Begin(state)
		local cmd = InputCommand.new()
		local yaw = 0
		for tick = 1, 300 do
			yaw += 0.013
			cmd.tick = tick
			cmd.dt = 1 / 60
			cmd.moveX = if tick % 3 == 0 then 1 else 0
			cmd.moveZ = 1
			cmd.yaw = yaw
			cmd.buttons = if tick > 60 then Buttons.Jump else 0
			sim:Step(state, cmd)
			rec:Record(cmd)
		end
		return rec, state.position
	end

	t:describe("Replay determinism", function()
		t:it("playback reproduces the exact final position", function()
			local rec, livePos = recordSession()
			local replay = rec:Finish()
			t:expect(replay ~= nil):toBeTrue()
			local sim = Simulator.new(profile, TestTraces.flatFloor(0, halfH))
			local out = MoveState.new(Vector3.zero)
			Replay.play(replay :: any, sim, out)
			t:expect((out.position - livePos).Magnitude):toBeCloseTo(0, 1e-6)
		end)

		t:it("survives serialize -> deserialize byte round-trip", function()
			local rec, livePos = recordSession()
			local replay = rec:Finish() :: any
			local buf = Replay.serialize(replay)
			local restored = Replay.deserialize(buf)
			t:expect(restored.count):toBe(replay.count)
			local sim = Simulator.new(profile, TestTraces.flatFloor(0, halfH))
			local out = MoveState.new(Vector3.zero)
			Replay.play(restored, sim, out)
			-- f32 command quantization: the recorded commands were already
			-- float-precision, so the tolerance stays tight.
			t:expect((out.position - livePos).Magnitude):toBeLessThan(0.05)
		end)

		t:it("player advances tick by tick and stops at the end", function()
			local rec = recordSession()
			local replay = rec:Finish() :: any
			local sim = Simulator.new(profile, TestTraces.flatFloor(0, halfH))
			local state = MoveState.new(Vector3.zero)
			local player = Replay.newPlayer()
			player:Begin(replay, state)
			local ticks = 0
			while player:Advance(sim, state) do
				ticks += 1
			end
			t:expect(ticks):toBe(replay.count)
			t:expect(player:IsPlaying()):toBeFalse()
		end)
	end)
end
