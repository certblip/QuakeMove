--!strict
--[[
	ReplayService.luau
	Purpose: Binds the replay control panel authored in StarterGui/ReplayHUD
	(record / play buttons + status line). Owns the playback loop: while
	playing it disables the live simulation and re-simulates the recorded
	command stream through the SAME simulator at the recorded tick rate -
	positions are never stored, determinism reproduces the run.
	Architecture notes: The GUI is a shipped instance tree (rbxmx); this
	service only wires events and text, it never constructs UI. Playback
	advances in the render phase behind a fixed accumulator so it runs at
	recording speed regardless of display refresh rate.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local FrameworkModule = ReplicatedStorage:WaitForChild("MovementFramework")
local Framework = require(FrameworkModule)
local Types = require(FrameworkModule:WaitForChild("Core"):WaitForChild("Types"))
local InputConfig = require(FrameworkModule:WaitForChild("Config"):WaitForChild("InputConfig"))
local Replay = require(FrameworkModule:WaitForChild("Networking"):WaitForChild("Replay"))

local Buttons = Types.Buttons

export type ReplayService = {
	Name: string,
	Dependencies: { string }?,
	-- Playback introspection: the HUD mirrors the REPLAY's keystrokes (not
	-- the live keyboard) while a run is playing.
	IsPlaying: (self: ReplayService) -> boolean,
	IsActionHeld: (self: ReplayService, action: InputConfig.ActionName) -> boolean,
	Init: (self: ReplayService, registry: any) -> (),
	Start: (self: ReplayService) -> (),
	Destroy: (self: ReplayService) -> (),
}

type ServiceInternal = ReplayService & {
	_fw: Framework.MovementFramework,
	_controller: any,
	_adapter: any,
	_camera: any,
	_player: Replay.ReplayPlayer,
	_curCmd: Types.InputCommand?,
	_prevYaw: number,
	_prevPitch: number,
	_curYaw: number,
	_curPitch: number,
	_replay: Replay.Replay?,
	_playing: boolean,
	_playedTicks: number,
	_acc: number,
	_recStart: number,
	_gui: ScreenGui?,
	_recordBtn: TextButton?,
	_playBtn: TextButton?,
	_status: TextLabel?,
	_lastStatus: string,
	_conns: { RBXScriptConnection },
	_enabled: boolean,
}

local RENDER_PRIORITY = 95 -- before the camera render (100): playback state lands first
local FIXED_DT = 1 / 60 -- replays advance at the recorded tick rate, never display rate

local COLOR_IDLE = Color3.fromRGB(235, 235, 235)
local COLOR_REC = Color3.fromRGB(255, 90, 80)
local COLOR_PLAY = Color3.fromRGB(120, 255, 140)
local BTN_IDLE = Color3.fromRGB(40, 40, 40)
local BTN_ACTIVE = Color3.fromRGB(120, 40, 36)

local ReplayService = {}
ReplayService.__index = ReplayService

local function recorder(self: ServiceInternal): Replay.ReplayRecorder
	return self._controller:GetReplayRecorder()
end

local function updateButtons(self: ServiceInternal)
	local recordBtn = self._recordBtn
	if recordBtn then
		local recording = recorder(self):IsRecording()
		recordBtn.Text = if recording then "STOP REC" else "REC"
		recordBtn.BackgroundColor3 = if recording then BTN_ACTIVE else BTN_IDLE
	end
	local playBtn = self._playBtn
	if playBtn then
		playBtn.Text = if self._playing then "STOP" else "PLAY"
		playBtn.BackgroundColor3 = if self._playing then BTN_ACTIVE else BTN_IDLE
	end
end

local function stopPlayback(self: ServiceInternal)
	if not self._playing then
		return
	end
	self._playing = false
	self._curCmd = nil
	self._player:Stop()
	-- Hand control back to the live pipeline; the next server snapshot will
	-- reconcile whatever divergence playback introduced.
	self._fw:Enable()
	updateButtons(self)
end

local function toggleRecord(self: ServiceInternal)
	if self._playing then
		return -- recording during playback would capture nothing meaningful
	end
	local rec = recorder(self)
	if rec:IsRecording() then
		self._replay = rec:Finish()
	else
		self._replay = nil -- Begin invalidates the previous view; drop it
		rec:Begin(self._fw.State)
		self._recStart = os.clock()
	end
	updateButtons(self)
end

local function togglePlay(self: ServiceInternal)
	if self._playing then
		stopPlayback(self)
		return
	end
	-- Pressing PLAY while recording finalizes the take first: one-button flow.
	local rec = recorder(self)
	if rec:IsRecording() then
		self._replay = rec:Finish()
	end
	local replay = self._replay
	if replay == nil or replay.count == 0 then
		return
	end
	self._playing = true
	self._playedTicks = 0
	self._acc = 0
	self._fw:Disable() -- the live fixed step must not fight the playback
	self._player:Begin(replay, self._fw.State)
	self._adapter:OnTickCommitted(self._fw.State) -- snap interpolation to the start
	-- Snap the view to the recorded starting look so the camera replays too.
	local first = replay.commands[1]
	if first then
		self._prevYaw, self._curYaw = first.yaw, first.yaw
		self._prevPitch, self._curPitch = first.pitch, first.pitch
		self._camera:SetLook(first.yaw, first.pitch)
	end
	updateButtons(self)
end

local function updateStatus(self: ServiceInternal)
	local status = self._status
	if not status then
		return
	end
	local text: string
	local color: Color3
	local replay = self._replay
	if self._playing then
		text = string.format("PLAY %d/%d", self._playedTicks, if replay then replay.count else 0)
		color = COLOR_PLAY
	elseif recorder(self):IsRecording() then
		local t = os.clock() - self._recStart
		text = string.format("REC %02d:%02d", math.floor(t / 60), math.floor(t % 60))
		color = COLOR_REC
	elseif replay ~= nil then
		text = string.format("READY %d ticks", replay.count)
		color = COLOR_IDLE
	else
		text = "IDLE"
		color = COLOR_IDLE
	end
	if text ~= self._lastStatus then
		self._lastStatus = text
		status.Text = text
		status.TextColor3 = color
	end
end

local function onRender(self: ServiceInternal, dt: number)
	if self._playing then
		self._acc += math.min(dt, 0.25) -- hitch clamp: never fast-forward a freeze
		while self._acc >= FIXED_DT do
			self._acc -= FIXED_DT
			if self._player:Advance(self._fw.Simulator, self._fw.State) then
				self._playedTicks += 1
				self._adapter:OnTickCommitted(self._fw.State)
				local cmd = self._player:GetCurrentCommand()
				if cmd then
					self._prevYaw, self._prevPitch = self._curYaw, self._curPitch
					self._curYaw, self._curPitch = cmd.yaw, cmd.pitch
					self._curCmd = cmd
				end
			else
				stopPlayback(self)
				break
			end
		end
		-- Drive the view from the recorded angles, interpolated between ticks
		-- by the accumulator so the look is as smooth as the display rate.
		-- Writing every frame also overrides any live mouse motion: the
		-- camera belongs to the replay while it plays.
		if self._playing then
			local alpha = math.clamp(self._acc / FIXED_DT, 0, 1)
			self._camera:SetLook(
				self._prevYaw + (self._curYaw - self._prevYaw) * alpha,
				self._prevPitch + (self._curPitch - self._prevPitch) * alpha
			)
		end
	end
	updateStatus(self)
end

local function bindGui(self: ServiceInternal, gui: ScreenGui)
	self._gui = gui
	local panel = gui:FindFirstChild("Panel")
	if not panel then
		return
	end
	local recordBtn = panel:FindFirstChild("RecordButton")
	if recordBtn and recordBtn:IsA("TextButton") then
		self._recordBtn = recordBtn
		table.insert(self._conns, recordBtn.Activated:Connect(function()
			toggleRecord(self)
		end))
	end
	local playBtn = panel:FindFirstChild("PlayButton")
	if playBtn and playBtn:IsA("TextButton") then
		self._playBtn = playBtn
		table.insert(self._conns, playBtn.Activated:Connect(function()
			togglePlay(self)
		end))
	end
	local status = panel:FindFirstChild("Status")
	if status and status:IsA("TextLabel") then
		self._status = status
	end
	updateButtons(self)
end

function ReplayService.IsPlaying(self: ServiceInternal): boolean
	return self._playing
end

-- Decodes an abstract action from the currently-playing recorded command so
-- the HUD can mirror the replay's keystrokes (same axis/button convention as
-- InputService.BuildCommand: moveX +1 right, moveZ +1 forward, Jump bit 0b1).
function ReplayService.IsActionHeld(self: ServiceInternal, action: InputConfig.ActionName): boolean
	local cmd = self._curCmd
	if cmd == nil then
		return false
	end
	if action == "MoveForward" then
		return cmd.moveZ > 0.25
	elseif action == "MoveBack" then
		return cmd.moveZ < -0.25
	elseif action == "MoveRight" then
		return cmd.moveX > 0.25
	elseif action == "MoveLeft" then
		return cmd.moveX < -0.25
	elseif action == "Jump" then
		return bit32.band(cmd.buttons, Buttons.Jump) ~= 0
	elseif action == "Sprint" then
		return bit32.band(cmd.buttons, Buttons.Sprint) ~= 0
	elseif action == "Slide" then
		return bit32.band(cmd.buttons, Buttons.Slide) ~= 0
	end
	return false
