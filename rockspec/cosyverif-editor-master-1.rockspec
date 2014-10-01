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
    ["dispatcher" ] = "src/dispatcher.lua",
    ["editor"     ] = "src/editor.lua",
    ["util.string"] = "src/util/string.lua",
  },
}
