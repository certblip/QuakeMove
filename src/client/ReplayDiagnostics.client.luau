--!nonstrict
--[[
	ReplayDiagnostics.client.luau
	Purpose: On-demand client self-test for the replay feature. Dormant by
	default: it creates NOTHING until you set the boolean attribute
	  workspace.RunDiagnostics = true
	(Workspace > Properties > Attributes, or from the command bar:
	  workspace:SetAttribute("RunDiagnostics", true)
	- works from either the Client or Server context; attributes replicate).
	While active it publishes every check under workspace.problemreplay.problems
	(a StringValue per check: "PASS <id>" / "FAIL <id>", value = detail) and a
	floating billboard summary. Set the attribute to false to remove the cube;
	set it to true again to re-run.
	Deliberately independent of the framework's DI so it still reports even if
	a service failed to boot. Lives in StarterPlayerScripts; dev-only.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local StarterGui = game:GetService("StarterGui")
local Workspace = game:GetService("Workspace")

local LP = Players.LocalPlayer

local ATTRIBUTE = "RunDiagnostics"

--------------------------------------------------------------------------------
-- Explorer + billboard reporting (created lazily per run)
--------------------------------------------------------------------------------

type Ui = {
	root: Part,
	problems: Folder,
	label: TextLabel,
}

local currentUi: Ui? = nil
local running = false

local function destroyUi()
	if currentUi then
		currentUi.root:Destroy()
		currentUi = nil
	end
end

local function createUi(): Ui
	destroyUi()

	local root = Instance.new("Part")
	root.Name = "problemreplay"
	root.Anchored = true
	root.CanCollide = false
	root.CanQuery = false
	root.Transparency = 0.35
	root.Size = Vector3.new(4, 4, 4)
	root.Color = Color3.fromRGB(255, 200, 60)
	local char = LP.Character
	local hrp = char and char:FindFirstChild("HumanoidRootPart")
	root.Position = if hrp then (hrp :: BasePart).Position + Vector3.new(0, 8, 0) else Vector3.new(0, 12, 0)
	root.Parent = Workspace

	local problems = Instance.new("Folder")
	problems.Name = "problems"
	problems.Parent = root

	local billboard = Instance.new("BillboardGui")
	billboard.Size = UDim2.fromScale(14, 9)
	billboard.StudsOffsetWorldSpace = Vector3.new(0, 5, 0)
	billboard.AlwaysOnTop = true
	billboard.Parent = root

	local label = Instance.new("TextLabel")
	label.Size = UDim2.fromScale(1, 1)
	label.BackgroundTransparency = 0.25
	label.BackgroundColor3 = Color3.fromRGB(15, 15, 20)
	label.TextColor3 = Color3.fromRGB(235, 235, 235)
	label.Font = Enum.Font.Code
	label.TextScaled = false
	label.TextSize = 16
	label.TextXAlignment = Enum.TextXAlignment.Left
	label.TextYAlignment = Enum.TextYAlignment.Top
	label.Text = "ReplayDiagnostics: running..."
	label.Parent = billboard

	local ui: Ui = { root = root, problems = problems, label = label }
	currentUi = ui
	return ui
end

--------------------------------------------------------------------------------
-- Checks
--------------------------------------------------------------------------------

local function countNamed(parent: Instance, name: string): number
	local n = 0
	for _, c in parent:GetChildren() do
		if c.Name == name then
			n += 1
		end
	end
	return n
end

local function runDiagnostics()
	if running then
		return
	end
	running = true

	local ui = createUi()
	local failures = 0
	local lines: { string } = {}

	local function report(id: string, ok: boolean, detail: string)
		local v = Instance.new("StringValue")
		v.Name = (if ok then "PASS " else "FAIL ") .. id
		v.Value = detail
		v.Parent = ui.problems
		if not ok then
			failures += 1
		end
		table.insert(lines, string.format("%s %s: %s", if ok then "[PASS]" else "[FAIL]", id, detail))
		ui.label.Text = table.concat(lines, "\n")
		if ok then
			print(string.format("[ReplayDiagnostics] PASS %s - %s", id, detail))
		else
			warn(string.format("[ReplayDiagnostics] FAIL %s - %s", id, detail))
		end
	end

	local function finish()
		local pass = failures == 0
		ui.root.Color = if pass then Color3.fromRGB(70, 220, 110) else Color3.fromRGB(230, 70, 70)
		ui.root:SetAttribute("Summary", if pass then "ALL PASS" else (failures .. " FAIL"))
		ui.label.Text = string.format(
			"ReplayDiagnostics @ %s\n%s\n\n%s",
			os.date("%H:%M:%S"),
			if pass then "ALL CHECKS PASSED" else (failures .. " FAILURE(S) - see Explorer > problemreplay > problems"),
			table.concat(lines, "\n")
		)
		running = false
	end

	-- The character may already exist when triggered; never hang on the signal.
	local _char = LP.Character or LP.CharacterAdded:Wait()
	task.wait(1) -- let ClientBootstrap + GUI cloning settle

	-- 1. Framework replicated?
	local fwModule = ReplicatedStorage:FindFirstChild("MovementFramework")
	report(
		"framework_replicated",
		fwModule ~= nil,
		if fwModule then "found in ReplicatedStorage" else "MISSING - map src/shared there via Rojo"
	)

	-- 2. Framework instance exposed by ClientBootstrap?
	local fw = (shared :: any).MovementFramework
	report(
		"framework_started",
		fw ~= nil,
		if fw then "shared.MovementFramework present (ClientBootstrap ran)" else "nil - ClientBootstrap errored before finishing"
	)

	-- 3. Services registered?
	if fw then
		for _, name in { "MovementController", "ReplayService", "CameraService", "CharacterAdapter" } do
			local ok, svc = pcall(function()
				return fw:GetService(name)
			end)
			report("service_" .. name, ok and svc ~= nil, if ok and svc then "registered" else "NOT registered / Get failed")
		end
	end

	-- 4. GUI present + not duplicated
	local playerGui = LP:WaitForChild("PlayerGui")
	local guiCount = countNamed(playerGui, "ReplayHUD")
	report("replayhud_in_playergui", guiCount == 1, string.format("%d instance(s) in PlayerGui (want exactly 1)", guiCount))
	report(
		"replayhud_in_startergui",
		countNamed(StarterGui, "ReplayHUD") <= 1,
		string.format("%d in StarterGui (>1 => stale place file)", countNamed(StarterGui, "ReplayHUD"))
	)

	-- 5. GUI structure
	local hud = playerGui:FindFirstChild("ReplayHUD")
	local panel = hud and hud:FindFirstChild("Panel")
	if panel then
		report("gui_recordbutton", panel:FindFirstChild("RecordButton") ~= nil, "RecordButton " .. (panel:FindFirstChild("RecordButton") and "present" or "MISSING"))
		report("gui_playbutton", panel:FindFirstChild("PlayButton") ~= nil, "PlayButton " .. (panel:FindFirstChild("PlayButton") and "present" or "MISSING"))
		report("gui_status", panel:FindFirstChild("Status") ~= nil, "Status " .. (panel:FindFirstChild("Status") and "present" or "MISSING"))
	else
		report("gui_panel", false, "ReplayHUD.Panel not found - GUI tree broken or not yet cloned")
	end

	-- 6. Simulation actually ticking?
	if fw then
		local t0 = fw.State.tick
		task.wait(1)
		local dt = fw.State.tick - t0
		report("sim_ticking", dt >= 30, string.format("state.tick advanced %d in 1s (want >=30; 0 => not bound/disabled)", dt))
	end

	-- 7. Character bound + anchored (the container the sim drives)
	local char = LP.Character
	local hrp = char and char:FindFirstChild("HumanoidRootPart")
	report(
		"character_anchored",
		hrp ~= nil and (hrp :: BasePart).Anchored == true,
		if hrp then ("HRP anchored=" .. tostring((hrp :: BasePart).Anchored)) else "no HumanoidRootPart"
	)

	-- 8. Live record->play self-test (only if the user is not mid-recording)
	if fw then
		local okCtrl, controller = pcall(function()
			return fw:GetService("MovementController")
		end)
		if okCtrl and controller then
			local rec = controller:GetReplayRecorder()
			if rec:IsRecording() then
				report("selftest_record", false, "skipped: a recording is already in progress")
			else
				rec:Begin(fw.State)
				task.wait(0.6)
				local replay = rec:Finish()
				local count = if replay then replay.count else 0
				report("selftest_record", count > 0, string.format("recorded %d ticks in 0.6s (0 => sim not feeding the recorder)", count))

				if replay and count > 0 then
					local okPlay, detail = pcall(function()
						local Simulator = require(fwModule.Simulation.Simulator)
						local MoveState = require(fwModule.Simulation.MoveState)
						local sim = Simulator.new(fw:GetMovementProfile(), fw.CollisionWorld.Trace)
						local out = MoveState.new(Vector3.zero)
						for i = 1, replay.count do
							sim:Step(out, replay.commands[i])
						end
						return string.format("re-sim ok, final tick=%d", out.tick)
					end)
					report("selftest_playback", okPlay, if okPlay then detail else ("re-sim error: " .. tostring(detail)))
				end
			end
		end
	end

	report("hint_mouse", true, "if buttons ignore clicks: press G to free the cursor, then click")
	finish()
end

--------------------------------------------------------------------------------
-- Trigger: dormant until workspace attribute RunDiagnostics == true
--------------------------------------------------------------------------------

local function onAttribute()
	if Workspace:GetAttribute(ATTRIBUTE) then
		task.spawn(runDiagnostics)
	else
		destroyUi()
	end
end

Workspace:GetAttributeChangedSignal(ATTRIBUTE):Connect(onAttribute)
onAttribute()
