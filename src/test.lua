#! /usr/bin/env lua

      cli        = require "cliargs"
local dispatcher = require "dispatcher"
local logging    = require "logging"
logging.console  = require "logging.console"
local logger     = logging.console "%level %message\n"
local json       = require "dkjson"
local websocket  = require "websocket"
local _          = require "util/string"

cli:set_name ("client.lua")
cli:add_argument(
  "resource",
  "resource to edit"
)
cli:add_option (
  "--dispatcher=<URL>",
  "dispatcher URL",
  "ws://${server}:${port}" % {
    server = dispatcher.interface,
    port   = dispatcher.port,
  }
)
cli:add_flag (
  "-v, --verbose",
  "enable verbose mode"
)
local args = cli:parse_args ()
if not args then
  cli:print_help()
  return
end

local dispatcher_url = args.dispatcher
local resource       = args.resource
local verbose_mode   = args.verbose

logger:info ("Dispatcher is " .. dispatcher_url .. ".")
logger:info ("Resource is " .. resource .. ".")
logger:info ("Verbose mode is " .. (verbose_mode and "on" or "off") .. ".")

-- Connect:
do
  local client = websocket.client.sync { timeout = 2 }
  local ok, err = client:connect (dispatcher_url, 'cosy')
  if not ok then error ('Cannot connect: ' .. err) end
  client:send (json.encode {
    action   = "connect",
    resource = resource,
  })
  print (client:receive())
  client:close ()
end

os.exit (1)

-- Perform user actions:
do
  local client = websocket.client.sync { timeout = 2 }
  local ok, err = client:connect (dispatcher_url, 'cosy')
  if not ok then error ('Cannot connect: ' .. err) end
  client:send (json.encode {
    token    = user_token,
    action   = "set-resource",
    resource = resource,
  })
  print (client:receive())

  client:send (json.encode {
    token    = user_token,
    action = "get-model"
  })
  print (client:receive())

  client:send (json.encode {
    token    = user_token,
    action = "list-patches"
  })
  print (client:receive())

  client:send (json.encode {
    token    = user_token,
    action = "add-patch",
    origin = "me",
    data   = [[
    cosy.model = {}
    ]]
  })
  print (client:receive())

  client:send (json.encode {
    token    = user_token,
    action = "list-patches"
  })
  print (client:receive())

  client:send (json.encode {
    token    = user_token,
    action = "add-patch",
    origin = "me",
    data = [[
    cosy.model.x = "some text"
    cosy.model.y = 42
    ]]
  })
  print (client:receive())

  client:send (json.encode {
    token    = user_token,
    action = "get-model"
  })
  print (client:receive())

  client:send (json.encode {
    token    = user_token,
    action = "get-patches"
  })
  print (client:receive())

  client:close()
end
