#! /usr/bin/env lua

local logging   = require "logging"
logging.console = require "logging.console"
local logger    = logging.console "%level %message\n"
local json      = require "dkjson"
local cli       = require "cliargs"
local websocket = require "websocket"

cli:set_name ("client.lua")
cli:add_argument(
  "token",
  "identification token"
)
cli:add_argument(
  "url",
  "server URL"
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

local token        = args.token
local url          = args.url
local verbose_mode = args.v

local client = websocket.client.sync { timeout = 2 }

local ok, err = client:connect (url, 'cosy')
if not ok then
   print('Cannot connect: ', err)
end
client:send (json.encode {
  action   = "set-editor",
  token    = token,
  resource = "/models/model",
  url      = "ws://127.0.0.1:8081",
})
print (client:receive())
client:close ()

os.exit (1)

local ok, err = client:connect (url, 'cosy')
if not ok then
   print('Cannot connect: ', err)
end
client:send "/models/model"

client:send (json.encode {
  action = "get-model"
})
print (client:receive())

client:send (json.encode {
  action = "list-patches"
})
print (client:receive())

client:send (json.encode {
  action = "add-patch",
  origin = "me",
  data   = [[
  cosy.model = {}
  ]]
})
print (client:receive())

client:send (json.encode {
  action = "list-patches"
})
print (client:receive())

client:send (json.encode {
  action = "add-patch",
  origin = "me",
  data = [[
  cosy.model.x = "some text"
  cosy.model.y = 42
  ]]
})
print (client:receive())

client:send (json.encode {
  action = "get-model"
})
print (client:receive())

client:send (json.encode {
  action = "get-patches"
})
print (client:receive())

client:close()
