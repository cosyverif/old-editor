package="lpack"
version="master-1"
source = {
  url = "git://github.com/LuaDist/lpack",
  branch = "master"
}
description = {
  summary = "A library for packing and unpacking binary data",
  detailed = [[
    A library for packing and unpacking binary data.
    The library adds two functions to the string library: pack and unpack.
  ]],
  homepage = "http://www.tecgraf.puc-rio.br/~lhf/ftp/lua/#lpack",
  license = "Public domain"
}
dependencies = {
  "lua >= 5.2"
}

build = {
  type = "builtin",
  modules = {
    pack = {
      defines = "luaL_reg=luaL_Reg",
      sources = "lpack.c",
    }
  }
}
