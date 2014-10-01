local string_mt = getmetatable ""

function string_mt:__mod (parameters)
  return self:gsub (
    '($%b{})',
    function (w)
      return parameters[w:sub(3, -2)] or w
    end
  )
end

function string:quote ()
  if not self:find ('"') then
    return '"' .. self .. '"'
  elseif not self:find ("'") then
    return "'" .. self .. "'"
  end
  local pattern = ""
  while true do
    if not (   self:find ("%[" .. pattern .. "%[")
            or self:find ("%]" .. pattern .. "%]")) then
      return "[" .. pattern .. "[" .. self .. "]" .. pattern .. "]"
    end
    pattern = pattern .. "="
  end
end

function string:is_identifier ()
  local i, j = self:find ("[_%a][_%w]*")
  return i == 1 and j == #self
end
