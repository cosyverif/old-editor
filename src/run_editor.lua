#! /usr/bin/env lua

local lfs       = require "lfs"
local json      = require "dkjson"
local cli       = require "cliargs"
local websocket = require "websocket"
local sha1      = require "sha1"

cli:set_name ("run_editor.lua")
cli:add_argument (
  "dispatcher-url",
  "URL of the dispatcher"
)
cli:add_argument (
  "root-directory",
  "root of the Cosy files"
)
cli:add_argument (
  "resource",
  "edited resource"
)
cli:add_argument (
  "dispatcher-token",
  "administration token for the dispatcher"
)
cli:add_argument (
  "editor-token",
  "administration token for the editor"
)

local editor_defaults = require "editor"
local args = cli:parse_args ()
if not args then
  cli:print_help()
  return
end


local dispatcher_url    = args ["dispatcher-url"]
local root_directory    = args ["root-directory"]
local resource          = args ["resource"]
local dispatcher_token  = args ["dispatcher-token"]
local editor_token      = args ["editor-token"]
local editor_port       = editor_defaults.port
local editor_directory  = editor_defaults.directory

function json.read (filename)
  local file = io.open (filename, "r")
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
  return (self:gsub('($%b{})', function(w) return parameters[w:sub(3, -2)] or w end))
end


-- Try to connect to the editor:
local info_filename = ("${root}/${resource}/info.json") {
  root     = root_directory,
  resource = resource,
}
local info = json.read (info_filename)
if not info then
  error ("File " .. info_filename .. " does not exist.")
end
if info.url then
  local client = websocket.client.sync { timeout = 2 }
  local ok, err = client:connect(info.url, 'cosy')
  if ok then
    os.exit (0) -- editor already exists
  else
    info.url = nil
  end
end

-- Generate Dockerfile
local docker = ([[
FROM saucisson/cosy-editor:testing-amd64
MAINTAINER alban.linard@lsv.ens-cachan.fr

USER cosyverif
RUN mkdir -p ${directory}
ADD model.lua     ${directory}/model.lua
ADD model.version ${directory}/model.version
ADD patches       ${directory}/patches
]]) {
  directory = editor_directory,
}
local dockerfile = ("${root}/${resource}/Dockerfile") {
  root     = root_directory,
  resource = resource,
}
docker:write (dockerfile)

local tag = sha1 (resource)

do
  local command = ([[
    docker.io build --force-rm --rm --quiet --tag=${tag} ${root}/${resource}
  ]]) {
    root     = root_directory,
    resource = resource,
    tag      = tag
  }
  print (command)
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
    editor="cosy-editor ${token}"
    docker.io run --detach --publish ${port}  ${image} ${editor}
  ]]) {
    port     = editor_port,
    token    = editor_token,
    image    = tag,
  }
  cid = execute (command) [1]
end

do
  local command = ([[
    docker.io port ${cid} ${port}
  ]]) {
    port = editor_port,
    cid  = cid,
  }
  url = "ws://" .. (execute (command) [1]) .. "/"
end

info.url = url
json.write (info, info_filename)

do
  local client = websocket.client.sync { timeout = 2 }
  local ok, err = client:connect(dispatcher_url, 'cosy')
  if ok then
    client:send (json.encode {
      token     = dispatcher_token,
      action    = "set-editor",
      resource  = resource,
      url       = info.url,
    })
  else
    os.exit (2)
  end
end

local command = ([[
  nohup bash -c "
  rm -f ${root}/${resource}/Dockerfile
  docker.io wait '${cid}'
  docker.io cp ${cid}:${directory}/model.lua     ${root}/${resource}/
  docker.io cp ${cid}:${directory}/model.version ${root}/${resource}/
  docker.io cp ${cid}:${directory}/patches       ${root}/${resource}/
  docker.io rm ${cid}
  docker.io rmi $(docker.io images | grep '${resource}' | tr -s ' ' | cut -f 3 -d ' ')
  " &
]]) {
  cid       = cid,
  root      = root,
  directory = directory,
  resource  = resource,
}
execute (command)
