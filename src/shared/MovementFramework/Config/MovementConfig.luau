--!strict
--[[
	MovementConfig.luau
	Purpose: Every tunable of the movement simulation, fully typed, with shipped
	profiles. Implementation code never contains magic numbers.
	Notes: Units are studs and seconds. Values are tuned so 16 studs ~ 1 Quake unit
	scale feels correct at Roblox character proportions.
	Extension: Add new profiles by table-cloning Default; the framework accepts
	any table matching MovementProfile. Use the SAME profile on client and server.
]]

-- Air acceleration strategy. "Quake" = Q3 pmove, "Source" = HL2 gamemovement
-- (uncapped accel scaling - the surf-friendly asymmetry), "CPM" = Challenge
-- ProMode (air control + strafe-only high accel).
export type AirAccelMode = "Quake" | "Source" | "CPM"

export type MovementProfile = {
	-- Ground movement
	GroundSpeed: number, -- target horizontal speed while walking
	SprintMultiplier: number,
	GroundAcceleration: number, -- Quake accel constant (per second)
	Friction: number,
	StopSpeed: number, -- friction control floor (enables crisp stops)

	-- Air movement
	AirAccelMode: AirAccelMode,
	AirAcceleration: number,
	AirSpeedCap: number, -- wishspeed clamp for air accel; the soul of airstrafing
	MaxAirWishSpeed: number,

	-- CPM extras (only read when AirAccelMode == "CPM")
	CPMAirControl: number, -- velocity-turning power on pure forward/back input
	CPMAirStopAcceleration: number, -- accel multiplier when wishing against velocity
	CPMStrafeAcceleration: number, -- accel for pure-strafe (A/D) input
	CPMStrafeSpeedCap: number, -- wishspeed cap for pure-strafe input

	-- Vertical
	Gravity: number,
	JumpPower: number, -- upward velocity applied on jump
	AutoJump: boolean,
	JumpBufferTime: number,
	CoyoteTime: number,

	-- Ramps / surf / slopes
	SlopeLimit: number, -- degrees; steeper than this = surf surface
	SurfFriction: number, -- friction applied while surfing (0 = pure Quake surf)
	RampBoostThreshold: number, -- min separation speed to skip ground snap
	GroundSnapDistance: number,
	StepHeight: number,

	-- Slide mechanic
	SlideEnabled: boolean,
	SlideMultiplier: number, -- initial boost applied to horizontal velocity
	SlideFriction: number,
	SlideMinSpeed: number, -- slide ends below this speed
	SlideMaxTime: number,

	-- Crouch stance (Source-style duck; shares the Slide key)
	CrouchEnabled: boolean,
	CrouchColliderHeight: number, -- collider Y while crouched (< ColliderSize.Y)
	CrouchEyeHeight: number, -- eye offset above the crouched box centre
	CrouchSpeedMultiplier: number, -- ground wishspeed scale while crouched

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

	-- Wall running
	WallRunEnabled: boolean,
	WallRunMaxTime: number, -- budget in seconds; refilled on ground contact
	WallRunGravityScale: number, -- 0..1; the reduced pull is what sells the run
	WallRunMinSpeed: number, -- horizontal speed required to stay attached
	WallRunStickDistance: number, -- wall probe reach beyond the collider half-width
	WallRunJumpKick: number, -- horizontal push off the wall on jump
	WallRunJumpBoost: number, -- vertical velocity granted by a wall jump

	-- Ladders (Source-style)
	LadderEnabled: boolean,
	LadderClimbSpeed: number,
	LadderJumpKick: number, -- push away from the ladder on jump-off
}

local Default: MovementProfile = {
	GroundSpeed = 20,
	SprintMultiplier = 1.35,
	GroundAcceleration = 10,
	Friction = 6,
	StopSpeed = 6.25,

	AirAccelMode = "Quake" :: AirAccelMode,
	AirAcceleration = 40,
	AirSpeedCap = 1.9, -- ~30ups in Quake scale; low cap => strong strafe gain
	MaxAirWishSpeed = 20,

	CPMAirControl = 150,
	CPMAirStopAcceleration = 2.5,
	CPMStrafeAcceleration = 70,
	CPMStrafeSpeedCap = 1.9,

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

	CrouchEnabled = true,
	CrouchColliderHeight = 3.0, -- vs 5.0 standing: clears low gaps when ducked
	CrouchEyeHeight = 1.15,
	CrouchSpeedMultiplier = 0.55,

	MaxVelocity = 200,
	Overbounce = 1.001,
	MaxClipPlanes = 5,
	MaxBumps = 4,

	ColliderSize = Vector3.new(2.6, 5.0, 2.6),
	EyeHeight = 2.1,

	LandingRecoveryTime = 0.18,
	HardLandingSpeed = 30,

	WallRunEnabled = true,
	WallRunMaxTime = 1.6,
	WallRunGravityScale = 0.25,
	WallRunMinSpeed = 14,
	WallRunStickDistance = 1.0,
	WallRunJumpKick = 18,
	WallRunJumpBoost = 15,

	LadderEnabled = true,
	LadderClimbSpeed = 12,
	LadderJumpKick = 16,
}

-- QuakeLive-flavoured: tighter ground control, harsher stops, faster bhop ceiling.
local QuakeLive: MovementProfile = table.clone(Default)
QuakeLive.GroundAcceleration = 15
QuakeLive.Friction = 8
QuakeLive.AirAcceleration = 70
QuakeLive.AirSpeedCap = 1.6

-- Source-flavoured: Source AirAccelerate, lower air accel, classic CS surf.
local Source: MovementProfile = table.clone(Default)
Source.AirAccelMode = "Source"
Source.AirAcceleration = 25
Source.AirSpeedCap = 1.9
Source.AutoJump = false
Source.GroundSpeed = 16

-- Challenge ProMode: air control on W/S, high-accel strafe on pure A/D,
-- snappier ground handling. The classic VQ3+CPM hybrid feel.
local CPM: MovementProfile = table.clone(Default)
CPM.AirAccelMode = "CPM"
CPM.GroundAcceleration = 15
CPM.Friction = 8
CPM.AirAcceleration = 30
CPM.AirSpeedCap = 1.9

local frozenDefault = table.freeze(Default) :: MovementProfile

local Profiles = table.freeze({
	Default = frozenDefault,
	Quake = frozenDefault, -- alias: the default IS the Quake feel
	QuakeLive = table.freeze(QuakeLive) :: MovementProfile,
	Source = table.freeze(Source) :: MovementProfile,
	CPM = table.freeze(CPM) :: MovementProfile,
})

return Profiles
