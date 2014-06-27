#! /usr/bin/env lua

cosy = {}

local logging   = require "logging"
logging.console = require "logging.console"
local logger = logging.console "%level %message\n"

local copas   = require "copas.timer"
local server  = require "websocket" . server . copas
local json    = require "dkjson"
local serpent = require "serpent"
local lfs     = require "lfs"
local cli     = require "cliargs"

cli:set_name ("editor.lua")
cli:add_argument(
  "token",
  "identification token for the server"
)
cli:add_argument(
  "directory",
  "path to the model directory"
)
cli:add_option(
  "-p, --port=<number>",
  "port to use",
  "8080"
)
cli:add_flag(
  "-s, --safe",
  "dump model after each patch for safety"
)
cli:add_option(
  "-t, --timeout=<in seconds>",
  "delay after the last connexion before shutdown",
  "60"
)
cli:add_flag(
  "-v, --verbose",
  "enable verbose mode"
)
local args = cli:parse_args ()
if not args then
  cli:print_help()
  return
end

local directory    = args.directory
local token        = args.token
local port         = args.p
local safe_mode    = args.s
local timeout      = tonumber (args.t) -- seconds
local verbose_mode = args.v

if verbose_mode then
  logger:setLevel (logging.DEBUG)
else
  logger:setLevel (logging.INFO)
end

logger:info ("Data directory is '" .. directory .. "'.")
logger:info ("Administration token is '" .. token .. "'.")
logger:info ("Timeout is set to " .. tostring (timeout) .. " seconds.")
logger:info ("Safe mode is " .. (safe_mode and "on" or "off") .. ".")

local data_file         = directory .. "/model.lua"
local version_file      = directory .. "/model.version"
local patches_directory = directory .. "/patches/"
local clients = {}
local patches = {}
local timestamp_suffix = 1
local latest_timestamp = nil

local ADMIN_ACCESS = {}
local WRITE_ACCESS = {}
local READ_ACCESS  = {}

local function is_empty (t)
  return pairs (t) (t, nil) == nil
end

local function read_file (file)
  logger:debug ("Reading file '" .. tostring (file) .. "'...")
  local f = io.open (file, "r")
  if not f then
    return nil
  end
  local content = f:read ("*all")
  f:close ()
  return content
end

local function write_file (file, s)
  logger:debug ("Writing file '" .. tostring (file) .. "'...")
  if not s then
    return nil
  end
  local f = io.open (file, "w")
  if not f then
    return nil
  end
  f:write (s.. "\n")
  f:close ()
end

