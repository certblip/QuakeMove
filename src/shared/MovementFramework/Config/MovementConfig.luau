--!strict
--[[
	MovementConfig.luau
	Purpose: Every tunable of the movement simulation, fully typed, with shipped
	profiles. Implementation code never contains magic numbers.
	Notes: Units are studs and seconds. Values are tuned so 16 studs ~ 1 Quake unit
	scale feels correct at Roblox character proportions.
	Extension: Add new profiles by table-merging over Default; the framework accepts
	any table matching MovementProfile.
]]

export type MovementProfile = {
	-- Ground movement
	GroundSpeed: number, -- target horizontal speed while walking
	SprintMultiplier: number,
	GroundAcceleration: number, -- Quake accel constant (per second)
	Friction: number,
	StopSpeed: number, -- friction control floor (enables crisp stops)

	-- Air movement
	AirAcceleration: number,
	AirSpeedCap: number, -- wishspeed clamp for air accel; the soul of airstrafing
	MaxAirWishSpeed: number,

	-- Vertical
	Gravity: number,
	JumpPower: number, -- upward velocity applied on jump
	AutoJump: boolean,
	JumpBufferTime: number,
	CoyoteTime: number,

	-- Ramps / surf / slopes
	SlopeLimit: number, -- degrees; steeper than this = surf surface
	SurfFriction: number, -- friction applied while surfing (0 = pure Quake surf)
	RampBoostThreshold: number, -- min upward speed to skip ground snap (ramp launch)
	GroundSnapDistance: number,
	StepHeight: number,

	-- Slide mechanic
	SlideEnabled: boolean,
	SlideMultiplier: number, -- initial boost applied to horizontal velocity
	SlideFriction: number,
	SlideMinSpeed: number, -- slide ends below this speed
	SlideMaxTime: number,

	-- Limits & solver
	MaxVelocity: number,
	Overbounce: number,
	MaxClipPlanes: number,
	MaxBumps: number,

	-- Collider dimensions
	ColliderSize: Vector3,
	EyeHeight: number,

	-- Landing
	LandingRecoveryTime: number,
	HardLandingSpeed: number,
}

local Default: MovementProfile = {
	GroundSpeed = 20,
	SprintMultiplier = 1.35,
	GroundAcceleration = 10,
	Friction = 6,
	StopSpeed = 6.25,

	AirAcceleration = 40,
	AirSpeedCap = 1.9, -- ~30ups in Quake scale; low cap => strong strafe gain
	MaxAirWishSpeed = 20,

	Gravity = 50,
	JumpPower = 17,
	AutoJump = true,
	JumpBufferTime = 0.12,
	CoyoteTime = 0.10,

	SlopeLimit = 45.5,
	SurfFriction = 0,
	RampBoostThreshold = 9,
	GroundSnapDistance = 0.35,
	StepHeight = 1.1,

	SlideEnabled = true,
	SlideMultiplier = 1.25,
	SlideFriction = 1.2,
	SlideMinSpeed = 8,
	SlideMaxTime = 1.1,

	MaxVelocity = 200,
	Overbounce = 1.001,
	MaxClipPlanes = 5,
	MaxBumps = 4,

	ColliderSize = Vector3.new(2.6, 5.0, 2.6),
	EyeHeight = 2.1,

	LandingRecoveryTime = 0.18,
	HardLandingSpeed = 30,
}

-- QuakeLive-flavoured: tighter ground control, harsher stops, faster bhop ceiling.
local QuakeLive: MovementProfile = table.clone(Default)
QuakeLive.GroundAcceleration = 15
QuakeLive.Friction = 8
QuakeLive.AirAcceleration = 70
QuakeLive.AirSpeedCap = 1.6

-- Source-flavoured: lower air accel, classic CS surf behaviour.
local Source: MovementProfile = table.clone(Default)
Source.AirAcceleration = 25
Source.AirSpeedCap = 1.9
Source.AutoJump = false
Source.GroundSpeed = 16

local Profiles = table.freeze({
	Default = table.freeze(Default) :: MovementProfile,
	QuakeLive = table.freeze(QuakeLive) :: MovementProfile,
	Source = table.freeze(Source) :: MovementProfile,
})

return Profiles
