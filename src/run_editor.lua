#! /usr/bin/env lua

local logging   = require "logging"
logging.console = require "logging.console"
local logger = logging.console "%level %message\n"

local lfs       = require "lfs"
local json      = require "dkjson"
local cli       = require "cliargs"
local websocket = require "websocket"
local sha1      = require "sha1"

cli:set_name ("run_editor.lua")
cli:add_argument (
  "resource",
  "edited resource"
)
cli:add_argument (
  "model-directory",
  "directory storing the model"
)
cli:add_argument (
  "dispatcher-token",
  "administration token for the dispatcher"
)
cli:add_option (
  "--editor-token=<string>",
  "administration token for the editor",
  "generated"
)
cli:add_option (
  "--dispatcher-url=<url>",
  "URL of the dispatcher",
  "ws://localhost:80"
)
cli:add_flag(
  "-v, --verbose",
  "enable verbose mode"
)

local editor_defaults = require "editor"
local args = cli:parse_args ()
if not args then
  cli:print_help()
  return
end


local dispatcher_url    = args ["dispatcher-url"]
local model_directory   = args ["model-directory"]
local resource          = args ["resource"]
local dispatcher_token  = args ["dispatcher-token"]
local editor_token      = args ["editor-token"]
local editor_port       = editor_defaults.port
local editor_directory  = editor_defaults.directory
local verbose_mode      = args.verbose

if editor_token == "generated" then
  editor_token = sha1 (
    dispatcher_url .. "+" ..
    resource       .. "+" ..
    tostring (os.time ())
  )
end

if verbose_mode then
  logger:setLevel (logging.DEBUG)
else
  logger:setLevel (logging.INFO)
end

logger:info ("Dispatcher URL is '" .. dispatcher_url .. "'.")
logger:info ("Model directory is '" .. model_directory .. "'.")
logger:info ("Resource is '" .. resource .. "'.")
logger:info ("Dispatcher token is '" .. dispatcher_token .. "'.")
logger:info ("Editor token is '" .. editor_token .. "'.")
logger:info ("Editor port is '" .. tostring (editor_port) .. "'.")
logger:info ("Editor directory is '" .. editor_directory .. "'.")

function json.read (filename)
  local file = io.open (filename, "r")
  if not file then
    return nil
  end
  lfs.lock (file, "r")
  local contents = file:read ("*all")
  local result   = json.decode (contents)
  lfs.unlock (file)
  file:close ()
  if not contents then
    error ("File " .. tostring (filename) .. " does not contain valid JSON.")
  end
  return result
end

function string.read (filename)
  local file = io.open (filename, "r")
  if not file then
    return nil
  end
  lfs.lock (file, "r")
  local contents = file:read ("*all")
  lfs.unlock (file)
  file:close ()
  return contents
end

function json.write (data, filename)
  local contents = json.encode (data)
  local file = io.open (filename, "w")
  lfs.lock (file, "w")
  file:write (contents)
  lfs.unlock (file)
  file:close ()
end

function string.write (contents, filename)
  local file = io.open (filename, "w")
  lfs.lock (file, "w")
  file:write (contents)
  lfs.unlock (file)
  file:close ()
end

local string_mt = getmetatable ""
function string_mt:__call (parameters)
  return self:gsub (
    '($%b{})',
    function (w)
      return parameters[w:sub(3, -2)] or w
    end
  )
end


-- Try to connect to the editor:
local info_filename = ("${directory}/info.json") {
  directory = model_directory,
}
local info = json.read (info_filename)
if not info then
  logger:warn ("File " .. info_filename .. " does not exist.")
  info = {}
end
if info.url then
  local client = websocket.client.sync { timeout = 2 }
  local ok, err = client:connect(info.url, 'cosy')
  if ok then
    logger:info ("Editor is already running at " .. info.url .. ".")
    os.exit (0) -- editor already exists
  else
    logger:debug ("Editor is not running at " .. info.url ..
                  ", because " .. err .. ".")
    info.url = nil
  end
  client:close ()
end

-- Generate Dockerfile
do
  local model_file = ("${directory}/model.lua") {
    directory = model_directory,
  }
  if not lfs.attributes (model_file) then
    local model = ([[
cosy [ '${resource}' ] = {}
    ]]) {
      resource = resource,
    }
    model:write (model_file)
  end
  local patches_dir = ("${directory}/patches") {
    directory = model_directory,
  }
  if not lfs.attributes (patches_dir) then
    lfs.mkdir (patches_dir)
  end
  local dockerfile = ("${directory}/Dockerfile") {
    directory = model_directory,
  }
  local docker = ([[
FROM saucisson/cosy-editor:testing-amd64
MAINTAINER alban.linard@lsv.ens-cachan.fr

USER cosyverif
RUN mkdir -p ${directory}
ADD model.lua ${directory}/model.lua
ADD patches   ${directory}/patches
  ]]) { -- ADD model.lua ${directory}/model.lua
    directory = editor_directory,
  }
  docker:write (dockerfile)
end

local tag = sha1 (resource)
do
  local command = ([[
docker.io build --force-rm --rm --quiet --tag=${tag} ${directory} > /dev/null
  ]]) {
    directory = model_directory,
    tag      = tag
  }
  logger:debug (command)
  os.execute (command)
end

local cid
local url

local function execute (command)
  local f = io.popen (command, "r")
  local outputs = {}
  for line in f:lines () do
    outputs [#outputs + 1] = line
  end
  return outputs
end

do
  local command = ([[
editor="cosy-editor ${resource} ${token}"
docker.io run --detach --publish ${port}  ${image} ${editor}
  ]]) {
    port     = editor_port,
    token    = editor_token,
    resource = resource,
    image    = tag,
  }
  logger:debug (command)
  cid = execute (command) [1]
end

do
  local command = ([[
docker.io port ${cid} ${port}
  ]]) {
    port = editor_port, 
    cid  = cid,
  }
  logger:debug (command)
  url = "ws://" .. (execute (command) [1]) .. "/"
end

info.url = url
json.write (info, info_filename)

do
  local client = websocket.client.sync { timeout = 2 }
  local ok, err = client:connect (dispatcher_url, "cosy")
  if ok then
    client:send (json.encode {
      token     = dispatcher_token,
      action    = "set-editor",
      resource  = resource,
      url       = info.url,
    })
  else
    logger:debug (err)
  end
  client:close ()
end

do
  local command = [[
    mktemp
  ]]
  logger:debug (command)
  local script_file = execute (command) [1]
  local script = ([[
#! /bin/bash
rm -f ${model_directory}/Dockerfile
docker.io wait '${cid}'
docker.io cp ${cid}:${editor_directory}/model.lua     ${model_directory}/
docker.io cp ${cid}:${editor_directory}/model.version ${model_directory}/
docker.io cp ${cid}:${editor_directory}/patches       ${model_directory}/
docker.io rm ${cid}
docker.io rmi $(docker.io images | grep '${tag}' | tr -s ' ' | cut -f 3 -d ' ')
rm -f ${script_file}
  ]]) {
    cid              = cid,
    model_directory  = model_directory,
    editor_directory = editor_directory,
    script_file      = script_file,
    tag              = tag,
  }
  print (script)
  print (script_file)
  string.write (script, script_file)
  command = ([[
chmod a+x ${script_file}
bash -c "nohup ${script_file} > /dev/null 2>&1 &"
  ]]) {
    script_file = script_file,
  }
  logger:debug (command)
--  execute (command)
end
