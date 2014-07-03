#! /usr/bin/env lua

local logging   = require "logging"
logging.console = require "logging.console"
local logger = logging.console "%level %message\n"

local ev        = require "ev"
local copas     = require "copas.timer"
local server    = require "websocket" . server . ev
local json      = require "dkjson"
local cli       = require "cliargs"
local websocket = require "websocket"
local client    = websocket.client.sync { timeout = 2 }

cli:set_name ("dispatcher.lua")
cli:add_argument(
  "token",
  "identification token for the server"
)
cli:add_option(
  "-p, --port=<number>",
  "port to use",
  "8080"
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

local admin_token  = args.token
local port         = args.p
local verbose_mode = args.v

if verbose_mode then
  logger:setLevel (logging.DEBUG)
else
  logger:setLevel (logging.INFO)
end

logger:info ("Administration token is '" .. admin_token .. "'.")

local clients = {}
local servers = {}


local handlers = {}

handlers ["set-editor"] = function (client, command)
  if command.token ~= admin_token then
    client:send (json.encode {
      accepted = false,
      reason = "Action only available to administrator.",
    })
    return
  end
  servers [command.resource] = command.url
  client:send (json.encode {
    accepted = true,
  })
end

handlers ["set-resource"] = function (client, command)
  local ws = clients [client]
  if ws then
    ws:close()
  end
  local target = websocket.client.sync { timeout = 2 }
  local ok, err = target:connect (url, 'cosy')
  if not ok then
    client:send (json.encode {
      accepted = false,
      reason = "Unable to connect to resource server: " .. err .. ".",
    })
    return
  end
  clients [client] = target
  client:send (json.encode {
    accepted = true,
  })
  target:on_message (function (_, message)
    handle_target (client, message)
  end)
end

local function handle_source (client, message)
  local editor = clients [client]
  if editor then
    editor:send (message)
  else
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
    local handler = handlers [command.action]
    if not handler then
      client:send (json.encode {
        accepted = false,
        reason = "Unknown action",
      })
      return
    end
    handler (client, command)
  end
end

local function handle_target (client, message)
  client:send (message)
end

server.listen {
  port = port,
  protocols = {
    ["cosy"] = function (ws)
      logger:info ("Client " .. tostring (ws) .. " is connecting...")
      ws:on_message (function (_, message)
        handle_source (ws, message)
      end)
      ws:on_close (function ()
        local target = clients [ws]
        if target  then
          target:close ()
          clients [ws] = nil
        end
        logger:info ("Client " .. tostring (ws) .. " has disconnected.")
        ws:close ()
      end)
    end,
  }
}

logger:info ("Listening on port " .. tostring (port) .. ".")
logger:info "Entering main loop..."
ev.Loop.default:loop()
