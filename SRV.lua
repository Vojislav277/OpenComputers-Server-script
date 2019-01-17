----------------------------------
-- ServerFS Host Autorun Script --
----------------------------------
-- Configuration --
local cachedActions = true -- Set this to true to make certain actions cached
local mordalTextWindow = true -- Set this to true to make the console mordal and clear the terminal.
local sendResponseDirectly = true -- Set this to true if this computer will send responses to clients without the assistance of another computer.
local showMessagesReceived = true -- Set this to true to print messages to the terminal.
local showReturnedVariables = true
local forceReadOnly = false
local fsLabelCanBeChanged = false -- Set this to true to allow changes to the filesystem label.
local handleFix = true -- Set this to true if OpenComputers is updated to a version which does not use number identifation for file handles.
local autoCheckVersion = true
local fsLabel = "Server filesystem"
 
-- Modules --
local computer = require("computer")
local component = require("component")
local serialization = require("serialization")
local event = require("event")
local term = require("term")
 
-- Clear anything on the screen
if mordalTextWindow then
    term.clear()
    term.setCursor(1, 1)
    term.setCursorBlink(false)
end
 
local freeMemory = function()
    for ilteration = 1, 10 do
        os.sleep(0)
    end
end
freeMemory() -- Free memory
 
-----------------------
-- Set up the server --
-----------------------
-- Gets a primary component.
local getComponent
getComponent = function(componentType)
    local success, component = pcall(component.getPrimary, componentType)
    if success then
        return component
    end
    return false, component
end
 
local filesystems = {}
 
-- Find filesystems --
print("Finding filesystems...")
local isReadOnly = true
for address in component.list("filesystem") do
    local thisComponent = component.proxy(address)
    -- We do not want to use the filesystem on the temp address or the boot address.
    if address ~= computer.tmpAddress() and address ~= computer.getBootAddress() then
        filesystems[address] = thisComponent
        isReadOnly = forceReadOnly or (isReadOnly and thisComponent.isReadOnly())
        if not thisComponent.getLabel() or thisComponent.getLabel() == "" then
            thisComponent.setLabel("ServerFSDisk " .. address:sub(1, 3))
        end
    end
end
 
-- Check if there is at least one filesystem for this server to use --
local hasFilesystem = false
for key, value in pairs(filesystems) do
    hasFilesystem = true
    break
end
if not hasFilesystem then
    error("No usable filesystems detected. ServerFS requires at least one filesystem not used for booting the system to run.", 0)
    while true do
        freeMemory()
    end
end
 
-- Build the filesystem variables --
local spaceTotalCache, spaceFreeCache, spaceUsedCache -- Respective caches
local listCache -- The directory list cache
local fileToFS = {} -- Which filesystem to access to find which file.
local handleToFS = {} -- Which filesystem to access for each handle.
local handleToNumber = {}
local numberToHandle = {}
local serverFS = {type = "filesystem", address = "0000-ServerFS"} -- The filesystem module itself.
 
-- Invalidates the caches.
local invalidateCache = function()
    spaceTotalCache, spaceFreeCache, spaceUsedCache = nil, nil, nil
    if cachedActions then
        listCache = {}
    end
end
if cachedActions then
    listCache = {}
end
 
-- Accoiates files to the correct file system
local numOfFiles = 0
local associateFilesInSubDirectories
associateFilesInSubDirectories = function(filesystem, path)
    local itemsInDirectory = filesystem.list(path)
    for key, item in ipairs(itemsInDirectory) do
        if filesystem.isDirectory(path..item) then
            associateFilesInSubDirectories(filesystem, path..item)
        end
        fileToFS[path..item] = filesystem
        numOfFiles = numOfFiles + 1
    end
    term.setCursor(1, 3)
    term.clearLine()
    print(numOfFiles..(numOfFiles == 1 and " file" or " files").." found")
end
 
-- Ilterate through the filesystems, to find all files in them.
print("Finding files...")
for address, filesystem in pairs(filesystems) do
    associateFilesInSubDirectories(filesystem, "")
end
 
-- Print the number of files
term.setCursor(1, 3)
term.clearLine()
print(numOfFiles..(numOfFiles == 1 and " file" or " files").." found")
 
freeMemory() -- Free memory
 
-- Build the library --
print("Initalizating library...")
 
-- The overall capacity of the file system, in bytes.
function serverFS.spaceTotal()
    if spaceTotalCache then
        return spaceTotalCache
    end
   
    -- Calculate the total space
    local spaceTotal = 0
    for address, filesystem in pairs(filesystems) do
        spaceTotal = spaceTotal + filesystem.spaceTotal()
    end
   
    spaceTotalCache = spaceTotal
   
    return tonumber(spaceTotal)
end
 
