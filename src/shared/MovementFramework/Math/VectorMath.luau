--!strict
--[[
	VectorMath.luau
	Purpose: Pure vector helpers used by the simulation hot path.
	Performance: Vector3 is a native value type in Luau (no heap allocation), so
	constructing vectors here is register-level work. All functions are branch-light
	and allocation-free.
]]

local VectorMath = {}

local ZERO = Vector3.zero
local UP = Vector3.yAxis

VectorMath.ZERO = ZERO
VectorMath.UP = UP

-- Horizontal (XZ) length without allocating an intermediate vector.
function VectorMath.horizontalLength(v: Vector3): number
	return math.sqrt(v.X * v.X + v.Z * v.Z)
end

function VectorMath.flatten(v: Vector3): Vector3
	return Vector3.new(v.X, 0, v.Z)
end

function VectorMath.withY(v: Vector3, y: number): Vector3
	return Vector3.new(v.X, y, v.Z)
end

-- Safe normalize: returns ZERO for degenerate input instead of NaN.
function VectorMath.safeUnit(v: Vector3): Vector3
	local m = v.Magnitude
	if m < 1e-6 then
		return ZERO
	end
	return v / m
end

-- Quake's PM_ClipVelocity: remove the component of `velocity` that points into
-- `normal`, scaled by overbounce (1.0 = perfect slide, >1 pushes slightly away
-- to defeat floating point re-penetration).
function VectorMath.clipVelocity(velocity: Vector3, normal: Vector3, overbounce: number): Vector3
	local backoff = velocity:Dot(normal) * overbounce
	local out = velocity - normal * backoff
	-- Kill tiny residuals so we do not creep along planes.
	if out:Dot(normal) < 0 and math.abs(out:Dot(normal)) < 0.001 then
		out -= normal * out:Dot(normal)
	end
	return out
end

-- Build a wish direction from yaw + input axes on the horizontal plane.
-- yaw follows Roblox convention: 0 faces -Z, positive rotates counter-clockwise.
function VectorMath.wishDirection(yaw: number, moveX: number, moveZ: number): Vector3
	local sinY = math.sin(yaw)
	local cosY = math.cos(yaw)
	-- forward = (-sin, 0, -cos), right = (cos, 0, -sin)
	local x = -sinY * moveZ + cosY * moveX
	local z = -cosY * moveZ - sinY * moveX
	local m = math.sqrt(x * x + z * z)
	if m < 1e-6 then
		return ZERO
	end
	return Vector3.new(x / m, 0, z / m)
end

-- Angle of a surface normal from horizontal, in degrees. Flat ground = 0.
function VectorMath.surfaceAngle(normal: Vector3): number
	return math.deg(math.acos(math.clamp(normal.Y, -1, 1)))
end

function VectorMath.lerp(a: number, b: number, t: number): number
	return a + (b - a) * t
end

-- Framerate-independent exponential decay toward a target.
function VectorMath.damp(current: number, target: number, lambda: number, dt: number): number
	return VectorMath.lerp(current, target, 1 - math.exp(-lambda * dt))
end

function VectorMath.dampVector(current: Vector3, target: Vector3, lambda: number, dt: number): Vector3
	return current:Lerp(target, 1 - math.exp(-lambda * dt))
end

return table.freeze(VectorMath)
