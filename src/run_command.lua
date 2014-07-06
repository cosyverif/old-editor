#! /usr/bin/env lua

local logging   = require "logging"
logging.console = require "logging.console"
local logger    = logging.console "%level %message\n"
local json      = require "dkjson"
local cli       = require "cliargs"
local websocket = require "websocket"
local sha1      = require "sha1"

cli:set_name ("run_command.lua")
cli:add_argument (
  "url",
  "editor URL"
)
cli:add_argument (
  "command",
  "command in JSON"
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

local url          = args.url
local command      = args.command
local verbose_mode = args.v

if verbose_mode then
  logger:setLevel (logging.DEBUG)
else
  logger:setLevel (logging.INFO)
end

local client = websocket.client.sync { timeout = 2 }
local ok, err = client:connect(url, 'cosy')
if not ok then
   logger:error ('Cannot connect: ' .. err)
   os.exit (2)
end

local c = json.decode (command)
if not c then
  logger:error ("Command is not valid JSON.")
  os.exit (3)
end

local id = c.id
if not c.id then
  c.id = sha1 (tostring (os.time ()) .. "+" .. command)
  logger:debug ("Generated missing command identifier: " .. tostring (c.id))
end

client:send (json.encode (c))
local answer
while true do
  local msg = client:receive()
  if not msg then
    logger:error ("No answer received.")
    os.exit (4)
  end
  answer = json.decode (msg)
  if answer.answer == c.id then
    break
  end
end
client:close ()

print (json.encode (answer))
if answer.accepted then
  os.exit (0)
else
  os.exit (1)
end
