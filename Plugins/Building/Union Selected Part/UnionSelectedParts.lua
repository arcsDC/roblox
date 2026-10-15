local Selection = game:GetService("Selection")
local ChangeHistoryService = game:GetService("ChangeHistoryService")

if typeof(plugin) ~= "Instance" then
	warn("Union Selected: this script must run as a Roblox Studio plugin.")
	return
end

local toolbar = plugin:CreateToolbar("Build Tools")
local unionButton = toolbar:CreateButton(
	"Union Selected",
	"Union selected CSG-compatible parts, or all CSG-compatible parts inside selected models and folders.",
	"rbxasset://textures/StudioToolbox/AssetConfigPackage.png"
)
unionButton.ClickableWhenViewportHidden = true

local weldButton = toolbar:CreateButton(
	"Weld Constraint Tool",
	"Weld all parts inside the current selection, including MeshParts inside selected models.",
	"rbxasset://textures/StudioToolbox/Weld.png"
)
weldButton.ClickableWhenViewportHidden = true

local function isPart(instance)
	if not instance:IsA("BasePart") then
		return false
	end

	return not instance:IsA("Terrain")
end

local function canUnion(instance)
	if not isPart(instance) then
		return false
	end

	return instance:IsA("Part") or instance:IsA("UnionOperation") or instance:IsA("NegateOperation") or instance:IsA("WedgePart") or instance:IsA("CornerWedgePart")
end

local function collectParts(root, predicate)
	local parts = {}
	local seen = {}

	local function add(instance)
		if predicate(instance) and instance.Parent and not seen[instance] then
			seen[instance] = true
			table.insert(parts, instance)
		end
	end

	add(root)

	for _, descendant in ipairs(root:GetDescendants()) do
		add(descendant)
	end

	return parts
end

local function dedupeParts(parts, predicate)
	local uniqueParts = {}
	local seen = {}

	for _, part in ipairs(parts) do
		if predicate(part) and part.Parent and not seen[part] then
			seen[part] = true
			table.insert(uniqueParts, part)
		end
	end

	return uniqueParts
end

local function tryCopyProperty(source, target, propertyName)
	local ok, value = pcall(function()
		return source[propertyName]
	end)

	if ok then
		pcall(function()
			target[propertyName] = value
		end)
	end
end

local function copyPartProperties(source, target)
	local properties = {
		"Anchored",
		"CanCollide",
		"CanTouch",
		"CanQuery",
		"CastShadow",
		"Locked",
		"Material",
		"MaterialVariant",
		"Color",
		"BrickColor",
		"Transparency",
		"Reflectance",
		"UsePartColor",
		"CustomPhysicalProperties",
		"CollisionGroup",
		"CollisionGroupId",
	}

	for _, propertyName in ipairs(properties) do
		tryCopyProperty(source, target, propertyName)
	end
end

local function getCommonParent(parts)
	local parent = parts[1] and parts[1].Parent

	for index = 2, #parts do
		if parts[index].Parent ~= parent then
			return workspace
		end
	end

	return parent or workspace
end

local function getTargetParent(selected, parts)
	if #selected == 1 then
		local root = selected[1]

		if root:IsA("Model") or root:IsA("Folder") then
			return root
		end

		if not root:IsA("BasePart") and root.Parent then
			return root
		end
	end

	return getCommonParent(parts)
end

local function unionParts(parts, name, targetParent)
	parts = dedupeParts(parts, canUnion)

	if #parts < 2 then
		warn(("Union Selected: %s needs at least 2 CSG-compatible parts. MeshParts cannot become CSG unions in Roblox; use the welded assembly fallback instead."):format(name))
		return nil
	end

	local firstPart = parts[1]
	local otherParts = {}

	for index = 2, #parts do
		table.insert(otherParts, parts[index])
	end

	local ok, result = pcall(function()
		return firstPart:UnionAsync(otherParts)
	end)

	if not ok then
		warn(("Union Selected: failed to union %s: %s"):format(name, tostring(result)))
		return nil
	end

	result.Name = name .. "_Union"
	copyPartProperties(firstPart, result)
	result.Parent = targetParent or getCommonParent(parts)

	for _, part in ipairs(parts) do
		if part and part.Parent then
			part:Destroy()
		end
	end

	return result
end

local function containsNonUnionParts(parts)
	for _, part in ipairs(parts) do
		if isPart(part) and not canUnion(part) then
			return true
		end
	end

	return false
end

