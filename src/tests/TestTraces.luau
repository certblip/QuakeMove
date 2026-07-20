--!strict
--[[
	TestTraces.luau
	Purpose: Analytic TraceFn worlds for engine-free simulation tests. The
	simulator only sees Types.TraceFn, so these replace Blockcast with exact
	plane math - deterministic, instant, no Roblox world required.
	Crouch model (mirrors Collision.luau): the crouched hull shrinks from the
	TOP - `origin` is always the STANDING box centre and the feet never move.
	Floors therefore ignore the pose entirely; only ceiling checks care, using
	hull top = origin.Y + (crouched ? crouchHeight - halfStand : halfStand).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Types = require(ReplicatedStorage:WaitForChild("MovementFramework"):WaitForChild("Core"):WaitForChild("Types"))

local TestTraces = {}

local function miss(endPos: Vector3): Types.TraceResult
	return {
		fraction = 1,
		hit = false,
		normal = Vector3.yAxis,
		position = endPos,
		instance = nil,
		startSolid = false,
		ladder = false,
	}
end

-- Infinite flat floor at floorY. The swept box rests when the standing-box
-- centre reaches floorY + halfHeight (pose-independent: feet are fixed).
function TestTraces.flatFloor(floorY: number, halfHeight: number): Types.TraceFn
	local floorCentre = floorY + halfHeight
	return function(origin: Vector3, delta: Vector3, _crouched: boolean?): Types.TraceResult
		local endPos = origin + delta
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
				ladder = false,
			}
		end
		return miss(endPos)
	end
end

-- Flat floor + an infinite vertical wall plane at x = wallX facing -X;
-- the box's half-width keeps its centre at wallX - halfWidth.
function TestTraces.floorAndWall(
	floorY: number,
	halfHeight: number,
	wallX: number,
	halfWidth: number
): Types.TraceFn
	local floorTrace = TestTraces.flatFloor(floorY, halfHeight)
	local faceX = wallX - halfWidth
	return function(origin: Vector3, delta: Vector3, crouched: boolean?): Types.TraceResult
		if delta.X > 1e-8 then
			local endPos = origin + delta
			if endPos.X >= faceX and origin.X <= faceX + 1e-3 then
				local frac = math.clamp((faceX - origin.X) / delta.X, 0, 1)
				return {
					fraction = frac,
					hit = true,
					normal = Vector3.new(-1, 0, 0),
					position = origin + delta * frac,
					instance = nil,
					startSolid = false,
					ladder = false,
				}
			end
		end
		return floorTrace(origin, delta, crouched)
	end
end

-- Flat floor everywhere plus a low ceiling at ceilY that exists only where
-- origin.X >= corridorMinX (a crawl tunnel). Upward sweeps inside the corridor
-- collide with the pose-correct hull TOP - the world that exercises the
-- "cannot stand up under a ceiling" rule.
function TestTraces.lowCorridor(
	floorY: number,
	halfHeight: number,
	crouchHeight: number,
	ceilY: number,
	corridorMinX: number
): Types.TraceFn
	local floorTrace = TestTraces.flatFloor(floorY, halfHeight)
	local crouchTopOffset = crouchHeight - halfHeight -- top of the shrunk hull
	return function(origin: Vector3, delta: Vector3, crouched: boolean?): Types.TraceResult
		if delta.Y > 1e-8 and origin.X >= corridorMinX then
			local top = origin.Y + (if crouched then crouchTopOffset else halfHeight)
			local endTop = top + delta.Y
			if endTop >= ceilY and top <= ceilY + 1e-3 then
				local frac = math.clamp((ceilY - top) / delta.Y, 0, 1)
				return {
					fraction = frac,
					hit = true,
					normal = Vector3.new(0, -1, 0),
					position = origin + delta * frac,
					instance = nil,
					startSolid = frac <= 0,
					ladder = false,
				}
			end
		end
		return floorTrace(origin, delta, crouched)
	end
end

return table.freeze(TestTraces)