-- The currently used capacity of the file system, in bytes.
function serverFS.spaceUsed()
    if spaceUsedCache then
        return spaceUsedCache
    end
   
    -- Calculate the used space
    local spaceUsed = 0
    for address, filesystem in pairs(filesystems) do
        spaceUsed = spaceUsed + filesystem.spaceUsed()
    end
   
    spaceUsedCache = spaceUsed
   
    return tonumber(spaceUsed)
end
 
-- The amount of space free on the file system.
function serverFS.spaceFree()
    if spaceFreeCache then
        return spaceFreeCache
    end
   
    -- Calculate the total and used space
    local spaceTotal, spaceUsed = 0, 0
    for address, filesystem in pairs(filesystems) do
        spaceTotal = spaceTotal + filesystem.spaceTotal()
        spaceUsed = spaceUsed + filesystem.spaceUsed()
    end
   
    spaceFreeCache = tonumber(spaceTotal - spaceUsed)
    spaceUsedCache = spaceUsed
    spaceTotalCache = spaceTotal
   
    return tonumber(spaceTotal - spaceUsed)
end
 
-- Returns whether the file system is read-only.
function serverFS.isReadOnly()
    return isReadOnly
end
 
-- Finds the filesystem to host this path.
-- If a file exists at this path on a filesystem then return the filesystem it is hosted on.
-- If not, then return the filesystem with the most space free.
local findFSFromPath = function(path)
    if fileToFS[path] then
        return fileToFS[path]
    end
   
    -- Find a filesystem to host this file.
    local largestFreeSpace, usedFileSystem = 0
    for address, filesystem in pairs(filesystems) do
        local spaceAvailable = filesystem.spaceTotal() - filesystem.spaceUsed()
        if spaceAvailable > largestFreeSpace then
            largestFreeSpace, usedFileSystem = spaceAvailable, filesystem
        end
    end
    fileToFS[path] = usedFileSystem
   
    return fileToFS[path]
end
 
-- Opens a new file descriptor and returns its handle.
function serverFS.open(path, mode)
    local filesystem = findFSFromPath(path)
 
    local handle, errorMessage = filesystem.open(path, mode)
    if handle then
        handleToFS[handle] = filesystem
        if autoCheckVersion then
            if type(handle) == "table" then
                handleFix = true
            else
                handleFix = false
            end
            autoCheckVersion = false
        end
        if handleFix and handle then
            handleToNumber[handle] = math.floor(math.random()*90000)
            numberToHandle[handleToNumber[handle]] = handle
            return handleToNumber[handle], errorMessage
        else
            return handle, errorMessage
        end
    end
   
    return tonumber(handle), errorMessage
end
 
-- Creates a directory at the specified absolute path in the file system. Creates parent directories, if necessary.
function serverFS.makeDirectory(path)
    local success, errorMessage
    for address, filesystem in pairs(filesystems) do
        success, errorMessage = filesystem.makeDirectory(path)
    end
    invalidateCache()
    return success, errorMessage
end
 
-- Creates a directory at the specified absolute path in the file system. Creates parent directories, if necessary.
function serverFS.exists(path)
    local filesystem = findFSFromPath(path)
    return filesystem.exists(path)
end
 
