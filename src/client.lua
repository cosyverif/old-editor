#! /usr/bin/env lua

local pretty = require "pl.pretty"
local json   = require "dkjson"

local websocket = require'websocket'
local client = websocket.client.sync { timeout = 2 }

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
