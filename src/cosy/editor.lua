#! /usr/bin/env lua

local global = _ENV or _G

local defaults = {
  port      = 6969,
  commit    = 10,
  timeout   = 300,
}

if global.cli then
  -- Called from another script
  return defaults
end

global.cli      = require "cliargs"
local logging   = require "logging"
logging.console = require "logging.console"
local logger    = logging.console "%level %message\n"

global.cli:set_name ("editor.lua")
global.cli:add_argument(
  "resource",
  "resource to edit"
)
global.cli:add_option(
  "--interface=<IP address>",
  "interface to use",
  tostring (defaults.interface or "*")
)
global.cli:add_option(
  "--port=<number>",
  "port to use",
  tostring (defaults.port)
)
global.cli:add_option(
  "--timeout=<number in seconds>",
  "timeout before closing",
  tostring (defaults.timeout)
)
global.cli:add_flag(
  "-v, --verbose",
  "enable verbose mode"
)
local args = global.cli:parse_args ()
if not args then
  global.cli:print_help()
  return
end

local resource     = args.resource
local interface    = args.interface
local port         = args.port
local timeout      = args.timeout
local verbose_mode = args.verbose

if interface == "*" then
  interface = nil
end

local ev        = require "ev"
local websocket = require "websocket"
local json      = require "dkjson"
local http      = require "socket.http"
local ltn12     = require "ltn12"
local _         = require "cosy.util.string"
local Data      = require "cosy.data"
local Tag       = require "cosy.tag"

local cosy = {}
global.cosy = cosy
global.Tag  = Tag

if verbose_mode then
  logger:setLevel (logging.DEBUG)
else
  logger:setLevel (logging.INFO)
end

logger:info ("Resource is '" .. resource .. "'.")
logger:info ("Timeout is set to " .. tostring (timeout) .. " seconds.")

local clients = {}
local data    = nil
local undo    = {}

global.cosy  = Data.new {}

Data.on_write.undo = function (target, value, reverse)
  target = target
  value  = value
  undo [#undo + 1] = reverse
end

local function is_empty (t)
  return pairs (t) (t) == nil
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

local handlers = {}

handlers ["connect"] = function (client, command)
  if command.resource ~= resource then
    client:send (json.encode {
      action    = command.action,
      answer    = command.request,
      accepted  = false,
      reason    = "I am not an editor for ${resource}." % {
        resource = command.resource
      }
    })
    client:close ()
    return
  end
  local username = command.username
  local password = command.password
  local url = resource
  if username then
    url = url:gsub ("^http://", "http://${username}:${password}@" % {
      username = username,
      password = password,
    })
  end
  local answer, code = http.request (url)
  if not answer or code ~= 200 then
    client:send (json.encode {
      action    = command.action,
      answer    = command.request,
      accepted  = false,
      reason    = "Resource ${resource} unreachable, because ${reason}." % {
        resource = command.resource,
        reason   = code,
      }
    })
    client:close ()
    return
  end
  answer = json.decode (answer)
  local can_write = answer.is_edit
  clients [client] = {
    username  = username,
    password  = password,
    can_write = can_write,
    url       = url,
  }
  if not data then
    data = answer.data or ""
  end
  client:send (json.encode {
    action    = command.action,
    answer    = command.request,
    accepted  = true,
    data      = data,
    can_write = can_write,
  })
end

handlers ["patch"] = function (client, command)
  local function cancel (message)
    logger:warn ("Cannot apply patch, because: " .. message)
    for i = #undo, 1, -1 do
      pcall (undo [i])
    end
    client:send (json.encode {
      action   = command.action,
      answer   = command.request,
      accepted = false,
      reason   = message,
    })
  end
  if not clients [client].can_write then
    cancel ("User does not have write permission.")
    client:close ()
    return
  end
  local patch = command.data
  if not patch then
    cancel ("Command does not have a 'data' field containing the patch.")
    return
  end
  logger:debug ("Asked to add patch: '" .. patch .. "'.")
  local s, err = pcall (function () loadstring (patch) () end)
  if not s then
    cancel (err)
    return
  end
  local sent_data = json.encode {
    data = patch
  }
  local _, code = http.request {
    url    = clients [client].url,
    method = "PATCH",
    source = ltn12.source.string (sent_data),
    headers = {
      ["content-type"  ] = "application/json",
      ["content-length"] = #sent_data,
    },
  }
  if code ~= 200 then
    cancel (code)
    if code == 403 then
      client:close ()
    end
    return
  end
  -- Accepted:
  data = data .. "\n" .. patch
  for i = #undo, 1, -1 do
    undo [i] = nil
  end
  local update = json.encode {
    action  = "update",
    data    = patch,
  }
  for c in pairs (clients) do
    if c ~= client then
      c:send (update)
    end
  end
  client:send (json.encode {
    action   = command.action,
    answer   = command.request,
    accepted = true,
    data     = patch,
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
      answer   = command.request,
      accepted = false,
      reason   = "Command has no 'action' field.",
    })
    return
  end
  if handlers [action] then
    return handlers [action] (client, command)
  else
    client:send (json.encode {
      action   = command.action,
      answer   = command.request,
      accepted = false,
      reason   = "Action '" .. action .. "' is not defined.",
    })
    return
  end
end

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

logger:info ("Listening on ws://${interface}:${port}." % {
  interface = interface or "*",
  port      = port,
})
logger:info "Entering main loop..."
timer:start (ev.Loop.default, true)
ev.Loop.default:loop ()
