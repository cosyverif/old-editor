#! /usr/bin/env lua

local defaults = {
  port = 6969,
  directory = "/home/cosyverif/resource/",
  safe = false,
  timeout = 300,
}

local global = _ENV or _G
local cosy = {}
global.cosy = cosy

local logging   = require "logging"
logging.console = require "logging.console"
local logger = logging.console "%level %message\n"

local ev        = require "ev"
local websocket = require "websocket"
local json      = require "dkjson"
local lfs       = require "lfs"
local cli       = require "cliargs"

if #(cli.required) ~= 0 or #(cli.optional) ~= 0 then
  -- Called from another script
  return defaults
end

cli:set_name ("editor.lua")
cli:add_argument(
  "resource",
  "resource to edit"
)
cli:add_argument(
  "token",
  "identification token for the server"
)
cli:add_option(
  "-d, --directory=<directory>",
  "path to the model directory",
  tostring (defaults.directory)
)
cli:add_option(
  "-p, --port=<number>",
  "port to use",
  tostring (defaults.port)
)
cli:add_option(
  "-t, --timeout=<in seconds>",
  "delay after the last connexion before shutdown",
  tostring (defaults.timeout)
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

if args.configuration then
  return defaults
end

local resource     = args.resource
local directory    = args.directory
local admin_token  = args.token
local port         = args.port
local timeout      = tonumber (args.timeout) -- seconds
local verbose_mode = args.verbose

if verbose_mode then
  logger:setLevel (logging.DEBUG)
else
  logger:setLevel (logging.INFO)
end

logger:info ("Resource is '" .. resource .. "'.")
logger:info ("Data directory is '" .. directory .. "'.")
logger:info ("Administration token is '" .. admin_token .. "'.")
logger:info ("Timeout is set to " .. tostring (timeout) .. " seconds.")
logger:info ("Safe mode is " .. (safe_mode and "on" or "off") .. ".")

local data_file         = directory .. "/model.lua"
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

local function append_file (file, s)
  logger:debug ("Appending to file '" .. tostring (file) .. "'...")
  if not s then
    return nil
  end
  local f = io.open (file, "a")
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
    local ok, err = pcall (dofile, data_file)
    if not ok then
      logger:warn (err)
    end
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
  logger:info "End of initialization."
end

local handlers = {}

handlers ["get-model"] = function (client, command)
  local access = tokens [command.token]
  if not access or not access [READ_ACCESS] then
    client:send (json.encode {
      action   = command.action,
      answer   = command.request_id,
      accepted = false,
      reason   = "User does not have 'read' permission.",
    })
    return
  end
  client:send (json.encode {
    action   = command.action,
    answer   = command.request_id,
    accepted = true,
    code     = read_file (data_file),
    version  = patches [#patches],
  })
end

handlers ["list-patches"] = function (client, command)
  local access = tokens [command.token]
  if not access or not access [READ_ACCESS] then
    client:send (json.encode {
      action   = command.action,
      answer   = command.request_id,
      accepted = false,
      reason   = "User does not have 'read' permission.",
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
    action   = command.action,
    answer   = command.request_id,
    accepted = true,
    patches  = extracted,
  })
end

handlers ["get-patches"] = function (client, command)
  local access = tokens [command.token]
  if not access or not access [READ_ACCESS] then
    client:send (json.encode {
      action   = command.action,
      answer   = command.request_id,
      accepted = false,
      reason   = "User does not have 'read' permission.",
    })
    return
  end
  local id   = command.id
  local from = command.from
  local to   = command.to
  local extracted = {}
  if id and (from or to) then
    client:send (json.encode {
      action   = command.action,
      answer   = command.request_id,
      accepted = false,
      reason   = "Command 'get-patches' requires 'id' or ('from'? and 'to'?).",
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
        action   = command.action,
        answer   = command.request_id,
        accepted = false,
        reason   = "Patch '" .. id .. "' does not exist.",
      })
      return
    end
  else
    for _, i in ipairs (patches) do
      if (not from or from <= i) and (not to or i <= to) then
        extracted [#extracted + 1] = {
          id = i,
          code = read_file (patches_directory .. i .. ".lua"),
        }
      end
    end
  end
  client:send (json.encode {
    action   = command.action,
    answer   = command.request_id,
    accepted = true,
    patches  = extracted,
  })
end

handlers ["add-patch"] = function (client, command)
  local access = tokens [command.token]
  if not access or not access [WRITE_ACCESS] then
    client:send (json.encode {
      action   = command.action,
      answer   = command.request_id,
      accepted = false,
      reason   = "User does not have 'write' permission.",
    })
    return
  end
  local patch_str = command.data
  if not patch_str then
    client:send (json.encode {
      action   = command.action,
      answer   = command.request_id,
      accepted = false,
      reason   = "Command has no 'data' key containing the patch.",
    })
    return
  end
  logger:debug ("Asked to add patch: '" .. patch_str .. "'.")
  local s, err = pcall (function () loadstring (patch_str) () end)
  if not s then
    logger:warn ("Cannot apply patch: '" .. patch_str  .. "', because: " .. err)
    client:send (json.encode {
      action   = command.action,
      answer   = command.request_id,
      accepted = false,
      reason   = "Error while loading patch: " .. err .. ".",
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
  write_file (patches_directory .. id .. ".lua", patch_str)
  append_file (data_file, patch_str)
  local update = json.encode {
    action  = "update",
    version = patches [#patches],
    patches = { { id = id, code = patch_str } },
  }
  for c in pairs (clients) do
    if c ~= client then
      logger:debug ("  Sending to " .. tostring (client) .. "...")
      c:send (update)
    end
  end
  client:send (json.encode {
    action   = command.action,
    answer   = command.request_id,
    accepted = true,
    id       = id,
    version  = patches [#patches],
  })

end

handlers ["set-token"] = function (client, command)
  local access = tokens [command.token]
  if not access or not access [ADMIN_ACCESS] then
    client:send (json.encode {
      action   = command.action,
      answer   = command.request_id,
      accepted = false,
      reason   = "Command 'set-user' is restricted to administrator.",
    })
    return
  end
  local token = command.for_token
  if not token then
    client:send (json.encode {
      action   = command.action,
      answer   = command.request_id,
      accepted = false,
      reason   = "Command 'set-user' requires a 'token'.",
    })
    return
  end
  tokens [token] = {
    [WRITE_ACCESS] = command.can_write,
    [READ_ACCESS ] = command.can_read,
    [ADMIN_ACCESS] = nil,
  }
  client:send (json.encode{
    action   = command.action,
    answer   = command.request_id,
    accepted = true,
  })
end

local function from_client (client, message)
  -- Extract command and data:
  local command, _, err = json.decode (message)
  if err then
    client:send (json.encode {
      accepted = false,
      reason   = "Command is not valid JSON: " .. err .. ".",
    })
    return
  end
  if not command then
    client:send (json.encode {
      accepted = false,
      reason   = "Command is empty.",
    })
    return
  end
  -- Extract action:
  local action = command.action:lower ()
  if not action then
    client:send (json.encode {
      action   = command.action,
      answer   = command.request_id,
      accepted = false,
      reason   = "Command has no 'action' key.",
    })
    return
  end
  if handlers [action] then
    return handlers [action] (client, command)
  else
    client:send (json.encode {
      action   = command.action,
      answer   = command.request_id,
      accepted = false,
      reason   = "Action '" .. action .. "' is not defined.",
    })
    return
  end
end

local timer = ev.Timer.new (
  function ()
    if is_empty (clients) then
      logger:info ("The timeout (" .. timeout .. "s) elapsed since the last client quit.")
      logger:info "Bye."
      ev.Loop.default:unloop ()
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
