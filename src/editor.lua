local copas   = require "copas.timer"
local server  = require "websocket" . server . copas
local json    = require "dkjson"
local serpent = require "serpent"
local lfs     = require "lfs"

local TIMEOUT = 10 -- seconds

local directory = "./"
local clients = {}
local patches = {}
local timestamp_suffix = 1
local latest_timestamp

cosy = {}



local function is_empty (t)
  for _, _ in pairs (t) do
    return false
  end
  return true
end

local function read_file (file)
  local f = io.open (file, "r")
  if not f then
    return nil
  end
  local content = f:read ("*all")
  f:close ()
  return content
end

local function write_file (file, s)
  local f = io.open (file, "w")
  if not f then
    return nil
  end
  f:write (s .. "\n")
  f:close ()
end

local function init ()
  -- Load the model:
  if lfs.attributes (directory .. "/model.lua") then
    local model_str = read_file (directory .. "/model.lua")
    cosy.model = loadstring (model_str) ()
  end
  -- Create the patches directory if it does not exist:
  if not lfs.attributes (directory .. "/patches") then
    lfs.mkdir (directory .. "/patches")
  end
  -- Load the list of patches:
  for entry in lfs.dir (directory .. "/patches/") do
    if entry:find (".lua") then
      local id = entry:sub (1, -5) -- remove ".lua"
      patches [#patches + 1] = id
    end
  end
  table.sort (patches)
end

local timer = copas.newtimer (
  nil,
  function ()
    if is_empty (clients) then
      write_file (directory .. "/model.lua", serpent.dump (cosy.model))
      os.exit (0)
    end
  end,
  nil,
  false,
  nil
)

local function handle_request (message)
  local result = {}
  local data   = nil
  -- Extract command and data:
  local p = message:find ("\n")
  local command_str = message:sub (1, p-1)
  local patch_str   = message:sub (p+1)
  local command, _, err = json.decode (command_str)
  if err then
    result.status = "rejected"
    result.reason = "Header is not valid JSON: " .. err .. "."
    return result
  end
  if not command then
    result.status = "rejected"
    result.reason = "Header is empty."
    return result
  end
  -- Extract meta info:
  local action = command.action:lower ()
  if not action then
    result.status = "rejected"
    result.reason = "Header has no 'action' key."
    return result
  end
  -- Perform command:
  if     action == "get-model" then
    result.status = "accepted"
    data = serpent.dump (cosy.model)
  elseif action == "list-patches" then
    result.status = "accepted"
    result.patches = patches
  elseif action == "get-patch" then
    local id   = command.id
    local from = command.from
    local to   = command.to
    if id and not from and not to then
      data = lfs.attributes (directory .. "/patches/" .. id .. ".lua")
      if data then
        result.status = "accepted"
      else
        result.status = "rejected"
        result.reason = "Patch '" .. id .. "' does not exist."
      end
    elseif not id and (from or to) then
      for _, i in ipairs (patches) do
        local extracted = {}
        local in_range = (to == nil)
        local saw_from = false
        local saw_to   = false
        if i == from then
          in_range = true
          extracted [#extracted + 1] = i
        elseif i == to then
          in_range = false
          extracted [#extracted + 1] = i
        elseif in_range then
          extracted [#extracted + 1] = i
        end
      end
      if from and not saw_from then
        result.status = "rejected"
        result.reason = "Patch '" .. from .. "' does not exist."
      end
      if to and not saw_to then
        result.status = "rejected"
        result.reason = "Patch '" .. to .. "' does not exist."
      end
      result.status = "accepted"
      for k, v in ipairs (extracted) do
        extracted [k] = read_file (directory .. "/patches/" .. v .. ".lua")
      end
      result.patches = extracted
    else
      result.status = "rejected"
      result.reason = "get-patch requires an 'id' or a range 'from' .. 'to'."
    end
  elseif action == "add-patch" then
    local origin = command.origin
    if not origin then
      result.status = "rejected"
      result.reason = "Header has no 'origin' key."
      return result
    end
    result.origin = origin
    local s, err = pcall (function () loadstring (patch_str) () end)
    if s then
      result.status = "accepted"
      data = patch_str
      local timestamp = os.time ()
      if timestamp == latest_timestamp then
        timestamp_suffix = timestamp_suffix + 1
      else
        timestamp_suffix = 1
      end
      latest_timestamp = timestamp
      local id = tostring (timestamp) .. "-" .. tostring (timestamp_suffix):format ("%09d")
      patches [#patches + 1] = id
      patch_str = "-- " .. os.date ("Created on %A %d %B %Y, at %X.", timestamp) .. "\n" ..
                  "-- Command: " .. command_str .. "\n" ..
                  patch_str
      write_file (directory .. "/patches/" .. id .. ".lua", patch_str)
    else
      result.status = "rejected"
      result.reason = "Error while loading patch: " .. err .. "."
    end
  else
    result.status = "rejected"
    result.reason = "Action '" .. action .. "' is not defined."
  end
  return result, data
end

server.listen {
  port = 8080,
  protocols = {
    ["cosy"] = function (ws)
      print ("New connexion")
      timer:cancel ()
      clients [ws] = true
      while true do
        local message = ws:receive()
        if message then
          local result, data = handle_request (message)
          if result.status == "accepted" then
            local answer = json.encode (result) .. "\n" .. (data or "")
            for client in pairs (clients) do
              client:send (answer)
            end
          else
            ws:send (result)
          end
        else
          print ("Close connexion")
          break
        end
      end
      clients [ws] = nil
      timer:arm (TIMEOUT)
      ws:close()
    end,
  }
}

init ()
timer:arm (TIMEOUT)
copas.loop()
