#! /usr/bin/env lua

local logging   = require "logging"
logging.console = require "logging.console"
local logger    = logging.console "%level %message\n"
local json      = require "dkjson"
local cli       = require "cliargs"
local websocket = require "websocket"

cli:set_name ("token.lua")
cli:add_argument(
  "admin-token",
  "administration token"
)
cli:add_argument(
  "url",
  "editor URL"
)
cli:add_argument(
  "user-token",
  "user token"
)
cli:add_argument(
  "can-read",
  "has user read permission?"
)
cli:add_argument(
  "can-write",
  "has user write permission?"
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

local admin_token  = args ["admin-token"]
local user_token   = args ["user-token"]
local can_read     = args ["can-read"]
local can_write    = args ["can-write"]
local url          = args.url
local verbose_mode = args.v

local client = websocket.client.sync { timeout = 2 }
local ok, err = client:connect(url, 'cosy')
if not ok then
   logger:error ('Cannot connect: ' .. err)
   os.exit (1)
end

client:send (json.encode {
  action    = "set-token",
  token     = admin_token,
  for_token = user_token,
  can_read  = can_read:lower() == "true",
  can_write = can_write:lower() == "true",
})
local answer = json.decode (client:receive())
client:close ()

logger:info ("Accepted? " .. tostring (answer.accepted))
if answer.accepted then
  os.exit (0)
else
  os.exit (1)
end
