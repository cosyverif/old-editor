package = "CosyVerif-Editor"
version = "master-1"

source = {
   url = "git://github.com/CosyVerif/editor",
}

description = {
  summary     = "CosyVerif Editor",
  detailed    = [[
  ]],
  homepage    = "http://www.cosyverif.org/",
  license     = "MIT/X11",
  maintainer  = "Alban Linard <alban.linard@lsv.ens-cachan.fr>",
}

dependencies = {
  "lua >= 5.1",
}

build = {
  type    = "builtin",
  modules = {
    ["cosy.dispatcher" ] = "src/cosy/dispatcher.lua",
    ["cosy.editor"     ] = "src/cosy/editor.lua",
    ["cosy.util.string"] = "src/cosy/util/string.lua",
  },
}
