--!strict
--[[
	LagCompensation.luau
	Purpose: Server-side rewind ("backtracking") for fair hit registration.
	A shooter aims at where targets were RENDERED on their screen - interp
	delay (~100 ms) plus half their RTT in the past. Validating hits against
	the server's CURRENT poses would punish every player for their own ping;
	rewinding targets to the shooter's perceived tick makes hits land where
	they were aimed.
	Architecture notes: Engine-free. One ring of parallel arrays per entity
	(contiguous server ticks => O(1) index math, no search). The hitbox is an
	axis-aligned box anchored at the FEET: the bottom face never moves when
	crouching - the top comes down (matches the simulation's collider).
	RaycastAt is a slab-test ray-vs-AABB over every rewound entity.
	Capacity guidance: 64 ticks ~= 1 s of history @ 60 Hz - covers 100 ms
	interp + 400 ms RTT with margin. MaxRewindTicks caps how far a laggy
	shooter may drag everyone into the past ("shot around the corner" bound);
	Source engines cap the same way.
]]

type EntityHistory = {
	positions: { Vector3 },
	crouches: { boolean },
	head: number, -- next write slot (1-based ring index)
	count: number,
	newestTick: number,
}

export type LagCompensation = {
	Record: (self: LagCompensation, id: number, tick: number, position: Vector3, crouching: boolean) -> (),
	Remove: (self: LagCompensation, id: number) -> (),
	CurrentTick: (self: LagCompensation) -> number,
	ClampTick: (self: LagCompensation, tick: number) -> number,
	GetPositionAt: (self: LagCompensation, id: number, tick: number) -> (Vector3?, boolean),
	RaycastAt: (
		self: LagCompensation,
		tick: number,
		origin: Vector3,
		direction: Vector3,
		maxDistance: number,
		excludeId: number?
	) -> (number?, Vector3?, number?),
}

type Internal = LagCompensation & {
	_entities: { [number]: EntityHistory },
	_capacity: number,
	_maxRewindTicks: number,
	_halfX: number, -- hull half-extents
	_halfY: number,
	_halfZ: number,
	_crouchHeight: number, -- full hull height while crouched
	_newestTick: number, -- newest tick recorded across ALL entities ("now")
}

local LagCompensation = {}
LagCompensation.__index = LagCompensation

local function newEntity(capacity: number): EntityHistory
	return {
		positions = table.create(capacity, Vector3.zero),
		crouches = table.create(capacity, false),
		head = 1,
		count = 0,
		newestTick = 0,
	}
end

-- Records one pose for `tick`. Ticks MUST be recorded in increasing order
-- (the server samples once per scheduler tick); a gap restarts the ring
-- rather than lying about the missing span - index math relies on contiguity.
function LagCompensation.Record(self: Internal, id: number, tick: number, position: Vector3, crouching: boolean)
	local entity = self._entities[id]
	if entity == nil then
		entity = newEntity(self._capacity)
		self._entities[id] = entity
	end
	if entity.count > 0 and tick ~= entity.newestTick + 1 then
		entity.head = 1
		entity.count = 0
	end
	local head = entity.head
	entity.positions[head] = position
	entity.crouches[head] = crouching
	entity.head = if head >= self._capacity then 1 else head + 1
	entity.count = math.min(entity.count + 1, self._capacity)
	entity.newestTick = tick
	if tick > self._newestTick then
		self._newestTick = tick
	end
end

-- Drops an entity's whole timeline. Call on despawn/death AND on respawn:
-- poses from a previous life must never validate a hit.
function LagCompensation.Remove(self: Internal, id: number)
	self._entities[id] = nil
end

function LagCompensation.CurrentTick(self: Internal): number
	return self._newestTick
end

-- Clamps a requested rewind tick into the fair window:
-- no further back than MaxRewindTicks, never into the future.
function LagCompensation.ClampTick(self: Internal, tick: number): number
	local newest = self._newestTick
	return math.clamp(tick, newest - self._maxRewindTicks, newest)
end

-- Ring index for an exact recorded tick, or nil when outside the window.
local function indexFor(entity: EntityHistory, capacity: number, tick: number): number?
	local offset = entity.newestTick - tick -- 0 = newest
	if offset < 0 or offset >= entity.count then
		return nil
	end
	local index = entity.head - 1 - offset -- head-1 = newest slot
	if index < 1 then
		index += capacity
	end
	return index
end

-- Pose at a (possibly fractional) tick. Fractional t lerps between the two
-- bracketing samples - rewind depths derived from RTT rarely land on whole
-- ticks. A request at most 1 tick past the newest sample clamps to the
-- newest pose (the shooter's estimate overshot by a hair); anything further
-- in the future or older than the window returns nil - never extrapolate.
function LagCompensation.GetPositionAt(self: Internal, id: number, tick: number): (Vector3?, boolean)
	local entity = self._entities[id]
	if entity == nil or entity.count == 0 then
		return nil, false
	end
	if tick >= entity.newestTick then
		if tick > entity.newestTick + 1 then
			return nil, false -- stale timeline (entity stopped recording)
		end
		local i = indexFor(entity, self._capacity, entity.newestTick) :: number
		return entity.positions[i], entity.crouches[i]
	end
	local lo = math.floor(tick)
	local iLo = indexFor(entity, self._capacity, lo)
	if iLo == nil then
		return nil, false -- older than the window: refuse
	end
	local alpha = tick - lo
	if alpha == 0 then
		return entity.positions[iLo], entity.crouches[iLo]
	end
	local iHi = indexFor(entity, self._capacity, lo + 1) :: number -- lo < newest => hi exists
	local pos = entity.positions[iLo]:Lerp(entity.positions[iHi], alpha)
	-- The discrete field snaps to the nearer sample.
	local nearer = if alpha < 0.5 then iLo else iHi
	return pos, entity.crouches[nearer]
end

-- Slab-test ray vs AABB. Returns entry distance along the unit ray in
-- [0, maxDist], 0 when the origin starts inside, nil on miss.
local function rayBox(
	origin: Vector3,
	dir: Vector3,
	minV: Vector3,
	maxV: Vector3,
	maxDist: number
): number?
	local tMin = 0
	local tMax = maxDist
	for axis = 1, 3 do
		local o = if axis == 1 then origin.X elseif axis == 2 then origin.Y else origin.Z
		local d = if axis == 1 then dir.X elseif axis == 2 then dir.Y else dir.Z
		local lo = if axis == 1 then minV.X elseif axis == 2 then minV.Y else minV.Z
		local hi = if axis == 1 then maxV.X elseif axis == 2 then maxV.Y else maxV.Z
		if math.abs(d) < 1e-9 then
			if o < lo or o > hi then
				return nil -- parallel to the slab and outside it
			end
		else
			local inv = 1 / d
			local t1 = (lo - o) * inv
			local t2 = (hi - o) * inv
			if t1 > t2 then
				t1, t2 = t2, t1
			end
			tMin = math.max(tMin, t1)
			tMax = math.min(tMax, t2)
			if tMin > tMax then
				return nil
			end
		end
	end
	return tMin
end

-- Lag-compensated hitscan: rewinds every entity (except excludeId) to `tick`
-- and intersects the ray with the pose-correct hull. The recorded position is
-- the STANDING hull centre; crouching keeps the feet planted and lowers the
-- top. Returns the nearest (id, hitPoint, distance).
function LagCompensation.RaycastAt(
	self: Internal,
	tick: number,
	origin: Vector3,
	direction: Vector3,
	maxDistance: number,
	excludeId: number?
): (number?, Vector3?, number?)
	local mag = direction.Magnitude
	if mag < 1e-9 or maxDistance <= 0 then
		return nil, nil, nil
	end
	local dir = direction / mag

	local bestT: number? = nil
	local bestId: number? = nil
	for id in self._entities do
		if id ~= excludeId then
			local pos, crouched = self:GetPositionAt(id, tick)
			if pos ~= nil then
				local p = pos :: Vector3
				local footY = p.Y - self._halfY
				local topY = footY + (if crouched then self._crouchHeight else 2 * self._halfY)
				local minV = Vector3.new(p.X - self._halfX, footY, p.Z - self._halfZ)
				local maxV = Vector3.new(p.X + self._halfX, topY, p.Z + self._halfZ)
				local t = rayBox(origin, dir, minV, maxV, maxDistance)
				if t ~= nil and (bestT == nil or t < bestT) then
					bestT = t
					bestId = id
				end
			end
		end
	end

	if bestT ~= nil then
		return bestId, origin + dir * bestT, bestT
	end
	return nil, nil, nil
end

local function new(
	capacityTicks: number,
	maxRewindTicks: number,
	hullSize: Vector3,
	crouchHeight: number
): LagCompensation
	assert(capacityTicks > 0, "capacityTicks must be positive")
	assert(maxRewindTicks <= capacityTicks, "maxRewindTicks cannot exceed history capacity")
	return setmetatable({
		_entities = {},
		_capacity = capacityTicks,
		_maxRewindTicks = maxRewindTicks,
		_halfX = hullSize.X * 0.5,
		_halfY = hullSize.Y * 0.5,
		_halfZ = hullSize.Z * 0.5,
		_crouchHeight = crouchHeight,
		_newestTick = 0,
	}, LagCompensation) :: any
end

return { new = new }
