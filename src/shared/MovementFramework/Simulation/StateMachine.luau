--!strict
--[[
	StateMachine.luau
	Purpose: Deterministic movement state classification. The state is a pure
	function of MoveState + profile: same inputs => same state on every machine,
	which is mandatory for prediction (states replicate as a single byte).
	Architecture notes: States do not own behaviour - the simulator owns physics;
	the state machine exists for animation, camera and gameplay consumers. This
	keeps physics unconditionally continuous (no per-state duplicated math).
]]

local Types = require(script.Parent.Parent.Core.Types)
local VectorMath = require(script.Parent.Parent.Math.VectorMath)
local MovementConfig = require(script.Parent.Parent.Config.MovementConfig)

local MoveStates = Types.MoveStates

local StateMachine = {}

local STATE_NAMES: { [number]: string } = {
	[MoveStates.Idle] = "Idle",
	[MoveStates.Walking] = "Walking",
	[MoveStates.Running] = "Running",
	[MoveStates.Jumping] = "Jumping",
	[MoveStates.Falling] = "Falling",
	[MoveStates.Landing] = "Landing",
	[MoveStates.Sliding] = "Sliding",
	[MoveStates.Surfing] = "Surfing",
	[MoveStates.Ramp] = "Ramp",
	[MoveStates.WallRunning] = "WallRunning",
	[MoveStates.Ladder] = "Ladder",
}

function StateMachine.name(id: Types.MoveStateId): string
	return STATE_NAMES[id] or "Unknown"
end

-- Evaluate the state for the tick that just completed. Ordering of the guards is
-- the transition priority and must stay deterministic; do not reorder casually.
function StateMachine.evaluate(
	state: Types.MoveState,
	profile: MovementConfig.MovementProfile,
	surfing: boolean,
	sprinting: boolean
): Types.MoveStateId
	-- Attachment states outrank everything: they gate physics, not just visuals.
	if state.onLadder then
		return MoveStates.Ladder
	end

	if surfing then
		return MoveStates.Surfing
	end

	if not state.grounded then
		if state.wallRunSide ~= 0 then
			return MoveStates.WallRunning
		end
		if state.velocity.Y > 0.5 then
			return MoveStates.Jumping
		end
		return MoveStates.Falling
	end

	-- Grounded from here on.
	if state.slideTimer > 0 then
		return MoveStates.Sliding
	end
	if state.landingTimer > 0 then
		return MoveStates.Landing
	end
	if state.surfaceAngle > 12 and VectorMath.horizontalLength(state.velocity) > profile.GroundSpeed * 1.05 then
		return MoveStates.Ramp
	end

	local hSpeed = VectorMath.horizontalLength(state.velocity)
	if hSpeed < 0.5 then
		return MoveStates.Idle
	end
	if sprinting and hSpeed > profile.GroundSpeed * 1.05 then
		return MoveStates.Running
	end
	return MoveStates.Walking
end

return table.freeze(StateMachine)
