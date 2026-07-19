--!strict
--[[
	ClientBootstrap.client.luau
	Purpose: The client composition root. Creates the framework, chooses profiles,
	instantiates every client service, registers them with the DI container in
	dependency order, and starts the single scheduler.
	Architecture notes: This is the ONLY place client services are constructed and
	wired. No service reaches out to another except through the registry it is
	handed at Init. Swap NullTransport <-> RemoteTransport here to toggle offline
	play - nothing downstream changes.
	This file lives in StarterPlayerScripts.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Framework = require(ReplicatedStorage:WaitForChild("MovementFramework"))
local MovementConfig = Framework.MovementConfig
local CameraConfig = Framework.CameraConfig
local InputConfig = Framework.InputConfig

local StarterPlayerScripts = script.Parent
local InputService = require(StarterPlayerScripts:WaitForChild("InputService"))
local CameraService = require(StarterPlayerScripts:WaitForChild("CameraService"))
local CharacterAdapter = require(StarterPlayerScripts:WaitForChild("CharacterAdapter"))
local DebugOverlay = require(StarterPlayerScripts:WaitForChild("DebugOverlay"))
local MovementController = require(StarterPlayerScripts:WaitForChild("MovementController"))
local Transport = require(ReplicatedStorage.MovementFramework.Networking.Transport)

-- 1. Framework instance + chosen profiles.
local fw = Framework.create({
	FixedRate = 60,
	MovementProfile = MovementConfig.Default,
	CameraProfile = CameraConfig.Default,
	InputProfile = InputConfig.Default,
	SpawnPosition = Vector3.new(0, 10, 0),
})

-- 2. Transport: live remotes. Use Transport.newNull() for pure offline testing.
local transport = Transport.newClient()

-- 3. Services.
local inputService = InputService.new(fw:GetInputProfile())
local cameraService = CameraService.new(fw:GetCameraProfile(), fw:GetInputProfile().MouseSensitivity)
local characterAdapter = CharacterAdapter.new()
local debugOverlay = DebugOverlay.new(false)
local controller = MovementController.new(fw, transport)

-- 4. Register (registry resolves ordering via declared Dependencies).
fw:RegisterService(inputService)
fw:RegisterService(cameraService)
fw:RegisterService(characterAdapter)
fw:RegisterService(debugOverlay)
fw:RegisterService(controller)

-- 5. Go.
fw:Start()

-- Expose for console tinkering / other local scripts.
local _G2 = shared :: any
_G2.MovementFramework = fw
