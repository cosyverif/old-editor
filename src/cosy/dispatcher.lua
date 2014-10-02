#! /usr/bin/env lua

local global = _ENV or _G

local defaults = {
  interface = "127.0.0.3",
  port      = 80,
  image     = "saucisson/cosy-editor:testing-i386",
}

if global.cli then
  -- Called from another script
  return defaults
end

global.cli      = require "cliargs"
local logging   = require "logging"
logging.console = require "logging.console"
local logger    = logging.console "%level %message\n"

global.cli:set_name ("dispatcher.lua")
global.cli:add_option(
  "--interface=<IP address>",
  "interface to use",
  tostring (defaults.interface)
)
global.cli:add_option(
  "--port=<number>",
  "port to use",
  tostring (defaults.port)
)
global.cli:add_option(
  "--image=<docker ID>",
  "port to use",
  tostring (defaults.image)
)
global.cli:add_flag(
  "-v, --verbose",
  "enable verbose mode"
)
local args = global.cli:parse_args ()
if not args then
  global.cli:print_help()
  os.exit (1)
end

local interface    = args.interface
local port         = args.port
local image        = args.image
local verbose_mode = args.verbose

local editor_configuration = require "cosy.editor"

local ev        = require "ev"
local json      = require "dkjson"
local websocket = require "websocket"
local http      = require "socket.http"
local _         = require "cosy.util.string"

if verbose_mode then
  logger:setLevel (logging.DEBUG)
else
  logger:setLevel (logging.INFO)
end

local editors = {}

local function execute (command)
  local f = io.popen (command, "r")
  local outputs = {}
  for line in f:lines () do
    outputs [#outputs + 1] = line
  end
  return outputs
end

local function instantiate (resource)
  local editor = editors [resource]
  if editor then
    return editor
  end
  local cid
  local url
  local editor_port = editor_configuration.port
--[=[
  do
    local command = ([[
nohup lua cosy/editor.lua ${resource} > /dev/null 2>&1 &
    ]]) % {
      port     = editor_port,
      resource = resource,
      image    = image,
    }
    logger:debug (command)
    url = "ws://127.0.0.3:6969/"
  end
--]=]
  do
    local command = ([[
editor="lua /usr/local/share/lua/5.2/cosy/editor.lua ${resource}"
docker.io run --detach --publish ${port} ${image} ${editor}'
    ]]) % {
      port     = editor_port,
      resource = resource,
      image    = image,
    }
    logger:debug (command)
    cid = execute (command) [1]
  end
  do
    local command = ([[
docker.io port ${cid} ${port}
    ]]) % {
      port = editor_port,
      cid  = cid,
    }
    logger:debug (command)
    url = "ws://" .. (execute (command) [1]) .. "/"
  end
  editors [resource] = url
  logger:info ("Resource " .. tostring (resource) ..
               " is now mapped to " .. tostring (url) .. ".")
  do
    local command = [[
      mktemp
    ]]
    logger:debug (command)
    local script_file = execute (command) [1]
    local script = ([[
#! /bin/bash
docker.io wait '${cid}'
docker.io rm ${cid}
docker.io rmi $(docker.io images | grep '${image}' | tr -s ' ' | cut -f 3 -d ' ')
rm -f ${script_file}
    ]]) % {
      cid         = cid,
      image       = image,
      script_file = script_file,
    }
    local f = io.open (script_file, "w")
    f:write (script)
    f:close ()
    command = ([[
chmod a+x ${script_file}
bash -c "nohup ${script_file} > /dev/null 2>&1 &"
    ]]) % {
      script_file = script_file,
    }
    logger:debug (command)
  --  execute (command)
  end
  return editors [resource]
end

local function from_client (client, message)
  local command = json.decode (message)
  if not command then
    client:send (json.encode {
      accepted = false,
      reason   = "Message is not valid JSON.",
    })
    return
  end
  local action = command.action
  if action ~= "connect" then
    client:send (json.encode {
      action   = command.action,
      accepted = false,
      reason   = "Illegal action '${action}'. It should be a 'connect' command." % {
        action = action
      },
    })
    return
  end
  local resource = command.resource
  if not resource then
    client:send (json.encode {
      action   = command.action,
      accepted = false,
      reason   = "No resource given.",
    })
    return
  end
  local username = command.username
  local password = command.password
  resource = resource:gsub ("/$", "")
  local url = resource
  if username then
    url = resource:gsub ("^http://", "http://${username}:${password}@" % {
      username = username,
      password = password,
    })
  end
  local answer, code = http.request (url)
  if not answer or code ~= 200 then
    client:send (json.encode {
      action   = command.action,
      accepted = false,
      reason   = "Resource unreachable, because ${reason}." % {
        reason = tostring (code)
      },
    })
    return
  end
  local editor = instantiate (resource)
  local retry  = true
  client.editor = websocket.client.ev { timeout = 2 }
  client.editor:on_open (function ()
    editors [resource] = editor
    client.editor:send (message)
  end)
  client.editor:on_error (function (_, err)
    print (err)
    editors [resource] = nil
    if retry then
      editor = instantiate (resource)
      retry  = false
      client.editor:connect (editor, 'cosy')
    else
      client.editor = nil
      client:send (json.encode {
        action   = command.action,
        accepted = false,
        reason   = "Unable to connect to resource server, because ${err}." % {
          err = err
        },
      })
      client:close ()
    end
  end)
  client.editor:on_close (function ()
    client.editor = nil
    client:send (json.encode {
      action   = "close",
      accepted = true,
      resource = resource,
    })
  end)
  client.editor:on_message (function (_, message)
    client:send (message)
  end)
  client:on_message (function (_, message)
    client.editor:send (message)
  end)
  client.editor:connect (editor, 'cosy')
end

websocket.server.ev.listen {
  interface = interface,
  port      = port,
  protocols = {
    cosy = function (client)
      logger:info ("Client " .. tostring (client) .. " is connecting...")
      client:on_message (from_client)
      client:on_close (function ()
        if client.editor then
          client.editor:close()
          client.editor = nil
        end
        logger:info ("Client " .. tostring (client) .. " has disconnected.")
      end)
    end,
  }
}

logger:info ("Listening on ws://${interface}:${port}." % {
  interface = interface,
  port      = port,
})
logger:info "Entering main loop..."
ev.Loop.default:loop ()
