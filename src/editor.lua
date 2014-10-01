#! /usr/bin/env lua

local defaults = {
  interface = "127.0.0.3",
  port      = 6969,
  directory = "/home/cosyverif/resource/",
  commit    = 10,
  timeout   = 300,
}

if cli then
  -- Called from another script
  return defaults
end

      cli       = require "cliargs"
local logging   = require "logging"
logging.console = require "logging.console"
local logger    = logging.console "%level %message\n"

cli:set_name ("editor.lua")
cli:add_argument(
  "resource",
  "resource to edit"
)
cli:add_option(
  "--directory=<directory>",
  "path to the model directory",
  tostring (defaults.directory)
)
cli:add_option(
  "--interface=<IP address>",
  "interface to use",
  tostring (defaults.interface)
)
cli:add_option(
  "--port=<number>",
  "port to use",
  tostring (defaults.port)
)
cli:add_option(
  "--commit=<in seconds>",
  "delay between commits to the repository",
  tostring (defaults.commit)
)
cli:add_option(
  "--timeout=<in seconds>",
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

local resource     = args.resource
local directory    = args.directory
local interface    = args.interface
local port         = args.port
local commit       = tonumber (args.commit)  -- seconds
local timeout      = tonumber (args.timeout) -- seconds
local verbose_mode = args.verbose

local ev        = require "ev"
local websocket = require "websocket"
local json      = require "dkjson"
local lfs       = require "lfs"
local _         = require "util.string"

local global = _ENV or _G
local cosy = {}
global.cosy = cosy

if verbose_mode then
  logger:setLevel (logging.DEBUG)
else
  logger:setLevel (logging.INFO)
end

logger:info ("Resource is '" .. resource .. "'.")
logger:info ("Data directory is '" .. directory .. "'.")
logger:info ("Commit is set to " .. tostring (commit) .. " seconds.")
logger:info ("Timeout is set to " .. tostring (timeout) .. " seconds.")

local patches = {}
local clients = {}
local timestamp_suffix = 1
local latest_timestamp = nil

local function is_empty (t)
  return pairs (t) (t) == nil
end

local function init ()
  logger:info "Initializing the data..."
  
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

local function from_client (client, message)
  -- Extract command and data:
  local command, _, err = json.decode (message)
  if not command then
    client:send (json.encode {
      accepted = false,
      reason   = "Command is not valid JSON: " .. err .. ".",
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

-- TODO: activate idle when a patch arrivesig
local idle = ev.Idle.new (
  function (loop, idle, revents)
    -- TODO: send patches
    idle:stop ()
  end
)

websocket.server.ev.listen {
  interface = interface,
  port      = port,
  protocols = {
    ["cosy"] = function (client)
      timer:stop (ev.Loop.default)
      clients [client] = {
        read  = false,
        write = false,
      }
      logger:info ("Client " .. tostring (client) .. " is connecting...")
      client:on_message (from_client)
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
logger:info ("Listening on ws://${interface}:${port}." % {
  interface = interface,
  port      = port,
})
logger:info "Entering main loop..."
timer:start (ev.Loop.default, true)
ev.Loop.default:loop ()
