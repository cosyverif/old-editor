#! /usr/bin/env lua

local logging   = require "logging"
logging.console = require "logging.console"
local logger    = logging.console "%level %message\n"
local json      = require "dkjson"
local cli       = require "cliargs"
local websocket = require "websocket"

cli:set_name ("client.lua")
cli:add_option (
  "--admin-token=<string>",
  "administration token",
  "123456"
)
cli:add_option (
  "--resource=<string>",
  "resource path",
  "/models/model"
)
cli:add_option (
  "--user-token=<string>",
  "user token",
  "the-user-token"
)
cli:add_option (
  "--dispatcher-url=<URL>",
  "dispatcher URL",
  "ws://localhost:8080"
)
cli:add_option (
  "--editor-url=<URL>",
  "editor URL",
  "ws://localhost:8081"
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

local admin_token    = args ["admin-token"]
local user_token     = args ["user-token"]
local dispatcher_url = args ["dispatcher-url"]
local editor_url     = args ["editor-url"]
local resource       = args ["resource"]
local verbose_mode   = args.v

logger:info ("Administration token is '" .. admin_token .. "'.")
logger:info ("User token is '" .. user_token .. "'.")
logger:info ("Dispatcher URL is " .. dispatcher_url .. ".")
logger:info ("Editor URL is " .. editor_url .. ".")
logger:info ("Resource path is " .. resource .. ".")
logger:info ("Verbose mode is " .. (verbose_mode and "on" or "off") .. ".")

-- Set editor:
do
  local client = websocket.client.sync { timeout = 2 }
  local ok, err = client:connect (dispatcher_url, 'cosy')
  if not ok then error ('Cannot connect: ' .. err) end
  client:send (json.encode {
    action   = "set-editor",
    token    = admin_token,
    resource = resource,
    url      = editor_url,
  })
  print (client:receive())
  client:close ()
end

-- Add token:
do
  local client = websocket.client.sync { timeout = 2 }
  local ok, err = client:connect (editor_url, 'cosy')
  if not ok then error ('Cannot connect: ' .. err) end
  client:send (json.encode {
    token     = admin_token,
    action    = "set-token",
    for_token = user_token,
    can_read  = true,
    can_write = true,
  })
  print (client:receive())
  client:close ()
end

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
