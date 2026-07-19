--!strict
--[[
	InputConfig.luau
	Purpose: Action map - binds physical inputs to abstract actions. Rebinding is a
	data change, never a code change.
	Notes: Each action lists every KeyCode that can trigger it, per device class.
	Touch is driven by on-screen controls that call InputService:SetAction directly.
]]

export type ActionName = "MoveForward" | "MoveBack" | "MoveLeft" | "MoveRight"
	| "Jump" | "Sprint" | "Slide" | "ToggleDebug"

export type Binding = {
	Keyboard: { Enum.KeyCode },
	Gamepad: { Enum.KeyCode },
}

export type InputProfile = {
	Bindings: { [ActionName]: Binding },
	GamepadDeadzone: number,
	MouseSensitivity: number,
	GamepadLookSensitivity: number,
}

local Default: InputProfile = {
	Bindings = {
		MoveForward = { Keyboard = { Enum.KeyCode.W, Enum.KeyCode.Up }, Gamepad = {} },
		MoveBack = { Keyboard = { Enum.KeyCode.S, Enum.KeyCode.Down }, Gamepad = {} },
		MoveLeft = { Keyboard = { Enum.KeyCode.A }, Gamepad = {} },
		MoveRight = { Keyboard = { Enum.KeyCode.D }, Gamepad = {} },
		Jump = { Keyboard = { Enum.KeyCode.Space }, Gamepad = { Enum.KeyCode.ButtonA } },
		Sprint = { Keyboard = { Enum.KeyCode.LeftShift }, Gamepad = { Enum.KeyCode.ButtonL3 } },
		Slide = { Keyboard = { Enum.KeyCode.LeftControl, Enum.KeyCode.C }, Gamepad = { Enum.KeyCode.ButtonB } },
		ToggleDebug = { Keyboard = { Enum.KeyCode.F3 }, Gamepad = { Enum.KeyCode.DPadUp } },
	},
	GamepadDeadzone = 0.18,
	MouseSensitivity = 1.0,
	GamepadLookSensitivity = 6.0,
}

return table.freeze({
	Default = table.freeze(Default) :: InputProfile,
})
