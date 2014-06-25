local pretty = require "pl.pretty"

local websocket = require'websocket'
local client = websocket.client.sync { timeout = 2 }

local ok, err = client:connect('ws://localhost:8080', 'cosy')
if not ok then
   print('Cannot connect: ', err)
end

client:send [[
  { "action": "get-model" }
]]
print (client:receive())

client:send [[
  { "action": "list-patches" }
]]
print (client:receive())

client:send [[
  { "action": "add-patch", "origin": "me" }
  cosy.model = {}
]]
print (client:receive())

client:send [[
  { "action": "list-patches" }
]]
print (client:receive())

client:send [[
  { "action": "add-patch", "origin": "me" }
  cosy.model.x = 1
  cosy.model.y = 2
]]
print (client:receive())

client:send [[
  { "action": "get-model" }
]]
print (client:receive())


client:close()
