package = "CosyVerif-Lang"
version = "master-1"

source = {
   url = "git://github.com/CosyVerif/lang",
}

description = {
  summary     = "CosyVerif Language for Formalisms & Models",
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
    ["cosy"                       ] = "src/cosy.lua",
    ["cosy.lang.cosy"             ] = "src/cosy/lang/cosy.lua",
    ["cosy.lang.data"             ] = "src/cosy/lang/data.lua",
    ["cosy.lang.iterators"        ] = "src/cosy/lang/iterators.lua",
    ["cosy.lang.message"          ] = "src/cosy/lang/iterators.lua",
    ["cosy.lang.tags"             ] = "src/cosy/lang/tags.lua",
    ["cosy.lang.view.make"        ] = "src/cosy/lang/view/make.lua",
    ["cosy.lang.view.observed"    ] = "src/cosy/lang/view/observed.lua",
    ["cosy.lang.view.synthesized" ] = "src/cosy/lang/view/synthesized.lua",
    ["cosy.lang.view.update"      ] = "src/cosy/lang/view/update.lua",
    ["cosy.util.http_require"     ] = "src/cosy/util/http_require.lua",
    ["cosy.util.shallow_copy"     ] = "src/cosy/util/shallow_copy.lua",
    ["cosy.util.type"             ] = "src/cosy/util/type.lua",
  },
}
