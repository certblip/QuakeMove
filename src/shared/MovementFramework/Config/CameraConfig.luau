--!strict
--[[
	CameraConfig.luau
	Purpose: Typed tunables for every camera effect. Effects read only their own
	sub-table; the pipeline reads Base.
]]

export type HeadBobConfig = {
	Enabled: boolean,
	Frequency: number, -- cycles per second at reference speed
	Amplitude: number, -- studs of vertical bob
	LateralAmplitude: number,
	ReferenceSpeed: number,
	AirFade: number, -- how fast bob fades when airborne (lambda)
}

export type TiltConfig = {
	Enabled: boolean,
	StrafeTilt: number, -- radians of roll at full strafe input
	VelocityTilt: number, -- extra roll from lateral velocity (rad per stud/s)
	WallRunTilt: number, -- radians of roll away from the wall while wall-running
	Responsiveness: number, -- damp lambda
}

export type FOVConfig = {
	Enabled: boolean,
	BaseFOV: number,
	SpeedFOVScale: number, -- degrees added per stud/s over ReferenceSpeed
	ReferenceSpeed: number,
	MaxFOVOffset: number,
	Responsiveness: number,
}

export type LandingConfig = {
	Enabled: boolean,
	DipPerSpeed: number, -- studs of dip per stud/s of landing speed
	MaxDip: number,
	Stiffness: number,
	Damping: number,
}

export type ShakeConfig = {
	Enabled: boolean,
	TraumaDecay: number,
	MaxOffset: number,
	MaxRoll: number,
	Frequency: number,
}

export type SwayConfig = {
	Enabled: boolean,
	VelocityScale: number, -- positional sway from velocity
	MaxSway: number,
	Responsiveness: number,
}

export type SlideConfig = {
	Enabled: boolean,
	EyeDrop: number, -- studs the eye lowers while sliding (crouch pose)
	Roll: number, -- radians of camera roll while sliding
	Responsiveness: number, -- damp lambda for enter/exit blending
}

export type CameraProfile = {
	HeadBob: HeadBobConfig,
	Tilt: TiltConfig,
	FOV: FOVConfig,
	Landing: LandingConfig,
	Shake: ShakeConfig,
	Sway: SwayConfig,
	Slide: SlideConfig,
}

local Default: CameraProfile = {
	HeadBob = {
		Enabled = true,
		Frequency = 1.7,
		Amplitude = 0.14,
		LateralAmplitude = 0.09,
		ReferenceSpeed = 20,
		AirFade = 10,
	},
	Tilt = {
		Enabled = true,
		StrafeTilt = math.rad(1.6),
		VelocityTilt = math.rad(0.035),
		WallRunTilt = math.rad(10),
		Responsiveness = 12,
	},
	FOV = {
		Enabled = true,
		BaseFOV = 90,
		SpeedFOVScale = 0.35,
		ReferenceSpeed = 20,
		MaxFOVOffset = 18,
		Responsiveness = 6,
	},
	Landing = {
		Enabled = true,
		DipPerSpeed = 0.012,
		MaxDip = 0.9,
		Stiffness = 320,
		Damping = 22,
	},
	Shake = {
		Enabled = true,
		TraumaDecay = 1.6,
		MaxOffset = 0.35,
		MaxRoll = math.rad(2.5),
		Frequency = 21,
	},
	Sway = {
		Enabled = true,
		VelocityScale = 0.004,
		MaxSway = 0.28,
		Responsiveness = 8,
	},
	Slide = {
		Enabled = true,
		EyeDrop = 1.1, -- ~half of the default 2.1 EyeHeight: reads as a crouch
		Roll = math.rad(2.2),
		Responsiveness = 10,
	},
}

local Minimal: CameraProfile = table.clone(Default)
Minimal.HeadBob = table.clone(Default.HeadBob)
Minimal.HeadBob.Enabled = false
Minimal.Shake = table.clone(Default.Shake)
Minimal.Shake.Enabled = false

return table.freeze({
	Default = table.freeze(Default) :: CameraProfile,
	Minimal = table.freeze(Minimal) :: CameraProfile,
})