local timer = copas.newtimer (
  nil,
  function ()
    if is_empty (clients) then
      logger:info ("The timeout (" .. timeout .. "s) elapsed since the last client quit.")
      if safe_mode then
        logger:info "Running in safe mode. Data has already been dumped."
      elseif #patches ~= 0 then
        logger:info ("Dumping data file in '" .. data_file .. "'...")
        write_file (data_file, serpent.dump (cosy.model)) -- TODO: fix
        local version = patches [#patches]
        logger:info ("Dumping data version '" .. version .. "' in '" .. version_file .. "'...")
        write_file (version_file, version)
      end
      logger:info "Bye."
      os.exit (0)
    end
  end,
  nil,
  false,
  nil
)

local function init ()
  logger:info "Initializing the data..."
  -- Load the data:
  if lfs.attributes (data_file) then
    logger:info ("Loading the data from '" .. data_file .. "'...")
    local model_str = read_file (data_file)
    cosy.model = loadstring (model_str) () -- TODO: change
  end
  -- Create the patches directory if it does not exist:
  if not lfs.attributes (patches_directory) then
    logger:info ("Creating the patches directory '" .. patches_directory .. "'...")
    lfs.mkdir (patches_directory)
  end
  -- Load the list of patches:
  logger:info ("Creating the list of patches in '" .. patches_directory .. "'...")
  for entry in lfs.dir (patches_directory) do
    if entry:find (".lua") then
      local id = entry:sub (1, -5) -- remove ".lua"
      logger:debug ("Adding patch '" .. id .. "' from file '" ..
                    patches_directory .. entry .. "'...")
      patches [#patches + 1] = id
    end
  end
  table.sort (patches)
  if verbose_mode then
    logger:debug "Found the following patches (from oldest to latest):"
    for _, p in ipairs (patches) do
      logger:debug ("  " .. p)
    end
  end
  -- Apply all patches since the model version:
  local after
  local latest_patch = read_file (version_file)
  if latest_patch then
    latest_patch = latest_patch:match'^%s*(.*%S)'
    logger:info ("Data corresponds to patch '" .. latest_patch .. "'.")
    after = false
  else
    logger:warn "Data corresponds to no patch."
    after = true
  end
  logger:info "Updating data using patches..."
  local patch
  for _, patch in ipairs (patches) do
    if after then
      logger:debug ("  Applying patch '" .. patch .. "'.")
      dofile (patches_directory .. patch .. ".lua")
    end
    if patch == latest_patch then
      after = true
    end
  end
  write_file (version_file, patch)
  logger:info "End of initialization."
  timer:arm (timeout)
end

local function handle_request (message)
  local result = {}
  -- Extract command and data:
  local command, _, err = json.decode (message)
  if err then
    result.status = "rejected"
    result.reason = "Command is not valid JSON: " .. err .. "."
    return result
  end
  if not command then
    result.status = "rejected"
    result.reason = "Command is empty."
    return result
  end
  -- Extract action:
  local action = command.action:lower ()
  if not action then
    result.status = "rejected"
    result.reason = "Command has no 'action' key."
    return result
  end
  -- Perform command:
  if     action == "get-model" then
    result.status = "accepted"
    result.data = serpent.dump (cosy.model)
  elseif action == "list-patches" then
    result.status = "accepted"
    local from = command.from
    local to   = command.to
    if not from and not to then
      result.patches = patches
    else
      local extracted = {}
      for _, i in ipairs (patches) do
        if (not from or from <= i) and (not to or i <= to) then
          extracted [#extracted + 1] = { id = i }
        end
      end
      result.patches = extracted
    end
  elseif action == "get-patches" then
    local id   = command.id
    local from = command.from
    local to   = command.to
    if id and (from or to) then
      result.status = "rejected"
      result.reason = "Command 'get-patches' requires 'id' or ('from'? and 'to'?)."
      return result
    elseif id then
      if lfs.attributes (patches_directory .. id .. ".lua") then
        result.status = "accepted"
        result.patches = { [id] = read_file (patches_directory .. id .. ".lua") }
      else
        result.status = "rejected"
        result.reason = "Patch '" .. id .. "' does not exist."
      end
    else
      local extracted = {}
      for _, i in ipairs (patches) do
        if (not from or from <= i) and (not to or i <= to) then
          extracted [#extracted + 1] = {
            id = i,
            data = read_file (patches_directory .. i .. ".lua"),
          }
        end
      end
      result.status = "accepted"
      result.patches = extracted
    end
  elseif action == "add-patch" then
    local origin = command.origin
    if not origin then
      result.status = "rejected"
      result.reason = "Command has no 'origin' key."
      return result
    end
    local patch_str = command.data
    if not patch_str then
      result.status = "rejected"
      result.reason = "Command has no 'data' key containing the patch."
      return result
    end
    result.action = "add-patch"
    result.origin = origin
    local s, err = pcall (function () loadstring (patch_str) () end)
    if s then
      result.status  = "accepted"
      local timestamp = os.time ()
      if timestamp == latest_timestamp then
        timestamp_suffix = timestamp_suffix + 1
      else
        timestamp_suffix = 1
      end
      latest_timestamp = timestamp
      local id = tostring (timestamp) .. "-" .. string.format ("%09d", timestamp_suffix)
      result.patches = { { id = id, data = patch_str } }
      patches [#patches + 1] = id
      patch_str = "-- " .. os.date ("Created on %A %d %B %Y, at %X", timestamp) ..
                  ", from origin '" .. origin .. "'.\n" ..
                  patch_str
      write_file (patches_directory .. id .. ".lua", patch_str)
      if safe_mode then
        write_file (data_file, serpent.dump (cosy.model))
        write_file (version_file, patches [#patches])
      end
    else
      result.status = "rejected"
      result.reason = "Error while loading patch: " .. err .. "."
    end
  elseif action == "set-user" then
    -- TODO
  else
    result.status = "rejected"
    result.reason = "Action '" .. action .. "' is not defined."
  end
  return result
end

server.listen {
  port = port,
  protocols = {
    ["cosy"] = function (ws)
      logger:info ("Client " .. tostring (ws) .. " is connecting...")
      timer:cancel ()
      clients [ws] = {}
      local auth_message = ws:receive ()
      if auth_message then
        auth_message = auth_message:match'^%s*(.*%S)'
        if auth_message == token then
          clients [ws] [ADMIN_ACCESS] = true
        else
          clients [ws] [WRITE_ACCESS] = true -- TODO: fix
          clients [ws] [READ_ACCESS ] = true -- TODO: fix
        end
        while true do
          local message = ws:receive()
          if message then
            local result = handle_request (message)
            if result.status == "accepted" then
              logger:debug ("Message is successfully handled. Sending answer to all clients...")
              local answer = json.encode (result)
              for client in pairs (clients) do
                logger:debug ("  Sending to " .. tostring (client) .. "...")
                client:send (answer)
              end
            else
              logger:debug ("Message cannot be handled. Sending error to its source client...")
              ws:send (result)
            end
          else
            break
          end
        end
      end
      logger:info ("Client " .. tostring (ws) .. " has disconnected.")
      clients [ws] = nil
      timer:arm (timeout)
      ws:close()
    end,
  }
}

init ()
logger:info ("Listening on port " .. tostring (port) .. ".")
logger:info "Entering main loop..."
copas.loop()