local function chooseWeldRoot(selected, parts)
	if #selected == 1 and selected[1]:IsA("Model") then
		local primaryPart = selected[1].PrimaryPart

		if primaryPart and isPart(primaryPart) then
			for _, part in ipairs(parts) do
				if part == primaryPart then
					return primaryPart
				end
			end
		end
	end

	return parts[1]
end

local function hasWeldBetween(part0, part1)
	for _, child in ipairs(part0:GetChildren()) do
		if child:IsA("WeldConstraint") then
			local childPart0 = child.Part0
			local childPart1 = child.Part1

			if (childPart0 == part0 and childPart1 == part1) or (childPart0 == part1 and childPart1 == part0) then
				return true
			end
		end
	end

	for _, child in ipairs(part1:GetChildren()) do
		if child:IsA("WeldConstraint") then
			local childPart0 = child.Part0
			local childPart1 = child.Part1

			if (childPart0 == part0 and childPart1 == part1) or (childPart0 == part1 and childPart1 == part0) then
				return true
			end
		end
	end

	return false
end

local function weldParts(parts, name, rootPart)
	parts = dedupeParts(parts, isPart)

	if #parts < 2 then
		warn(("Weld Constraint Tool: %s needs at least 2 parts."):format(name))
		return nil
	end

	rootPart = rootPart or parts[1]

	for _, part in ipairs(parts) do
		if part ~= rootPart and not hasWeldBetween(rootPart, part) then
			local weld = Instance.new("WeldConstraint")
			weld.Name = rootPart.Name .. "_To_" .. part.Name
			weld.Part0 = rootPart
			weld.Part1 = part
			weld.Parent = rootPart
		end
	end

	return rootPart
end

local function assembleParts(parts, name, targetParent, rootPart)
	parts = dedupeParts(parts, isPart)

	if #parts < 2 then
		warn(("Union Selected: %s needs at least 2 parts to create a welded assembly."):format(name))
		return nil
	end

	local model = Instance.new("Model")
	model.Name = name .. "_MeshAssembly"
	model.Parent = targetParent or getCommonParent(parts)

	rootPart = rootPart or parts[1]

	for _, part in ipairs(parts) do
		part.Parent = model
	end

	model.PrimaryPart = rootPart
	weldParts(parts, name, rootPart)

	return model
end

unionButton.Click:Connect(function()
	local selected = Selection:Get()

	if #selected == 0 then
		warn("Union Selected: select parts, models, folders, or containers first.")
		return
	end

	ChangeHistoryService:SetWaypoint("Before Union Selected")

	local selectedParts = {}
	local csgParts = {}

	for _, instance in ipairs(selected) do
		for _, part in ipairs(collectParts(instance, isPart)) do
			table.insert(selectedParts, part)

			if canUnion(part) then
				table.insert(csgParts, part)
			end
		end
	end

	local unionName = #selected == 1 and selected[1].Name or "SelectedParts"
	local targetParent = getTargetParent(selected, selectedParts)
	local union = nil

	if containsNonUnionParts(selectedParts) then
		warn("Union Selected: Roblox cannot CSG-union MeshParts. Created a welded model assembly instead.")
		union = assembleParts(selectedParts, unionName, targetParent, chooseWeldRoot(selected, selectedParts))
	else
		union = unionParts(csgParts, unionName, targetParent)
	end

	if union then
		Selection:Set({ union })
	end

	ChangeHistoryService:SetWaypoint("After Union Selected")
end)

weldButton.Click:Connect(function()
	local selected = Selection:Get()

	if #selected == 0 then
		warn("Weld Constraint Tool: select parts, models, folders, or containers first.")
		return
	end

	ChangeHistoryService:SetWaypoint("Before Weld Constraint Tool")

	local selectedParts = {}

	for _, instance in ipairs(selected) do
		for _, part in ipairs(collectParts(instance, isPart)) do
			table.insert(selectedParts, part)
		end
	end

	selectedParts = dedupeParts(selectedParts, isPart)

	local weldName = #selected == 1 and selected[1].Name or "SelectedParts"
	local rootPart = chooseWeldRoot(selected, selectedParts)
	local weldedRoot = weldParts(selectedParts, weldName, rootPart)

	if weldedRoot then
		Selection:Set({ weldedRoot })

		if #selected == 1 and selected[1]:IsA("Model") and not selected[1].PrimaryPart then
			selected[1].PrimaryPart = weldedRoot
		end
	end

	ChangeHistoryService:SetWaypoint("After Weld Constraint Tool")
end)
