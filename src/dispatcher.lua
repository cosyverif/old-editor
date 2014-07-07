#! /usr/bin/env lua

local logging   = require "logging"
logging.console = require "logging.console"
local logger = logging.console "%level %message\n"

local defaults = {
  port = 8080,
}

local ev        = require "ev"
local json      = require "dkjson"
local cli       = require "cliargs"
local websocket = require "websocket"

if #(cli.required) ~= 0 or #(cli.optional) ~= 0 then
  -- Called from another script
  return defaults
end

cli:set_name ("dispatcher.lua")
cli:add_argument(
  "token",
  "identification token for the server"
)
cli:add_option(
  "-p, --port=<number>",
  "port to use",
  tostring (defaults.port)
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
local port         = args.port
local verbose_mode = args.verbose

if verbose_mode then
  logger:setLevel (logging.DEBUG)
else
  logger:setLevel (logging.INFO)
end

logger:info ("Administration token is '" .. admin_token .. "'.")

local editors = {}
local handlers = {}

local function from_client (client, message)
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
  if handler then
    handler (client, command)
  else
    if client.editor then
      client.editor:send (message)
    else
      client:send (json.encode {
        accepted = false,
        reason = "Unknown command and no active editor.",
      })
    end
  end
end

local function from_editor (client, message)
  client:send (message)
end

handlers ["set-editor"] = function (client, command)
  if command.token ~= admin_token then
    client:send (json.encode {
      accepted = false,
      reason = "Action only available to administrator.",
    })
    return
  end
  editors [command.resource] = command.url
  logger:info ("Resource " .. tostring (command.resource) ..
               " is now mapped to " .. tostring (command.url) .. ".")
  client:send (json.encode {
    accepted = true,
  })
end

handlers ["set-resource"] = function (client, command)
  if client.editor then
    client.editor:close()
  end
  client.editor = websocket.client.ev { timeout = 2 }
  client.editor:on_open (function ()
    client:send (json.encode {
      accepted = true,
    })
  end)
  client.editor:on_error (function (_, err)
    client.editor = nil
    client:send (json.encode {
      accepted = false,
      reason = "Unable to connect to resource server: " .. tostring (err) .. ".",
    })
  end)
  client.editor:on_message (function (_, message)
    from_editor (client, message)
  end)
  client.editor:on_close (function ()
    client.editor = nil
  end)
  local url = editors [command.resource]
  if not url then
    client:send (json.encode {
      accepted = false,
      reason   = "Resource is not available.",
    })
    return
  end
  client.editor:connect (url, 'cosy')
end

websocket.server.ev.listen {
  port = port,
  protocols = {
    ["cosy"] = function (client)
      logger:info ("Client " .. tostring (client) .. " is connecting...")
      client:on_message (function (_, message)
        from_client (client, message)
      end)
      client:on_close (function ()
        if client.editor then
          client.editor:close()
          client.editor = nil
        end
        client:close ()
        logger:info ("Client " .. tostring (client) .. " has disconnected.")
      end)
    end,
  }
}

logger:info ("Listening on port " .. tostring (port) .. ".")
logger:info "Entering main loop..."
ev.Loop.default:loop ()
