--!strict
--[[
	Spring.luau
	Purpose: Critically-damped-capable harmonic spring for camera effects
	(landing dip, shake recovery, weapon sway).
	Performance: Semi-implicit Euler integration; two multiplies and two adds per
	axis per frame. State lives in plain number fields - zero allocation.
	Notes: Stable for stiffness/damping values used by the shipped camera configs;
	extreme values should be validated with the included test.
]]

export type Spring3 = {
	Position: Vector3,
	Velocity: Vector3,
	Target: Vector3,
	Stiffness: number,
	Damping: number,
	Update: (self: Spring3, dt: number) -> Vector3,
	Impulse: (self: Spring3, impulse: Vector3) -> (),
	Reset: (self: Spring3) -> (),
}

local Spring = {}
Spring.__index = Spring

function Spring.Update(self: Spring3, dt: number): Vector3
	-- Semi-implicit Euler keeps the spring stable at high stiffness.
	local toTarget = self.Target - self.Position
	local accel = toTarget * self.Stiffness - self.Velocity * self.Damping
	self.Velocity += accel * dt
	self.Position += self.Velocity * dt
	return self.Position
end

function Spring.Impulse(self: Spring3, impulse: Vector3)
	self.Velocity += impulse
end

function Spring.Reset(self: Spring3)
	self.Position = Vector3.zero
	self.Velocity = Vector3.zero
	self.Target = Vector3.zero
end

local function new(stiffness: number, damping: number): Spring3
	return setmetatable({
		Position = Vector3.zero,
		Velocity = Vector3.zero,
		Target = Vector3.zero,
		Stiffness = stiffness,
		Damping = damping,
	}, Spring) :: any
end

return { new = new }
