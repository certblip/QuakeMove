--!strict
--[[
	ServerBootstrap.server.luau
	Purpose: Server composition root. Publishes the framework module to
	ReplicatedStorage (so clients can require it), creates the remote transport
	folder, and starts the authoritative movement service.
	Architecture notes: The framework ModuleScript is authored under
	ServerStorage/shared and cloned into ReplicatedStorage here so a single source
	of truth ships to both realms. This file lives in ServerScriptService.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

-- Ensure the shared framework is replicated. In a Rojo project the MovementFramework
-- ModuleScript is mapped directly into ReplicatedStorage and this guard is a no-op.
assert(
	ReplicatedStorage:FindFirstChild("MovementFramework"),
	"MovementFramework must be placed in ReplicatedStorage (map src/shared there via Rojo)"
)

local Framework = require(ReplicatedStorage.MovementFramework)
local MovementConfig = Framework.MovementConfig

-- Remotes are created by ServerMovementService.Init (idempotent) before any
-- player can join; the client side WaitForChild's them, so no eager copy here.
local ServerMovementService = require(ServerScriptService:WaitForChild("ServerMovementService"))

local fw = Framework.create({
	FixedRate = 60,
	MovementProfile = MovementConfig.Default,
})

fw:RegisterService(ServerMovementService.new(fw, MovementConfig.Default))
fw:Start()
