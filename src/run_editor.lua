#! /usr/bin/env lua

local lfs       = require "lfs"
local json      = require "dkjson"
local cli       = require "cliargs"
local websocket = require "websocket"

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

cli:set_name ("run_editor.lua")
cli:add_argument (
  "admin-token",
  "administration token"
)
cli:add_argument (
  "resource",
  "edited resource"
)
cli:add_option (
  "-p, --port=<NUMBER>",
  "port used by the editor",
  "6969"
)
cli:add_option (
  "-r, --root=<DIRECTORY>",
  "root of the Cosy files",
  "/home/alinard/projects/cosyverif/editor/src"
)
cli:add_option (
  "-d, --directory=<DIRECTORY>",
  "remote directory",
  "/home/cosyverif/resource/"
)
local args = cli:parse_args ()
if not args then
  cli:print_help()
  return
end

local root        = args ["root"]
local directory   = args ["directory"]
local admin_token = args ["admin-token"]
local resource    = args ["resource"]
local port        = args ["port"]

-- Editor does not exist, create it:
local string_mt = getmetatable ""
function string_mt:__call (parameters)
  return (self:gsub('($%b{})', function(w) return parameters[w:sub(3, -2)] or w end))
end

-- Try to connect to the editor:
local info_filename = ("${root}/${resource}/info.json") {
  root     = root,
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
  directory = directory,
}
local dockerfile = ("${root}/${resource}/Dockerfile") {
  root     = root,
  resource = resource,
}
docker:write (dockerfile)

do
  local command = ([[
    docker.io build --force-rm --rm --quiet --tag=${resource} ${root}/${resource}
  ]]) {
    root     = root,
    resource = resource,
  }
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
    editor="cosy-editor --port=${port} --safe --timeout=20 ${token} ${directory}"
    docker.io run --detach --publish ${port}  ${image} ${editor}
  ]]) {
    port      = port,
    token     = admin_token,
    directory = directory,
    image     = resource,
    root     = root,
    resource = resource,
  }
  cid = execute (command) [1]
end

do
  local command = ([[
    docker.io port ${cid} ${port}
  ]]) {
    port = port,
    cid  = cid,
  }
  url = "ws://" .. (execute (command) [1]) .. "/"
end

info.url = url
json.write (info, info_filename)

local command = ([[
  rm -f ${root}/${resource}/Dockerfile
  docker.io wait "${cid}"
  docker.io cp ${cid}:${directory}/model.lua     ${root}/${resource}/
  docker.io cp ${cid}:${directory}/model.version ${root}/${resource}/
  docker.io cp ${cid}:${directory}/patches       ${root}/${resource}/
  docker.io rm ${cid}
  docker.io rmi $(docker.io images | grep "${resource}" | tr -s ' ' | cut -f 3 -d ' ')
]]) {
  cid       = cid,
  root      = root,
  directory = directory,
  resource  = resource,
}
execute (command)

info.url = nil
json.write (info, info_filename)
