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

local CollectionService = game:GetService("CollectionService")

local Types = require(script.Parent.Parent.Core.Types)

export type DebugHook = (origin: Vector3, delta: Vector3, result: Types.TraceResult) -> ()

export type CollisionWorld = {
	Trace: Types.TraceFn,
	SetIgnoreCharacter: (self: CollisionWorld, character: Model?) -> (),
	-- Optional observer for every trace (debug visualization). nil in
	-- production: the hot path pays one nil-check per trace, nothing more.
	SetDebugHook: (self: CollisionWorld, hook: DebugHook?) -> (),
	Size: Vector3,
}

-- Level authors mark climbable surfaces with this CollectionService tag (an
-- attribute works too). Resolved here - not in the simulation - so solver
-- modules stay engine-free.
local LADDER_TAG = "MovementLadder"

local SKIN = 0.03

local Collision = {}
Collision.__index = Collision

type CollisionInternal = CollisionWorld & {
	_params: RaycastParams,
	_result: Types.TraceResult,
	_halfY: number,
	_crouchSize: Vector3, -- pre-computed crouched hull dimensions
	_crouchDrop: number, -- cast-centre drop so the hull shrinks from the TOP
	_debugHook: DebugHook?,
}

local function makeResult(): Types.TraceResult
	return {
		fraction = 1,
		hit = false,
		normal = Vector3.yAxis,
		position = Vector3.zero,
		instance = nil,
		startSolid = false,
		ladder = false,
	}
end

local function isLadder(inst: Instance): boolean
	return CollectionService:HasTag(inst, LADDER_TAG) or inst:GetAttribute(LADDER_TAG) == true
end

function Collision.SetIgnoreCharacter(self: CollisionInternal, character: Model?)
	if character then
		self._params.FilterDescendantsInstances = { character }
	else
		self._params.FilterDescendantsInstances = {}
	end
end

local function traceImpl(
	self: CollisionInternal,
	origin: Vector3,
	delta: Vector3,
	crouched: boolean?
): Types.TraceResult
	local result = self._result
	local dist = delta.Magnitude
	result.instance = nil
	result.startSolid = false
	result.ladder = false

	if dist < 1e-8 then
		result.fraction = 1
		result.hit = false
		result.normal = Vector3.yAxis
		result.position = origin
		return result
	end

	-- The crouched hull shrinks from the TOP: `origin` stays the centre of the
	-- STANDING box (feet level never changes), while the actual cast uses a
	-- shorter box whose centre sits _crouchDrop lower. Results stay expressed
	-- in origin space, so no other module knows the hull changed.
	local size = self.Size
	local castOrigin = origin
	if crouched then
		size = self._crouchSize
		castOrigin = origin - Vector3.new(0, self._crouchDrop, 0)
	end

	local dir = delta / dist
	local cast = workspace:Blockcast(CFrame.new(castOrigin), size, delta, self._params)
	if cast == nil then
		result.fraction = 1
		result.hit = false
		result.normal = Vector3.yAxis
		result.position = origin + delta
	else
		local hitDist = math.max(cast.Distance - SKIN, 0)
		result.fraction = hitDist / dist
		result.hit = true
		result.normal = cast.Normal
		result.position = origin + dir * hitDist
		result.instance = cast.Instance
		result.startSolid = cast.Distance <= 1e-4
		result.ladder = isLadder(cast.Instance)
	end

	local hook = self._debugHook
	if hook then
		hook(origin, delta, result)
	end
	return result
end

function Collision.SetDebugHook(self: CollisionInternal, hook: DebugHook?)
	self._debugHook = hook
end

local function new(size: Vector3, crouchScale: number?): CollisionWorld
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.IgnoreWater = true
	params.RespectCanCollide = true

	local scale = math.clamp(crouchScale or 0.55, 0.2, 1)
	local crouchY = size.Y * scale

	local self: CollisionInternal = setmetatable({
		Size = size,
		_params = params,
		_result = makeResult(),
		_halfY = size.Y * 0.5,
		_crouchSize = Vector3.new(size.X, crouchY, size.Z),
		_crouchDrop = (size.Y - crouchY) * 0.5,
	}, Collision) :: any

	self.Trace = function(origin: Vector3, delta: Vector3, crouched: boolean?): Types.TraceResult
		return traceImpl(self, origin, delta, crouched)
	end

	return self
end

return { new = new }
