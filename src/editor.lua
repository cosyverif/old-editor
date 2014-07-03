#! /usr/bin/env lua

local cosy = {}
local global = _ENV or _G
global.cosy = cosy

local logging   = require "logging"
logging.console = require "logging.console"
local logger = logging.console "%level %message\n"

local ev        = require "ev"
local websocket = require "websocket"
local json      = require "dkjson"
local serpent   = require "serpent"
local lfs       = require "lfs"
local cli       = require "cliargs"

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
local admin_token  = args.token
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
logger:info ("Administration token is '" .. admin_token .. "'.")
logger:info ("Timeout is set to " .. tostring (timeout) .. " seconds.")
logger:info ("Safe mode is " .. (safe_mode and "on" or "off") .. ".")

local data_file         = directory .. "/model.lua"
local version_file      = directory .. "/model.version"
local patches_directory = directory .. "/patches/"
local tokens  = {}
local patches = {}
local clients = {}
local timestamp_suffix = 1
local latest_timestamp = nil

local ADMIN_ACCESS = {}
local WRITE_ACCESS = {}
local READ_ACCESS  = {}

tokens [admin_token] = {
  [ADMIN_ACCESS] = true,
  [WRITE_ACCESS] = true,
  [READ_ACCESS ] = true,
}

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
end

local handlers = {}

handlers ["get-model"] = function (client, command)
  local access = tokens [command.token]
  if not access or not access [READ_ACCESS] then
    client:send (json.encode {
      accepted = false,
      reason = "User does not have 'read' permission.",
    })
    return
  end
  client:send (json.encode {
    accepted = true,
    data = serpent.dump (cosy.model),
  })
end

handlers ["list-patches"] = function (client, command)
  local access = tokens [command.token]
  if not access or not access [READ_ACCESS] then
    client:send (json.encode {
      accepted = false,
      reason = "User does not have 'read' permission.",
    })
    return
  end
  local from = command.from
  local to   = command.to
  local extracted = {}
  for _, i in ipairs (patches) do
    if (not from or from <= i) and (not to or i <= to) then
      extracted [#extracted + 1] = { id = i }
    end
  end
  client:send (json.encode {
    accepted = true,
    patches  = extracted,
  })
end

handlers ["get-patches"] = function (client, command)
  local access = tokens [command.token]
  if not access or not access [READ_ACCESS] then
    client:send (json.encode {
      accepted = false,
      reason = "User does not have 'read' permission.",
    })
    return
  end
  local id   = command.id
  local from = command.from
  local to   = command.to
  local extracted = {}
  if id and (from or to) then
    client:send (json.encode {
      accepted = false,
      reason = "Command 'get-patches' requires 'id' or ('from'? and 'to'?).",
    })
    return
  elseif id then
    if lfs.attributes (patches_directory .. id .. ".lua") then
      extracted [1] = {
        id = id,
        data = read_file (patches_directory .. id .. ".lua"),
      }
    else
      client:send (json.encode {
        accepted = false,
        reason = "Patch '" .. id .. "' does not exist.",
      })
      return
    end
  else
    for _, i in ipairs (patches) do
      if (not from or from <= i) and (not to or i <= to) then
        extracted [#extracted + 1] = {
          id = i,
          data = read_file (patches_directory .. i .. ".lua"),
        }
      end
    end
  end
  client:send (json.encode {
    accepted = true,
    patches = extracted,
  })
end

handlers ["add-patch"] = function (client, command)
  local access = tokens [command.token]
  if not access or not access [WRITE_ACCESS] then
    client:send (json.encode {
      accepted = false,
      reason = "User does not have 'write' permission.",
    })
    return
  end
  local origin = command.origin
  if not origin then
    client:send (json.encode {
      accepted = false,
      reason = "Command has no 'origin' key.",
    })
    return
  end
  local patch_str = command.data
  if not patch_str then
    client:send (json.encode {
      accepted = false,
      reason = "Command has no 'data' key containing the patch.",
    })
    return
  end
  local s, err = pcall (function () loadstring (patch_str) () end)
  if not s then
    client:send (json.encode {
      accepted = false,
      reason = "Error while loading patch: " .. err .. ".",
    })
    return
  end
  local timestamp = os.time ()
  if timestamp == latest_timestamp then
    timestamp_suffix = timestamp_suffix + 1
  else
    timestamp_suffix = 1
    latest_timestamp = timestamp
  end
  local id = tostring (timestamp) .. "-" .. string.format ("%09d", timestamp_suffix)
  patches [#patches + 1] = id
  patch_str = "-- " .. os.date ("Created on %A %d %B %Y, at %X", timestamp) ..
              ", from origin '" .. origin .. "'.\n" ..
              patch_str
  write_file (patches_directory .. id .. ".lua", patch_str)
  if safe_mode then
    write_file (data_file, serpent.dump (cosy.model))
    write_file (version_file, patches [#patches])
  end
  local update = json.encode {
    action  = "update",
    patches = { { id = id, data = patch_str } },
  }
  for c in pairs (clients) do
    if c ~= client then
      logger:debug ("  Sending to " .. tostring (client) .. "...")
      c:send (update)
    end
  end
  client:send (json.encode {
    accepted = true,
    action   = command.action,
    origin   = origin,
    id       = id,
    patches  = { { id = id, data = patch_str } },
  })

end

handlers ["set-token"] = function (client, command)
  local access = tokens [command.token]
  if not access or not access [ADMIN_ACCESS] then
    client:send (json.encode {
      accepted = false,
      reason = "Command 'set-user' is restricted to administrator.",
    })
    return
  end
  local token = command.for_token
  if not token then
    client:send (json.encode {
      accepted = false,
      reason = "Command 'set-user' requires a 'token'.",
    })
    return
  end
  tokens [token] = {
    [WRITE_ACCESS] = command.can_write,
    [READ_ACCESS ] = command.can_read,
    [ADMIN_ACCESS] = nil,
  }
  client:send (json.encode{
    accepted = true,
  })
end

local function from_client (client, message)
  -- Extract command and data:
  local command, _, err = json.decode (message)
  if err then
    client:send (json.encode {
      accepted = false,
      reason = "Command is not valid JSON: " .. err .. ".",
    })
    return
  end
  if not command then
    client:send (json.encode {
      accepted = false,
      reason = "Command is empty.",
    })
    return
  end
  -- Extract action:
  local action = command.action:lower ()
  if not action then
    client:send (json.encode {
      accepted = false,
      reason = "Command has no 'action' key.",
    })
    return
  end
  if handlers [action] then
    return handlers [action] (client, command)
  else
    client:send (json.encode {
      accepted = false,
      reason = "Action '" .. action .. "' is not defined.",
    })
    return
  end
end

local timer = ev.Timer.new (
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
  timeout,
  timeout
)

websocket.server.ev.listen {
  port = port,
  protocols = {
    ["cosy"] = function (client)
      timer:stop (ev.Loop.default)
      clients [client] = true
      logger:info ("Client " .. tostring (client) .. " is connecting...")
      client:on_message (function (_, message)
        from_client (client, message)
      end)
      client:on_close (function ()
        clients [client] = nil
        client:close ()
        logger:info ("Client " .. tostring (client) .. " has disconnected.")
        timer:again (ev.Loop.default)
      end)
    end,
  }
}

init ()
logger:info ("Listening on port " .. tostring (port) .. ".")
logger:info "Entering main loop..."
timer:start (ev.Loop.default, true)
ev.Loop.default:loop ()
