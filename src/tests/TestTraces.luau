--!strict
--[[
	TestTraces.luau
	Purpose: Analytic TraceFn worlds for engine-free simulation tests. The
	simulator only sees Types.TraceFn, so these replace Blockcast with exact
	plane math - deterministic, instant, no Roblox world required.
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

-- Infinite flat floor at floorY. The swept box (given half-height) rests when
-- its centre reaches floorY + halfHeight.
function TestTraces.flatFloor(floorY: number, halfHeight: number): Types.TraceFn
	local floorCentre = floorY + halfHeight
	return function(origin: Vector3, delta: Vector3): Types.TraceResult
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

-- Flat floor + an infinite vertical wall plane at x = wallX facing -X
-- (normal (-1,0,0)); the box's half-width keeps its centre at wallX - halfWidth.
function TestTraces.floorAndWall(
	floorY: number,
	halfHeight: number,
	wallX: number,
	halfWidth: number
): Types.TraceFn
	local floorTrace = TestTraces.flatFloor(floorY, halfHeight)
	local faceX = wallX - halfWidth -- box-centre plane of contact
	return function(origin: Vector3, delta: Vector3): Types.TraceResult
		-- Wall test first: moving +X across the contact plane?
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
		return floorTrace(origin, delta)
	end
end

return table.freeze(TestTraces)