-- Returns a list of names of objects in the directory at the specified absolute path in the file system.
function serverFS.list(path)
    if listCache then
        if listCache[path] then
            return listCache[path]
        end
    end
    local completeList = {}
    for address, filesystem in pairs(filesystems) do
        local list = filesystem.list(path)
        if type(list) == "table" then
            for key, value in ipairs(list) do
                completeList[#completeList + 1] = value
            end
        end
    end
   
    if listCache then
        listCache[path] = completeList
    end
   
    return completeList
end
 
-- Removes the object at the specified absolute path in the file system.
function serverFS.remove(path)
    local filesystem = findFSFromPath(path)
    invalidateCache()
    return filesystem.remove(path)
end
 
-- Returns whether the object at the specified absolute path in the file system is a directory.
function serverFS.isDirectory(path)
    local filesystem = findFSFromPath(path)
    return filesystem.isDirectory(path)
end
 
-- Returns the size of the object at the specified absolute path in the file system.
function serverFS.size(path)
    local filesystem = findFSFromPath(path)
    return tonumber(filesystem.size(path))
end
 
-- Returns the (real world) timestamp of when the object at the specified absolute path in the file system was modified.
function serverFS.lastModified(path)
    local filesystem = findFSFromPath(path)
    return tonumber(filesystem.lastModified(path))
end
 
-- Renames a file.
function serverFS.rename(path, newPath)
    local filesystem = findFSFromPath(path)
    invalidateCache()
    return filesystem.rename(path, newPath)
end
 
-- Get the current label of the file system.
function serverFS.getLabel()
    return fsLabel
end
 
-- Sets the label of the file system. Returns the new value, which may be truncated.
function serverFS.setLabel(newLabel)
    if fsLabelCanBeChanged then
        if type(newLabel) == "string" then
            fsLabel = newLabel:sub(1, 80)
        end
    end
    return fsLabel
end
 
-- Seeks in an open file descriptor with the specified handle. Returns the new pointer position.
function serverFS.seek(handle, ...)
    if handleFix then
        handle = numberToHandle[handle]
    end
    if handleToFS[handle] then
        return handleToFS[handle].seek(handle, ...)
    end
end
 
-- Writes the specified data to an open file descriptor with the specified handle.
function serverFS.write(handle, ...)
    if handleFix then
        handle = numberToHandle[handle]
    end
    if handleToFS[handle] then
        return handleToFS[handle].write(handle, ...)
    end
end
 
-- Reads up to the specified amount of data from an open file descriptor with the specified handle. Returns nil when EOF is reached.
function serverFS.read(handle, ...)
    if handleFix then
        handle = numberToHandle[handle]
    end
    if handleToFS[handle] then
        return handleToFS[handle].read(handle, ...)
    end
end
 
-- Closes an open file descriptor with the specified handle.
function serverFS.close(handle, ...)
    if handleFix then
        handle = numberToHandle[handle]
    end
    if handleToFS[handle] then
        invalidateCache()
        return handleToFS[handle].close(handle, ...)
    end
end
 
package.loaded["serverFS"] = serverFS
 
-- Free up unused memory --
print("Freeing memory...")
freeMemory() -- Free memory
 
print("Total array capacity is "..serverFS.spaceTotal().." bytes")
print("Used array capacity is "..serverFS.spaceUsed().." bytes")
print("Free space on array totals "..serverFS.spaceFree().." bytes")
print("Total RAM is "..computer.totalMemory().." bytes")
print("Remaining memory is "..computer.freeMemory().." bytes")
 
-- Set the ports used --
local directResponseReceivePort = 300
local directResponseSendPort = 280
local indirectReceivePort = 250
local indirectSendPort = 245
 
local sendPort = (sendResponseDirectly and directResponseSendPort) or indirectSendPort
local receivePort = (sendResponseDirectly and directResponseReceivePort) or indirectReceivePort
 
-- Get the components used for the messaging system --
local modemAddress, tunnelAddress
local modem = getComponent("modem") -- get primary modem component
if modem then
    modem.open(receivePort)
    modem.broadcast(240, "Server Filesystem online")
    modem.setWakeMessage("Server Filesystem online")
    modemAddress = modem.address
end
 
local tunnel = getComponent("tunnel") -- get primary tunnel component
if tunnel then
    tunnelAddress = tunnel.address
end
 
-- Check for a modem or tunnel
if not (tunnel or modem) then
    error("No modem or tunnel detected. ServerFS requires a modem or tunnel to work.")
end
 
-- Activate the messaging system --
print("Activating message system...")
 
local lastMessage, lastMessage2 -- This is used to stop duplicate packets from being sent to relays and cause a cycle.
local lastTime = -.1
 
print("Server ready to handle requests.")
if showMessagesReceived then
    print("Waiting for message...")
end
-- Start recieving messages --
while true do
    local _, componentAddress, from, port, _, message = event.pull("modem_message")
   
    if port == receivePort or componentAddress == tunnelAddress then
        if #message > 1 and ((message ~= lastMessage and message ~= lastMessage2) or computer.uptime() - lastTime > .1) then
            if showMessagesReceived then
                print("Got a message from " .. from .. ": " .. tostring(message))
            end
           
            -- Attempt to handle the request
            local recievedTime = computer.uptime()
            local arguments = serialization.unserialize(message)
           
            -- Did we even get the arguments???
            if arguments then
                if serverFS[arguments[1]] then
                    local functToCall = serverFS[arguments[1]]
                    table.remove(arguments, 1)
                    local result = {pcall(functToCall, table.unpack(arguments))}
                    if not result[1] then
                        io.stderr:write("Failed to handle request: "..tostring(result[2]).."\n")
                    end
                   
                    if showReturnedVariables then
                        print(result[1], result[2], result[3])
                    end
                   
                    -- Allow the computer to get the message
                    if computer.uptime() - recievedTime < .1 then
                        os.sleep(.1)
                    end
                    if componentAddress == modemAddress then
                        modem.send(from, sendPort, serialization.serialize(result))
                    elseif componentAddress == tunnelAddress then
                        tunnel.send(serialization.serialize(result))
                    end
                else
                    if componentAddress == modemAddress then
                        modem.send(from, sendPort, serialization.serialize({false, "function does not exist"}))
                    elseif componentAddress == tunnelAddress then
                        tunnel.send(serialization.serialize({false, "function does not exist"}))
                    end
                end
            end
           
            lastMessage2 = lastMessage
            lastMessage = message
            lastTime = computer.uptime()
        end
    end
end
