--[[ Annotations ]]
---@alias NavConnection { count: integer, connections: integer[] }
---@alias NavNode { id: integer, x: number, y: number, z: number, c: { [1]: NavConnection, [2]: NavConnection, [3]: NavConnection, [4]: NavConnection } }

--[[ Imports ]]
local Common = require("Lmaobot.Common")
local Navigation = require("Lmaobot.Navigation")
local Lib = Common.Lib

-- Unload package for debugging
Lib.Utils.UnloadPackages("Lmaobot")

local Notify, FS, Fonts, Commands, Timer = Lib.UI.Notify, Lib.Utils.FileSystem, Lib.UI.Fonts, Lib.Utils.Commands, Lib.Utils.Timer
local Log = Lib.Utils.Logger.new("Lmaobot")
Log.Level = 0

--[[ Variables ]]

local options = {
    memoryUsage = true,
    drawNodes = false,
    drawPath = false,
    drawCurrentNode = true,
    autoPath = true,
}

local repathTimer = Timer.new()
local currentNodeIndex = 1
local currentNodeTicks = 0

--[[ Functions ]]

-- Loads the nav file of the current map
local function LoadNavFile()
    local mapFile = engine.GetMapName()
    local navFile = string.gsub(mapFile, ".bsp", ".nav")

    Navigation.LoadFile(navFile)
end

--[[ Callbacks ]]

local function OnDraw()
    draw.SetFont(Fonts.Verdana)
    draw.Color(255, 0, 0, 255)

    local me = entities.GetLocalPlayer()
    if not me then return end

    local myPos = me:GetAbsOrigin()
    local currentPath = Navigation.GetCurrentPath()
    local currentY = 120

    -- Memory usage
    if options.memoryUsage then
        local memUsage = collectgarbage("count")
        draw.Text(20, currentY, string.format("Memory usage: %.2f MB", memUsage / 1024))
        currentY = currentY + 20
    end

    -- Auto path informaton
    if options.autoPath then
        draw.Text(20, currentY, string.format("Current Node: %d", currentNodeIndex))
        currentY = currentY + 20
    end

    -- Draw all nodes
    if options.drawNodes then
        draw.Color(0, 255, 0, 255)

        local navNodes = Navigation.GetNodes()
        for id, node in pairs(navNodes) do
            local nodePos = Vector3(node.x, node.y, node.z)
            local dist = (myPos - nodePos):Length()
            if dist > 700 then goto continue end

            local screenPos = client.WorldToScreen(nodePos)
            if not screenPos then goto continue end

            -- Node IDs
            draw.Text(screenPos[1], screenPos[2], tostring(id))

            ::continue::
        end
    end

    -- Draw current path
    if options.drawPath and currentPath then
        draw.Color(255, 255, 0, 255)

        for i = 1, #currentPath - 1 do
            local node1 = currentPath[i]
            local node2 = currentPath[i + 1]

            local node1Pos = Vector3(node1.x, node1.y, node1.z)
            local node2Pos = Vector3(node2.x, node2.y, node2.z)

            local screenPos1 = client.WorldToScreen(node1Pos)
            local screenPos2 = client.WorldToScreen(node2Pos)
            if not screenPos1 or not screenPos2 then goto continue end

            draw.Line(screenPos1[1], screenPos1[2], screenPos2[1], screenPos2[2])

            ::continue::
        end
    end

    -- Draw current node
    if options.drawCurrentNode and currentPath then
        draw.Color(255, 0, 0, 255)

        local currentNode = currentPath[currentNodeIndex]
        local currentNodePos = Vector3(currentNode.x, currentNode.y, currentNode.z)

        local screenPos = client.WorldToScreen(currentNodePos)
        if screenPos then
            draw.Text(screenPos[1], screenPos[2], tostring(currentNodeIndex))
        end
    end
end

