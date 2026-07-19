--!strict
--[[
	Collision.luau
	Purpose: Swept-box collision queries against the Roblox world, exposed as a
	pure trace(origin, delta) -> TraceResult function for the solver.
	Architecture notes: The simulator depends only on Types.TraceFn, so tests
	substitute analytic plane worlds and never touch the engine.
	Performance: RaycastParams, the box CFrame identity rotation and both
	TraceResult tables are cached at construction. Zero allocation per trace beyond
	the engine's own RaycastResult.
	Notes: Uses workspace:Blockcast (swept AABB). SKIN keeps the box a hair off
	surfaces so subsequent traces never start solid.
]]

local Types = require(script.Parent.Parent.Core.Types)

export type CollisionWorld = {
	Trace: Types.TraceFn,
	SetIgnoreCharacter: (self: CollisionWorld, character: Model?) -> (),
	Size: Vector3,
}

local SKIN = 0.03

local Collision = {}
Collision.__index = Collision

type CollisionInternal = CollisionWorld & {
	_params: RaycastParams,
	_result: Types.TraceResult,
	_halfY: number,
}

local function makeResult(): Types.TraceResult
	return {
		fraction = 1,
		hit = false,
		normal = Vector3.yAxis,
		position = Vector3.zero,
		instance = nil,
		startSolid = false,
	}
end

function Collision.SetIgnoreCharacter(self: CollisionInternal, character: Model?)
	if character then
		self._params.FilterDescendantsInstances = { character }
	else
		self._params.FilterDescendantsInstances = {}
	end
end

local function traceImpl(self: CollisionInternal, origin: Vector3, delta: Vector3): Types.TraceResult
	local result = self._result
	local dist = delta.Magnitude
	result.instance = nil
	result.startSolid = false

	if dist < 1e-8 then
		result.fraction = 1
		result.hit = false
		result.normal = Vector3.yAxis
		result.position = origin
		return result
	end

	local dir = delta / dist
	local cast = workspace:Blockcast(CFrame.new(origin), self.Size, delta, self._params)
	if cast == nil then
		result.fraction = 1
		result.hit = false
		result.normal = Vector3.yAxis
		result.position = origin + delta
		return result
	end

	-- Pull back along the sweep so the box rests SKIN off the surface.
	local hitDist = math.max(cast.Distance - SKIN, 0)
	result.fraction = hitDist / dist
	result.hit = true
	result.normal = cast.Normal
	result.position = origin + dir * hitDist
	result.instance = cast.Instance
	result.startSolid = cast.Distance <= 1e-4
	return result
end

local function new(size: Vector3): CollisionWorld
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.IgnoreWater = true
	params.RespectCanCollide = true

	local self: CollisionInternal = setmetatable({
		Size = size,
		_params = params,
		_result = makeResult(),
		_halfY = size.Y * 0.5,
	}, Collision) :: any

	self.Trace = function(origin: Vector3, delta: Vector3): Types.TraceResult
		return traceImpl(self, origin, delta)
	end

	return self
end

return { new = new }
