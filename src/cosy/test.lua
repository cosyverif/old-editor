#! /usr/bin/env lua

local global = _ENV or _G

global.cli       = require "cliargs"
local logging    = require "logging"
logging.console  = require "logging.console"
local logger     = logging.console "%level %message\n"
local json       = require "dkjson"
local websocket  = require "websocket"
local _          = require "cosy.util.string"
local dispatcher = require "cosy.editor"
--local dispatcher = require "cosy.dispatcher"

global.cli:set_name ("client.lua")
global.cli:add_argument(
  "resource",
  "resource to edit"
)
global.cli:add_option (
  "--username=<string>",
  "username"
)
global.cli:add_option (
  "--password=<string>",
  "password"
)
global.cli:add_option (
  "--dispatcher=<URL>",
  "dispatcher URL",
  "ws://${server}:${port}" % {
    server = dispatcher.interface,
    port   = dispatcher.port,
  }
)
global.cli:add_flag (
  "-v, --verbose",
  "enable verbose mode"
)
local args = global.cli:parse_args ()
if not args then
  global.cli:print_help()
  return
end

local dispatcher_url = args.dispatcher
local resource       = args.resource
local username       = args.username
local password       = args.password
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
    username = username,
    password = password,
  })
  print (client:receive())
  client:send (json.encode {
    action   = "patch",
    resource = resource,
    username = username,
    password = password,
    data   = [[
cosy ["${resource}"].x = 1
cosy ["${resource}"].y = 1
    ]] % {
      resource = resource,
    }
  })
  print (client:receive())

  client:close ()
end