---@param userCmd UserCmd
local function OnCreateMove(userCmd)
    if not options.autoPath then return end

    local me = entities.GetLocalPlayer()
    if not me or not me:IsAlive() then
        Navigation.ClearPath()
        return
    end

    local myPos = me:GetAbsOrigin()
    local currentPath = Navigation.GetCurrentPath()

    if currentPath then
        -- Move along path
        local currentNode = currentPath[currentNodeIndex]
        local currentNodePos = Vector3(currentNode.x, currentNode.y, currentNode.z)

        local dist = (myPos - currentNodePos):Length()
        if dist < 22 then
            currentNodeTicks = 0
            currentNodeIndex = currentNodeIndex - 1
            if currentNodeIndex < 1 then
                Navigation.ClearPath()
                --options.autoPath = false
                Log:Info("Reached end of path")
            end
        else
            currentNodeTicks = currentNodeTicks + 1
            Lib.TF2.Helpers.WalkTo(userCmd, me, currentNodePos)
        end

        -- Jump if stuck
        if currentNodeTicks > 100 then
            userCmd.buttons = userCmd.buttons | IN_JUMP
        end

        -- Repath if stuck
        if currentNodeTicks > 250 then
            Log:Warn("Stuck on node %d, removing connection and repathing...", currentNodeIndex)
            Navigation.RemoveConnection(currentNode, currentPath[currentNodeIndex - 1])
            Navigation.ClearPath()
            currentNodeTicks = 0
        end
    else
        -- Generate new path

        -- Get start (Local player position)
        local startNode = Navigation.GetClosestNode(myPos)

        -- Get goal (Enemy flag)
        local goalNode = nil
        local myItem = me:GetPropInt("m_hItem")
        local flags = entities.FindByClass("CCaptureFlag")
        for idx, entity in pairs(flags) do
            local myTeam = entity:GetTeamNumber() == me:GetTeamNumber()
            if (myItem > 0 and myTeam) or (myItem < 0 and not myTeam) then
                goalNode = Navigation.GetClosestNode(entity:GetAbsOrigin())
                break
            end
        end

        -- Check if we found a start and goal node
        if not startNode or not goalNode then
            Log:Warn("Could not find new start or goal node")
            return
        end

        -- Update the pathfinder
        Log:Info("Generating new path from node %d to node %d", startNode.id, goalNode.id)
        Navigation.FindPath(startNode, goalNode)
        currentNodeIndex = #Navigation.GetCurrentPath()
    end
end

---@param event GameEvent
local function OnGameEvent(event)
    local eventName = event:GetName()

    -- Reload nav file on new map
    if eventName == "game_newmap" then
        Log:Info("New map detected, reloading nav file...")
        LoadNavFile()
    end
end

callbacks.Unregister("Draw", "LNX.Lmaobot.Draw")
callbacks.Unregister("CreateMove", "LNX.Lmaobot.CreateMove")
callbacks.Unregister("FireGameEvent", "LNX.Lmaobot.FireGameEvent")

callbacks.Register("Draw", "LNX.Lmaobot.Draw", OnDraw)
callbacks.Register("CreateMove", "LNX.Lmaobot.CreateMove", OnCreateMove)
callbacks.Register("FireGameEvent", "LNX.Lmaobot.FireGameEvent", OnGameEvent)

--[[ Commands ]]

-- Reloads the nav file
Commands.Register("pf_reload", function()
    LoadNavFile()
end)

-- Calculates the path from start to goal
Commands.Register("pf", function(args)
    if args:size() ~= 2 then
        print("Usage: pf <Start> <Goal>")
        return
    end

    local start = tonumber(args:popFront())
    local goal = tonumber(args:popFront())

    if not start or not goal then
        print("Start/Goal must be numbers!")
        return
    end

    local startNode = Navigation.GetNodeByID(start)
    local goalNode = Navigation.GetNodeByID(goal)

    if not startNode or not goalNode then
        print("Start/Goal node not found!")
        return
    end

    Navigation.FindPath(startNode, goalNode)
end)

Commands.Register("pf_auto", function (args)
    options.autoPath = not options.autoPath
    print("Auto path: " .. tostring(options.autoPath))
end)

Notify.Alert("Lmaobot loaded!")
LoadNavFile()