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

local directory    = args.directory
local admin_token  = args.token
local port         = args.p
local safe_mode    = args.s
local timeout      = tonumber (args.t) -- seconds
local verbose_mode = args.v

local client = websocket.client.sync { timeout = 2 }

local ok, err = client:connect('ws://localhost:8080', 'cosy')
if not ok then
   print('Cannot connect: ', err)
end

client:send "abcde"
client:send (json.encode {
  action = "set-token",
  token  = "my-token",
  ["can-read" ] = true,
  ["can-write"] = true,
})
print (client:receive())
client:close ()


local ok, err = client:connect('ws://localhost:8080', 'cosy')
if not ok then
   print('Cannot connect: ', err)
end
client:send "my-token"

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