end

function ReplayService.Init(self: ServiceInternal, registry: any)
	self._controller = registry:Get("MovementController")
	self._adapter = registry:Get("CharacterAdapter")
	self._camera = registry:Get("CameraService")
end

function ReplayService.Start(self: ServiceInternal)
	local player = Players.LocalPlayer
	local playerGui = player:WaitForChild("PlayerGui")

	-- Self-heal: a stale place file can contain DUPLICATE ReplayHUDs (saved
	-- during an old Rojo session). The extra copy draws on top of the bound
	-- one and swallows every click, so keep the first and disable the rest.
	local seen = false
	for _, child in playerGui:GetChildren() do
		if child.Name == "ReplayHUD" and child:IsA("ScreenGui") then
			if seen then
				child.Enabled = false
				warn("[ReplayService] duplicate ReplayHUD disabled - clean your place file (delete extras in StarterGui, save)")
			else
				seen = true
			end
		end
	end

	-- StarterGui clones into PlayerGui on first spawn; bind lazily, never yield.
	local existing = playerGui:FindFirstChild("ReplayHUD")
	if existing and existing:IsA("ScreenGui") then
		bindGui(self, existing)
	else
		table.insert(self._conns, playerGui.ChildAdded:Connect(function(child: Instance)
			if self._gui == nil and child.Name == "ReplayHUD" and child:IsA("ScreenGui") then
				bindGui(self, child)
			end
		end))
	end

	self._fw.Scheduler:RegisterRender(RENDER_PRIORITY, function(dt: number, _alpha: number)
		if self._enabled then
			onRender(self, dt)
		end
	end)
end

function ReplayService.Destroy(self: ServiceInternal)
	self._enabled = false
	stopPlayback(self)
	for _, conn in self._conns do
		conn:Disconnect()
	end
	table.clear(self._conns)
end

local function new(fw: Framework.MovementFramework): ReplayService
	return setmetatable({
		Name = "ReplayService",
		Dependencies = { "MovementController", "CharacterAdapter", "CameraService" },
		_fw = fw,
		_controller = nil,
		_adapter = nil,
		_camera = nil,
		_player = Replay.newPlayer(),
		_curCmd = nil,
		_prevYaw = 0,
		_prevPitch = 0,
		_curYaw = 0,
		_curPitch = 0,
		_replay = nil,
		_playing = false,
		_playedTicks = 0,
		_acc = 0,
		_recStart = 0,
		_gui = nil,
		_recordBtn = nil,
		_playBtn = nil,
		_status = nil,
		_lastStatus = "",
		_conns = {},
		_enabled = true,
	}, ReplayService) :: any
end

return { new = new }
