--[[
  PrisonLife.lua — reference script built from the deobfuscated client API.

  Place: Prison Life (PlaceId 155615604)
  Source of truth: docs/PrisonLife-Deobfuscated-API.md in this repository.

  Every remote used here is from the recovered client dump:
    RequestTeamChange, RequestHere, GiverPressed, InteractWithItem, TouchGiver,
    ArrestPlayer, meleeEvent, UpdateSetting, GetSettings,
    RequestCollisionChange, ReplicateEvent, InnocentWarnEvent
  Argument shapes are best-effort: the dump gives names and call sites, not
  server-side validation. All calls are pcall-guarded, and features that need a
  remote this build cannot find simply report it in the UI instead of firing.

  Client-side features (ESP, camera assist, fullbright, anti-AFK) need no remote.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local TweenService = game:GetService("TweenService")
local Lighting = game:GetService("Lighting")
local VirtualUser = game:GetService("VirtualUser")
local HttpService = game:GetService("HttpService")
local TeleportService = game:GetService("TeleportService")

local unpackArgs = table.unpack or unpack

local LocalPlayer = Players.LocalPlayer
if not LocalPlayer then
	repeat task.wait() until Players.LocalPlayer
	LocalPlayer = Players.LocalPlayer
end
local Camera = workspace.CurrentCamera or workspace:WaitForChild("Camera")

local PLACE_ID = 155615604
local VERSION = "1.0.0"
local CONFIG_FILE = "pl_research_config.json"

-- ---------------------------------------------------------------- theme

local Theme = {
	window = Color3.fromRGB(16, 16, 22),
	panel = Color3.fromRGB(24, 24, 34),
	row = Color3.fromRGB(31, 31, 44),
	accent = Color3.fromRGB(124, 92, 255),
	accentDark = Color3.fromRGB(92, 66, 200),
	text = Color3.fromRGB(236, 236, 246),
	sub = Color3.fromRGB(148, 148, 170),
	off = Color3.fromRGB(52, 52, 68),
	good = Color3.fromRGB(74, 214, 138),
	danger = Color3.fromRGB(255, 92, 92),
}

local Font = Enum.Font.Gotham
local FontBold = Enum.Font.GothamBold

-- ---------------------------------------------------------------- state

local Config = {
	ESP = false,
	ESPTeamColor = true,
	ESPDistance = 600,
	ESPHealth = true,
	Aim = false,
	AimFOV = 90,
	AimStrength = 0.35,
	AimTeamCheck = true,
	AimDistance = 400,
	Arrest = false,
	ArrestRange = 20,
	AutoGrab = false,
	AutoCollect = false,
	AntiAFK = true,
	Fullbright = false,
}

local unloaded = false
local connections = {}
local espData = {}
local notify

local function saveConfig()
	if typeof(writefile) ~= "function" then return end
	pcall(function()
		writefile(CONFIG_FILE, HttpService:JSONEncode(Config))
	end)
end

local function loadConfig()
	if typeof(isfile) ~= "function" or typeof(readfile) ~= "function" then return end
	local ok, data = pcall(function()
		if not isfile(CONFIG_FILE) then return nil end
		return HttpService:JSONDecode(readfile(CONFIG_FILE))
	end)
	if ok and type(data) == "table" then
		for key, value in pairs(data) do
			if Config[key] ~= nil and type(value) == type(Config[key]) then
				Config[key] = value
			end
		end
	end
end

local function track(connection)
	connections[#connections + 1] = connection
	return connection
end

-- ---------------------------------------------------------------- remotes

local function getRemote(name)
	local remotes = ReplicatedStorage:FindFirstChild("Remotes")
	local remote = remotes and remotes:FindFirstChild(name)
	if not remote then
		remote = ReplicatedStorage:FindFirstChild(name)
	end
	return remote
end

local function fire(name, ...)
	local remote = getRemote(name)
	if not remote then return false, name .. " missing" end
	local args = { ... }
	local ok, err = pcall(function()
		remote:FireServer(unpackArgs(args))
	end)
	return ok, err
end

local function invoke(name, ...)
	local remote = getRemote(name)
	if not remote then return false, name .. " missing" end
	local args = { ... }
	local ok, result = pcall(function()
		return remote:InvokeServer(unpackArgs(args))
	end)
	return ok, result
end

-- ---------------------------------------------------------------- helpers

local function inst(class, props, parent)
	local object = Instance.new(class)
	for key, value in pairs(props or {}) do
		if key ~= "Parent" then
			object[key] = value
		end
	end
	if parent then
		object.Parent = parent
	end
	return object
end

local function round(parent, radius)
	return inst("UICorner", { CornerRadius = UDim.new(0, radius or 6) }, parent)
end

local function outline(parent, color, thickness)
	return inst("UIStroke", {
		Color = color or Color3.fromRGB(48, 48, 64),
		Thickness = thickness or 1,
		ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
	}, parent)
end

local function teamColor(player)
	local team = player.Team
	if team then
		local name = team.Name
		if name == "Guards" then return Color3.fromRGB(74, 144, 255) end
		if name == "Inmates" then return Color3.fromRGB(255, 168, 64) end
		if name == "Criminals" then return Color3.fromRGB(255, 82, 82) end
		if name == "Neutral" then return Color3.fromRGB(176, 176, 190) end
		return team.TeamColor.Color
	end
	return Color3.fromRGB(176, 176, 190)
end

local function isHostile(player, character)
	if player.Team and player.Team.Name == "Criminals" then return true end
	if player:GetAttribute("Hostile") or player:GetAttribute("Trespassing") then return true end
	if character and (character:GetAttribute("Hostile") or character:GetAttribute("Trespassing")) then return true end
	return false
end

local function getHRP(character)
	return character and character:FindFirstChild("HumanoidRootPart")
end

local function alive(player)
	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	return character, humanoid, humanoid and humanoid.Health > 0
end

local function distanceTo(position)
	local character = LocalPlayer.Character
	local hrp = getHRP(character)
	local origin = hrp and hrp.Position or Camera.CFrame.Position
	return (position - origin).Magnitude
end

-- ---------------------------------------------------------------- ESP

local espFolder = inst("Folder", { Name = "PLR_ESP" }, Camera)

local function destroyESP(player)
	local data = espData[player]
	if not data then return end
	if data.highlight then data.highlight:Destroy() end
	if data.billboard then data.billboard:Destroy() end
	espData[player] = nil
end

local function clearESP()
	for player in pairs(espData) do
		destroyESP(player)
	end
end

local function buildESP(player)
	if player == LocalPlayer then return end
	local character, humanoid, isAlive = alive(player)
	if not isAlive then
		destroyESP(player)
		return
	end
	local head = character:FindFirstChild("Head")
	if not head then return end

	local color = Config.ESPTeamColor and teamColor(player) or Color3.fromRGB(232, 232, 242)
	local data = espData[player]
	if not data then
		local highlight = inst("Highlight", {
			Name = "PLR_Highlight",
			DepthMode = Enum.HighlightDepthMode.AlwaysOnTop,
			FillTransparency = 0.62,
			OutlineTransparency = 0,
			FillColor = color,
			OutlineColor = color:Lerp(Color3.new(1, 1, 1), 0.35),
		}, espFolder)

		local billboard = inst("BillboardGui", {
			Name = "PLR_Tag",
			Size = UDim2.fromOffset(190, 46),
			StudsOffset = Vector3.new(0, 2.4, 0),
			AlwaysOnTop = true,
			MaxDistance = Config.ESPDistance,
			LightInfluence = 0,
			Adornee = head,
		}, head)

		local holder = inst("Frame", {
			Size = UDim2.fromScale(1, 1),
			BackgroundTransparency = 1,
		}, billboard)

		local nameLabel = inst("TextLabel", {
			Size = UDim2.new(1, 0, 0, 18),
			BackgroundTransparency = 1,
			Font = FontBold,
			TextSize = 13,
			TextColor3 = Theme.text,
			TextStrokeTransparency = 0.5,
			Text = player.Name,
		}, holder)

		local infoLabel = inst("TextLabel", {
			Position = UDim2.new(0, 0, 0, 18),
			Size = UDim2.new(1, 0, 0, 14),
			BackgroundTransparency = 1,
			Font = Font,
			TextSize = 11,
			TextColor3 = Theme.sub,
			TextStrokeTransparency = 0.6,
			Text = "",
		}, holder)

		local barBack = inst("Frame", {
			Position = UDim2.new(0.5, -45, 0, 34),
			Size = UDim2.fromOffset(90, 4),
			BackgroundColor3 = Color3.fromRGB(40, 40, 54),
			BorderSizePixel = 0,
		}, holder)
		round(barBack, 2)

		local barFill = inst("Frame", {
			Size = UDim2.fromScale(1, 1),
			BackgroundColor3 = Theme.good,
			BorderSizePixel = 0,
		}, barBack)
		round(barFill, 2)

		data = {
			highlight = highlight,
			billboard = billboard,
			nameLabel = nameLabel,
			infoLabel = infoLabel,
			barBack = barBack,
			barFill = barFill,
		}
		espData[player] = data
	end

	data.highlight.Adornee = character
	data.highlight.Enabled = Config.ESP
	data.highlight.FillColor = color
	data.highlight.OutlineColor = color:Lerp(Color3.new(1, 1, 1), 0.35)
	data.billboard.Adornee = head
	data.billboard.Parent = head
	data.billboard.MaxDistance = Config.ESPDistance
	data.billboard.Enabled = Config.ESP

	local health = humanoid.Health / math.max(humanoid.MaxHealth, 1)
	data.barFill.Size = UDim2.fromScale(math.clamp(health, 0, 1), 1)
	data.barFill.BackgroundColor3 = Color3.fromRGB(255, 92, 92):Lerp(Color3.fromRGB(74, 214, 138), health)
	data.barFill.Visible = Config.ESPHealth
	data.barBack.Visible = Config.ESPHealth
	data.nameLabel.Text = player.Name
	data.infoLabel.Text = string.format("%s  •  %dm", player.Team and player.Team.Name or "No team", math.floor(distanceTo(head.Position)))
end

local function updateESP()
	if not Config.ESP then
		for _, data in pairs(espData) do
			data.highlight.Enabled = false
			data.billboard.Enabled = false
		end
		return
	end
	for _, player in ipairs(Players:GetPlayers()) do
		buildESP(player)
	end
	for player in pairs(espData) do
		if not player.Parent then
			destroyESP(player)
		end
	end
end

-- ---------------------------------------------------------------- aim assist

local function aimTarget()
	local cam = workspace.CurrentCamera
	if not cam then return nil end
	local best, bestAngle = nil, math.huge
	local origin = cam.CFrame.Position
	local look = cam.CFrame.LookVector
	for _, player in ipairs(Players:GetPlayers()) do
		if player ~= LocalPlayer then
			local character, humanoid, isAlive = alive(player)
			local head = character and character:FindFirstChild("Head")
			if head and isAlive then
				local sameTeam = Config.AimTeamCheck and player.Team and LocalPlayer.Team and player.Team == LocalPlayer.Team
				local distance = (head.Position - origin).Magnitude
				if not sameTeam and distance <= Config.AimDistance then
					local direction = (head.Position - origin).Unit
					local angle = math.deg(math.acos(math.clamp(look:Dot(direction), -1, 1)))
					if angle <= Config.AimFOV and angle < bestAngle then
						best, bestAngle = player, angle
					end
				end
			end
		end
	end
	return best
end

track(RunService.RenderStepped:Connect(function()
	if unloaded or not Config.Aim then return end
	local cam = workspace.CurrentCamera
	if not cam then return end
	local target = aimTarget()
	if not target then return end
	local character = target.Character
	local head = character and character:FindFirstChild("Head")
	if not head then return end
	local goal = CFrame.lookAt(cam.CFrame.Position, head.Position)
	local alpha = math.clamp(Config.AimStrength, 0, 1)
	cam.CFrame = cam.CFrame:Lerp(goal, alpha)
end))

-- ---------------------------------------------------------------- arrest aura

local arrestCooldown = {}

local function arrestTarget()
	local character = LocalPlayer.Character
	local hrp = getHRP(character)
	if not hrp then return nil end
	local best, bestDistance = nil, Config.ArrestRange
	for _, player in ipairs(Players:GetPlayers()) do
		if player ~= LocalPlayer then
			local otherCharacter, humanoid, isAlive = alive(player)
			local otherHRP = getHRP(otherCharacter)
			if otherHRP and isAlive then
				local distance = (otherHRP.Position - hrp.Position).Magnitude
				if distance <= bestDistance and isHostile(player, otherCharacter) then
					best, bestDistance = player, distance
				end
			end
		end
	end
	return best
end

-- ---------------------------------------------------------------- items

local TOOL_NAMES = {
	["M9"] = true, ["MP5"] = true, ["AK-47"] = true, ["M4A1"] = true,
	["Remington 870"] = true, ["Revolver"] = true, ["M700"] = true,
	["FAL"] = true, ["Taser"] = true, ["Crude Knife"] = true,
	["Hammer"] = true, ["Handcuffs"] = true, ["Riot Shield"] = true,
}

local function looksLikeGiver(object)
	if object:GetAttribute("ToolName") then return true end
	if TOOL_NAMES[object.Name] then return true end
	return false
end

local grabCooldown = {}

local function grabGivers(force)
	local remotes = ReplicatedStorage:FindFirstChild("Remotes")
	if not remotes then return 0, "Remotes folder missing" end
	local giverRemote = remotes:FindFirstChild("GiverPressed")
	local touchRemote = remotes:FindFirstChild("TouchGiver")
	if not giverRemote and not touchRemote then return 0, "Giver remotes missing" end

	local count = 0
	local now = os.clock()
	for _, object in ipairs(workspace:GetDescendants()) do
		if looksLikeGiver(object) then
			local last = grabCooldown[object]
			if force or not last or now - last > 2 then
				grabCooldown[object] = now
				count = count + 1
				if giverRemote then pcall(function() giverRemote:FireServer(object) end) end
				if touchRemote then pcall(function() touchRemote:FireServer(object) end) end
				if count >= 24 then break end
			end
		end
	end
	return count
end

local collectCooldown = {}

local function collectItems()
	local remotes = ReplicatedStorage:FindFirstChild("Remotes")
	local interact = remotes and remotes:FindFirstChild("InteractWithItem")
	if not interact then return 0, "InteractWithItem missing" end
	local now = os.clock()
	local count = 0
	for _, object in ipairs(workspace:GetDescendants()) do
		if object:IsA("Tool") then
			local last = collectCooldown[object]
			if (not last or now - last > 3) and object.Parent ~= LocalPlayer.Character then
				collectCooldown[object] = now
				count = count + 1
				pcall(function() interact:InvokeServer(object) end)
				if count >= 10 then break end
			end
		end
	end
	return count
end

-- ---------------------------------------------------------------- teleport

local function tpPoint(position)
	local remotes = ReplicatedStorage:FindFirstChild("Remotes")
	local request = remotes and remotes:FindFirstChild("RequestHere")
	if not request then return false, "RequestHere missing" end
	local ok, err = pcall(function() request:FireServer(position) end)
	return ok, err
end

local function mousePoint()
	if not UserInputService.TouchEnabled then
		local mouse = LocalPlayer:GetMouse()
		if mouse and mouse.Hit then
			return mouse.Hit.Position
		end
	end
	local cam = workspace.CurrentCamera
	if not cam then return nil end
	local ray = cam:ViewportPointToRay(cam.ViewportSize.X / 2, cam.ViewportSize.Y / 2)
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = { LocalPlayer.Character }
	local hit = workspace:Raycast(ray.Origin, ray.Direction * 800, params)
	return hit and hit.Position or nil
end

-- ---------------------------------------------------------------- fullbright

local lightingBackup

local function setFullbright(enabled)
	if enabled then
		if not lightingBackup then
			lightingBackup = {
				Brightness = Lighting.Brightness,
				ClockTime = Lighting.ClockTime,
				Ambient = Lighting.Ambient,
				OutdoorAmbient = Lighting.OutdoorAmbient,
				FogEnd = Lighting.FogEnd,
				GlobalShadows = Lighting.GlobalShadows,
			}
		end
		Lighting.Brightness = 2
		Lighting.ClockTime = 14
		Lighting.Ambient = Color3.fromRGB(150, 150, 150)
		Lighting.OutdoorAmbient = Color3.fromRGB(150, 150, 150)
		Lighting.FogEnd = 100000
		Lighting.GlobalShadows = false
	elseif lightingBackup then
		for key, value in pairs(lightingBackup) do
			Lighting[key] = value
		end
		lightingBackup = nil
	end
end

-- ---------------------------------------------------------------- UI

loadConfig()

if getgenv and getgenv().PL_Research_Unload then
	pcall(getgenv().PL_Research_Unload)
end

local oldGui = LocalPlayer:FindFirstChild("PlayerGui") and LocalPlayer.PlayerGui:FindFirstChild("PL_Research")
if oldGui then oldGui:Destroy() end

local gui = inst("ScreenGui", {
	Name = "PL_Research",
	ResetOnSpawn = false,
	DisplayOrder = 900,
	IgnoreGuiInset = true,
	ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
}, LocalPlayer:WaitForChild("PlayerGui"))

local window = inst("Frame", {
	Name = "Window",
	Size = UDim2.fromOffset(468, 332),
	Position = UDim2.new(0.5, 0, 0.5, 0),
	AnchorPoint = Vector2.new(0.5, 0.5),
	BackgroundColor3 = Theme.window,
	BorderSizePixel = 0,
	ClipsDescendants = true,
}, gui)
local scale = inst("UIScale", {}, window)
round(window, 10)
outline(window, Color3.fromRGB(52, 52, 72), 1)

local topbar = inst("Frame", {
	Size = UDim2.new(1, 0, 0, 36),
	BackgroundColor3 = Theme.panel,
	BorderSizePixel = 0,
}, window)

inst("Frame", {
	Size = UDim2.new(1, 0, 0, 1),
	Position = UDim2.new(0, 0, 1, -1),
	BackgroundColor3 = Color3.fromRGB(44, 44, 60),
	BorderSizePixel = 0,
}, topbar)

local title = inst("TextLabel", {
	Position = UDim2.fromOffset(14, 5),
	Size = UDim2.new(1, -120, 0, 15),
	BackgroundTransparency = 1,
	Font = FontBold,
	TextSize = 13,
	TextColor3 = Theme.text,
	TextXAlignment = Enum.TextXAlignment.Left,
	Text = "PRISON LIFE  •  " .. VERSION,
}, topbar)

local subtitle = inst("TextLabel", {
	Position = UDim2.fromOffset(14, 20),
	Size = UDim2.new(1, -120, 0, 12),
	BackgroundTransparency = 1,
	Font = Font,
	TextSize = 9,
	TextColor3 = Theme.sub,
	TextXAlignment = Enum.TextXAlignment.Left,
	Text = "built from the deobfuscated client API",
}, topbar)

local function topButton(text, x, color, callback)
	local button = inst("TextButton", {
		Position = UDim2.new(1, x, 0, 6),
		Size = UDim2.fromOffset(24, 24),
		BackgroundColor3 = color,
		BorderSizePixel = 0,
		Font = FontBold,
		TextSize = 14,
		TextColor3 = Theme.text,
		Text = text,
		AutoButtonColor = false,
	}, topbar)
	round(button, 6)
	button.MouseButton1Click:Connect(callback)
	return button
end

local minimized = false

local body = inst("Frame", {
	Position = UDim2.fromOffset(0, 36),
	Size = UDim2.new(1, 0, 1, -36),
	BackgroundTransparency = 1,
}, window)

local sidebar = inst("Frame", {
	Size = UDim2.new(0, 118, 1, 0),
	BackgroundColor3 = Theme.panel,
	BorderSizePixel = 0,
}, body)

local tabList = inst("Frame", {
	Position = UDim2.fromOffset(8, 10),
	Size = UDim2.new(1, -16, 1, -20),
	BackgroundTransparency = 1,
}, sidebar)
inst("UIListLayout", {
	Padding = UDim.new(0, 6),
	SortOrder = Enum.SortOrder.LayoutOrder,
}, tabList)

local content = inst("Frame", {
	Position = UDim2.fromOffset(118, 0),
	Size = UDim2.new(1, -118, 1, 0),
	BackgroundTransparency = 1,
}, body)

local pages = {}

local function makePage(name, order)
	local page = inst("ScrollingFrame", {
		Name = name,
		Size = UDim2.fromScale(1, 1),
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		ScrollBarThickness = 2,
		ScrollBarImageColor3 = Theme.accent,
		CanvasSize = UDim2.new(0, 0, 0, 0),
		AutomaticCanvasSize = Enum.AutomaticSize.Y,
		ScrollingDirection = Enum.ScrollingDirection.Y,
		Visible = false,
	}, content)
	local pad = inst("UIPadding", {
		PaddingTop = UDim.new(0, 10),
		PaddingBottom = UDim.new(0, 14),
		PaddingLeft = UDim.new(0, 12),
		PaddingRight = UDim.new(0, 12),
	}, page)
	local layout = inst("UIListLayout", {
		Padding = UDim.new(0, 5),
		SortOrder = Enum.SortOrder.LayoutOrder,
	}, page)
	page.LayoutOrder = order
	pages[name] = page
	return page
end

local function makeTab(name)
	local button = inst("TextButton", {
		Size = UDim2.new(1, 0, 0, 32),
		BackgroundColor3 = Theme.row,
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		Font = FontBold,
		TextSize = 12,
		TextColor3 = Theme.sub,
		TextXAlignment = Enum.TextXAlignment.Left,
		Text = "  " .. name,
		AutoButtonColor = false,
	}, tabList)
	round(button, 6)
	button.MouseButton1Click:Connect(function()
		for pageName, page in pairs(pages) do
			page.Visible = pageName == name
		end
		for _, other in ipairs(tabList:GetChildren()) do
			if other:IsA("TextButton") then
				other.TextColor3 = other == button and Theme.text or Theme.sub
				other.BackgroundTransparency = other == button and 0 or 1
			end
		end
	end)
	return button
end

local function section(parent, text)
	local label = inst("TextLabel", {
		Size = UDim2.new(1, 0, 0, 18),
		BackgroundTransparency = 1,
		Font = FontBold,
		TextSize = 10,
		TextColor3 = Theme.accent,
		TextXAlignment = Enum.TextXAlignment.Left,
		Text = string.upper(text),
	}, parent)
	return label
end

local function row(parent, height)
	return inst("Frame", {
		Size = UDim2.new(1, 0, 0, height or 32),
		BackgroundColor3 = Theme.row,
		BorderSizePixel = 0,
	}, parent)
end

local function addToggle(parent, label, key, callback)
	local holder = row(parent)
	round(holder, 6)
	inst("TextLabel", {
		Position = UDim2.fromOffset(10, 0),
		Size = UDim2.new(1, -58, 1, 0),
		BackgroundTransparency = 1,
		Font = Font,
		TextSize = 12,
		TextColor3 = Theme.text,
		TextXAlignment = Enum.TextXAlignment.Left,
		Text = label,
	}, holder)
	local switch = inst("Frame", {
		Position = UDim2.new(1, -46, 0.5, -9),
		Size = UDim2.fromOffset(36, 18),
		BackgroundColor3 = Theme.off,
		BorderSizePixel = 0,
	}, holder)
	round(switch, 9)
	local knob = inst("Frame", {
		Position = UDim2.fromOffset(2, 2),
		Size = UDim2.fromOffset(14, 14),
		BackgroundColor3 = Theme.text,
		BorderSizePixel = 0,
	}, switch)
	round(knob, 7)
	local click = inst("TextButton", {
		Size = UDim2.fromScale(1, 1),
		BackgroundTransparency = 1,
		Text = "",
	}, holder)

	local function render()
		local on = Config[key] and true or false
		TweenService:Create(switch, TweenInfo.new(0.14), { BackgroundColor3 = on and Theme.accent or Theme.off }):Play()
		TweenService:Create(knob, TweenInfo.new(0.14), {
			Position = on and UDim2.new(1, -16, 0.5, -7) or UDim2.fromOffset(2, 2),
		}):Play()
	end

	click.MouseButton1Click:Connect(function()
		Config[key] = not Config[key]
		render()
		saveConfig()
		if callback then callback(Config[key]) end
	end)
	render()
	return holder
end

local function addButton(parent, label, callback, color)
	local button = inst("TextButton", {
		Size = UDim2.new(1, 0, 0, 30),
		BackgroundColor3 = color or Theme.row,
		BorderSizePixel = 0,
		Font = FontBold,
		TextSize = 11,
		TextColor3 = Theme.text,
		Text = label,
		AutoButtonColor = false,
	}, parent)
	round(button, 6)
	local press = button.MouseButton1Down:Connect(function()
		TweenService:Create(button, TweenInfo.new(0.08), { BackgroundColor3 = Theme.accentDark }):Play()
	end)
	local release = button.MouseButton1Up:Connect(function()
		TweenService:Create(button, TweenInfo.new(0.15), { BackgroundColor3 = color or Theme.row }):Play()
	end)
	button.MouseLeave:Connect(function()
		TweenService:Create(button, TweenInfo.new(0.15), { BackgroundColor3 = color or Theme.row }):Play()
	end)
	button.MouseButton1Click:Connect(function()
		local ok, err = pcall(callback)
		if not ok and notify then notify("error", tostring(err)) end
	end)
	return button, press, release
end

local function addSlider(parent, label, key, minimum, maximum, step, suffix, callback)
	local holder = row(parent, 42)
	round(holder, 6)
	local text = inst("TextLabel", {
		Position = UDim2.fromOffset(10, 4),
		Size = UDim2.new(1, -80, 0, 16),
		BackgroundTransparency = 1,
		Font = Font,
		TextSize = 11,
		TextColor3 = Theme.text,
		TextXAlignment = Enum.TextXAlignment.Left,
		Text = label,
	}, holder)
	local value = inst("TextLabel", {
		Position = UDim2.new(1, -70, 0, 4),
		Size = UDim2.fromOffset(60, 16),
		BackgroundTransparency = 1,
		Font = FontBold,
		TextSize = 10,
		TextColor3 = Theme.sub,
		TextXAlignment = Enum.TextXAlignment.Right,
		Text = tostring(Config[key]) .. (suffix or ""),
	}, holder)
	local bar = inst("Frame", {
		Position = UDim2.new(0, 10, 0, 26),
		Size = UDim2.new(1, -20, 0, 5),
		BackgroundColor3 = Theme.off,
		BorderSizePixel = 0,
	}, holder)
	round(bar, 3)
	local fill = inst("Frame", {
		Size = UDim2.fromScale(math.clamp((Config[key] - minimum) / (maximum - minimum), 0, 1), 1),
		BackgroundColor3 = Theme.accent,
		BorderSizePixel = 0,
	}, bar)
	round(fill, 3)
	local knob = inst("Frame", {
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.new(1, 0, 0.5, 0),
		Size = UDim2.fromOffset(12, 12),
		BackgroundColor3 = Theme.text,
		BorderSizePixel = 0,
		ZIndex = 2,
	}, bar)
	round(knob, 6)

	local hitbox = inst("TextButton", {
		Position = UDim2.new(0, 0, 0, 18),
		Size = UDim2.new(1, 0, 0, 20),
		BackgroundTransparency = 1,
		Text = "",
	}, holder)

	local dragging = false

	local function apply(input)
		local relative = math.clamp((input.Position.X - bar.AbsolutePosition.X) / math.max(bar.AbsoluteSize.X, 1), 0, 1)
		local raw = minimum + (maximum - minimum) * relative
		if step and step > 0 then
			raw = math.floor((raw / step) + 0.5) * step
		end
		raw = math.clamp(raw, minimum, maximum)
		Config[key] = raw
		fill.Size = UDim2.fromScale(relative, 1)
		knob.Position = UDim2.new(relative, 0, 0.5, 0)
		local shown = (step and step < 1) and string.format("%.1f", raw) or tostring(math.floor(raw + 0.5))
		value.Text = shown .. (suffix or "")
		if callback then callback(raw) end
	end

	hitbox.InputBegan:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
			dragging = true
			apply(input)
		end
	end)
	track(UserInputService.InputChanged:Connect(function(input)
		if dragging and (input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch) then
			apply(input)
		end
	end))
	track(UserInputService.InputEnded:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
			if dragging then
				dragging = false
				saveConfig()
			end
		end
	end))
	return holder
end

local function addDropdown(parent, label, options, getValue, setValue)
	local holder = row(parent)
	round(holder, 6)
	inst("TextLabel", {
		Position = UDim2.fromOffset(10, 0),
		Size = UDim2.new(1, -110, 1, 0),
		BackgroundTransparency = 1,
		Font = Font,
		TextSize = 12,
		TextColor3 = Theme.text,
		TextXAlignment = Enum.TextXAlignment.Left,
		Text = label,
	}, holder)
	local value = inst("TextButton", {
		Position = UDim2.new(1, -96, 0.5, -11),
		Size = UDim2.fromOffset(86, 22),
		BackgroundColor3 = Theme.panel,
		BorderSizePixel = 0,
		Font = FontBold,
		TextSize = 10,
		TextColor3 = Theme.text,
		Text = tostring(getValue()),
		AutoButtonColor = false,
	}, holder)
	round(value, 5)
	outline(value, Color3.fromRGB(58, 58, 78))
	value.MouseButton1Click:Connect(function()
		local current = tostring(getValue())
		local index = 1
		for position, option in ipairs(options) do
			if tostring(option) == current then index = position break end
		end
		local nextOption = options[(index % #options) + 1]
		setValue(nextOption)
		value.Text = tostring(nextOption)
		saveConfig()
	end)
	return holder
end

-- ---------------------------------------------------------------- tabs

makePage("Visuals", 1)
makePage("Player", 2)
makePage("Items", 3)
makePage("Misc", 4)

makeTab("Visuals")
makeTab("Player")
makeTab("Items")
makeTab("Misc")

for _, tab in ipairs(tabList:GetChildren()) do
	if tab:IsA("TextButton") then
		tab.MouseButton1Click:Connect(function()
			for _, other in ipairs(tabList:GetChildren()) do
				if other:IsA("TextButton") then
					other.BackgroundTransparency = other == tab and 0 or 1
					other.TextColor3 = other == tab and Theme.text or Theme.sub
				end
			end
		end)
	end
end

-- open the first tab so the window is not blank on load
local firstTab
for _, child in ipairs(tabList:GetChildren()) do
	if child:IsA("TextButton") then
		firstTab = firstTab or child
	end
end
if firstTab then
	firstTab.BackgroundTransparency = 0
	firstTab.TextColor3 = Theme.text
end
pages.Visuals.Visible = true

-- Visuals page
local visuals = pages.Visuals
section(visuals, "ESP")
addToggle(visuals, "Enable ESP", "ESP", function(on)
	if not on then clearESP() end
end)
addToggle(visuals, "Team-coloured highlights", "ESPTeamColor")
addToggle(visuals, "Show health bar", "ESPHealth")
addSlider(visuals, "Max distance", "ESPDistance", 100, 2000, 50, "m", function()
	for _, data in pairs(espData) do
		data.billboard.MaxDistance = Config.ESPDistance
	end
end)

section(visuals, "Camera")
addToggle(visuals, "Camera aim assist", "Aim")
addToggle(visuals, "Skip teammates", "AimTeamCheck")
addSlider(visuals, "Field of view", "AimFOV", 10, 180, 5, "°")
addSlider(visuals, "Assist strength", "AimStrength", 0.05, 1, 0.05, "", nil)
addSlider(visuals, "Max target distance", "AimDistance", 50, 1000, 25, "m")

-- Player page
local playerPage = pages.Player
section(playerPage, "Team")
local selectedTeam = "Guards"
addDropdown(playerPage, "Select team", { "Guards", "Inmates", "Criminals", "Neutral" }, function()
	return selectedTeam
end, function(value)
	selectedTeam = value
end)
addButton(playerPage, "Join selected team", function()
	local request = getRemote("RequestTeamChange")
	if not request then
		notify("error", "RequestTeamChange not found")
		return
	end
	local ok, err = pcall(function() request:InvokeServer(selectedTeam) end)
	notify(ok and "ok" or "error", ok and ("Requested " .. selectedTeam) or tostring(err))
end)

section(playerPage, "Arrest")
addToggle(playerPage, "Auto-arrest hostiles", "Arrest", function(on)
	if on then notify("info", "Guards only — server validates") end
end)
addSlider(playerPage, "Arrest range", "ArrestRange", 5, 60, 1, "m")

section(playerPage, "Movement")
addButton(playerPage, "Teleport to cursor", function()
	local point = mousePoint()
	if not point then notify("error", "No ground target") return end
	local ok, err = tpPoint(point)
	notify(ok and "ok" or "error", ok and "Teleport requested" or tostring(err))
end)
addButton(playerPage, "Teleport behind nearest player", function()
	local nearest, best = nil, math.huge
	local myHRP = getHRP(LocalPlayer.Character)
	if not myHRP then notify("error", "No character") return end
	for _, player in ipairs(Players:GetPlayers()) do
		if player ~= LocalPlayer then
			local character, _, isAlive = alive(player)
			local hrp = getHRP(character)
			if hrp and isAlive then
				local d = (hrp.Position - myHRP.Position).Magnitude
				if d < best then nearest, best = hrp, d end
			end
		end
	end
	if not nearest then notify("error", "No target") return end
	local behind = nearest.CFrame * CFrame.new(0, 0, 3)
	local ok, err = tpPoint(behind.Position)
	notify(ok and "ok" or "error", ok and "Teleport requested" or tostring(err))
end)

local playerList = inst("ScrollingFrame", {
	Size = UDim2.new(1, 0, 0, 96),
	BackgroundColor3 = Theme.row,
	BorderSizePixel = 0,
	ScrollBarThickness = 2,
	CanvasSize = UDim2.new(0, 0, 0, 0),
	AutomaticCanvasSize = Enum.AutomaticSize.Y,
}, playerPage)
round(playerList, 6)
local playerLayout = inst("UIListLayout", { Padding = UDim.new(0, 2) }, playerList)
local playerPad = inst("UIPadding", {
	PaddingTop = UDim.new(0, 4), PaddingBottom = UDim.new(0, 4),
	PaddingLeft = UDim.new(0, 4), PaddingRight = UDim.new(0, 4),
}, playerList)

local function refreshPlayerList()
	for _, child in ipairs(playerList:GetChildren()) do
		if child:IsA("TextButton") then child:Destroy() end
	end
	for _, player in ipairs(Players:GetPlayers()) do
		if player ~= LocalPlayer then
			local button = inst("TextButton", {
				Size = UDim2.new(1, 0, 0, 24),
				BackgroundColor3 = Theme.panel,
				BorderSizePixel = 0,
				Font = Font,
				TextSize = 10,
				TextColor3 = Theme.text,
				TextXAlignment = Enum.TextXAlignment.Left,
				Text = "  " .. player.Name .. "  (" .. (player.Team and player.Team.Name or "?") .. ")",
				AutoButtonColor = false,
			}, playerList)
			round(button, 4)
			button.MouseButton1Click:Connect(function()
				local hrp = getHRP(player.Character)
				if not hrp then notify("error", "Target has no character") return end
				local ok, err = tpPoint(hrp.Position)
				notify(ok and "ok" or "error", ok and ("Teleport to " .. player.Name) or tostring(err))
			end)
		end
	end
end
refreshPlayerList()

-- Items page
local items = pages.Items
section(items, "Givers")
addToggle(items, "Auto-grab givers", "AutoGrab")
addToggle(items, "Auto-collect tools", "AutoCollect")
addButton(items, "Grab givers now", function()
	local count, err = grabGivers(true)
	if count and count > 0 then
		notify("ok", "Fired at " .. count .. " givers")
	elseif err then
		notify("error", tostring(err))
	else
		notify("info", "No givers in range")
	end
end)
addButton(items, "Collect nearby tools", function()
	local count, err = collectItems()
	if count and count > 0 then
		notify("ok", "Interacted with " .. count .. " tools")
	elseif err then
		notify("error", tostring(err))
	else
		notify("info", "No tools found")
	end
end)

section(items, "Settings")
addButton(items, "Read player settings", function()
	local ok, result = invoke("GetSettings")
	if ok then
		local text = type(result) == "table" and HttpService:JSONEncode(result) or tostring(result)
		notify("info", "Settings: " .. text:sub(1, 120))
	else
		notify("error", tostring(result))
	end
end)

-- Misc page
local misc = pages.Misc
section(misc, "Client")
addToggle(misc, "Anti-AFK", "AntiAFK")
addToggle(misc, "Fullbright", "Fullbright", function(on)
	setFullbright(on)
end)
addButton(misc, "Rejoin server", function()
	TeleportService:Teleport(PLACE_ID, LocalPlayer)
end)
addButton(misc, "Copy place link", function()
	local link = "https://www.roblox.com/games/" .. PLACE_ID
	if setclipboard then
		setclipboard(link)
		notify("ok", "Copied game link")
	else
		notify("info", link)
	end
end)

section(misc, "About")
inst("TextLabel", {
	Size = UDim2.new(1, 0, 0, 54),
	BackgroundTransparency = 1,
	Font = Font,
	TextSize = 10,
	TextWrapped = true,
	TextColor3 = Theme.sub,
	TextXAlignment = Enum.TextXAlignment.Left,
	TextYAlignment = Enum.TextYAlignment.Top,
	Text = "Remotes come from docs/PrisonLife-Deobfuscated-API.md. Argument shapes are inferred; the server may reject any call. Client-side features do not touch the server.",
}, misc)

-- ---------------------------------------------------------------- notifications

local toastHolder = inst("Frame", {
	Position = UDim2.new(0.5, 0, 1, -46),
	Size = UDim2.fromOffset(300, 28),
	AnchorPoint = Vector2.new(0.5, 0),
	BackgroundTransparency = 1,
}, window)

local toast = inst("TextLabel", {
	Size = UDim2.fromScale(1, 1),
	BackgroundColor3 = Theme.row,
	Font = FontBold,
	TextSize = 10,
	TextColor3 = Theme.text,
	Text = "",
	Visible = false,
}, toastHolder)
round(toast, 6)

local toastToken = 0

notify = function(kind, message)
	toastToken = toastToken + 1
	local token = toastToken
	toast.Text = "  " .. tostring(message)
	if kind == "error" then
		toast.BackgroundColor3 = Theme.danger
		toast.TextColor3 = Color3.fromRGB(22, 22, 28)
	elseif kind == "ok" then
		toast.BackgroundColor3 = Theme.good
		toast.TextColor3 = Color3.fromRGB(10, 10, 16)
	else
		toast.BackgroundColor3 = Theme.row
		toast.TextColor3 = Theme.text
	end
	toast.Visible = true
	task.delay(2.2, function()
		if toastToken == token then
			toast.Visible = false
		end
	end)
end

-- ---------------------------------------------------------------- window chrome

local function toggleMinimize()
	minimized = not minimized
	body.Visible = not minimized
	window.Size = minimized and UDim2.fromOffset(468, 36) or UDim2.fromOffset(468, 332)
end

topButton("−", -54, Theme.row, toggleMinimize)
local closeButton = topButton("×", -30, Theme.danger, function()
	if getgenv and getgenv().PL_Research_Unload then
		getgenv().PL_Research_Unload()
	else
		gui:Destroy()
	end
end)
closeButton.TextColor3 = Color3.fromRGB(20, 20, 28)

-- dragging (mouse + touch)
local dragging, dragStart, startPosition

topbar.InputBegan:Connect(function(input)
	if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
		dragging = true
		dragStart = input.Position
		startPosition = window.Position
	end
end)
track(UserInputService.InputChanged:Connect(function(input)
	if dragging and (input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch) then
		local delta = input.Position - dragStart
		window.Position = UDim2.new(
			startPosition.X.Scale, startPosition.X.Offset + delta.X,
			startPosition.Y.Scale, startPosition.Y.Offset + delta.Y
		)
	end
end))
track(UserInputService.InputEnded:Connect(function(input)
	if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
		dragging = false
	end
end))

local function fitScale()
	local cam = workspace.CurrentCamera
	if not cam then return end
	local viewport = cam.ViewportSize
	local factor = math.min(viewport.X / 500, viewport.Y / 380)
	scale.Scale = math.clamp(factor, 0.62, 1)
end
local function watchCamera()
	local cam = workspace.CurrentCamera
	if cam then
		track(cam:GetPropertyChangedSignal("ViewportSize"):Connect(fitScale))
	end
	fitScale()
end
watchCamera()
track(workspace:GetPropertyChangedSignal("CurrentCamera"):Connect(watchCamera))

-- ---------------------------------------------------------------- loops

task.spawn(function()
	while not unloaded do
		updateESP()
		task.wait(0.25)
	end
end)

task.spawn(function()
	while not unloaded do
		task.wait(2)
		if Config.AutoGrab then
			grabGivers()
		end
		if Config.AutoCollect then
			collectItems()
		end
	end
end)

task.spawn(function()
	while not unloaded do
		task.wait(0.6)
		if Config.Arrest then
			local target = arrestTarget()
			if target then
				local now = os.clock()
				local last = arrestCooldown[target]
				if not last or now - last > 2 then
					arrestCooldown[target] = now
					local remote = getRemote("ArrestPlayer")
					if remote then pcall(function() remote:FireServer(target) end) end
				end
			end
		end
	end
end)

task.spawn(function()
	while not unloaded do
		task.wait(2)
		if pages.Player.Visible then
			refreshPlayerList()
		end
	end
end)

-- anti-AFK
track(LocalPlayer.Idled:Connect(function()
	if not Config.AntiAFK then return end
	VirtualUser:CaptureController()
	VirtualUser:ClickButton2(Vector2.new())
end))

-- character hooks
track(LocalPlayer.CharacterAdded:Connect(function()
	task.wait(1)
	clearESP()
end))
track(Players.PlayerRemoving:Connect(function(player)
	destroyESP(player)
end))

for _, player in ipairs(Players:GetPlayers()) do
	if player ~= LocalPlayer then
		track(player.CharacterAdded:Connect(function()
			task.wait(0.5)
			if Config.ESP then buildESP(player) end
		end))
		track(player.CharacterRemoving:Connect(function()
			destroyESP(player)
		end))
	end
end
track(Players.PlayerAdded:Connect(function(player)
	track(player.CharacterAdded:Connect(function()
		task.wait(0.5)
		if Config.ESP then buildESP(player) end
	end))
	track(player.CharacterRemoving:Connect(function()
		destroyESP(player)
	end))
end))

-- initial state
setFullbright(Config.Fullbright)
refreshPlayerList()

-- ---------------------------------------------------------------- unload

local function unload()
	if unloaded then return end
	unloaded = true
	for _, connection in ipairs(connections) do
		pcall(function() connection:Disconnect() end)
	end
	clearESP()
	setFullbright(false)
	if espFolder then espFolder:Destroy() end
	if toastHolder then toastHolder:Destroy() end
	if gui then gui:Destroy() end
	if getgenv then
		getgenv().PL_Research_Unload = nil
	end
end

if getgenv then
	getgenv().PL_Research_Unload = unload
end
