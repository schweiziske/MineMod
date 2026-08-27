# MCSWEP Engineering Rules

## Units, coordinate spaces, and Lua return values

- One Minecraft block is `MC.API.Coords.BlockSize()` Source units. Its current
  default is `36.5`, but runtime code must read the API instead of hard-coding
  `36.5`. Minecraft model/display values are dimensionless block ratios and
  must be multiplied by the current block size exactly once.
- Keep MC world space, Source engine space, and client render space distinct.
  Use `MC.API.Coords` conversion/query functions. Do not pass an MC-world
  vector directly to an engine trace or `Entity:SetPos` on a re-origining
  world.
- Treat every GLua function documented to return multiple values as unsafe
  behind `and`, `or`, parentheses, or another function argument. Lua preserves
  all results only when the call is the final expression in an assignment,
  return statement, or list-style table constructor. An `and`/`or` expression
  always collapses the nested call to one value.

Forbidden:

```lua
local minimum, maximum = Coords and Coords.EntityWorldAABB
	and Coords.EntityWorldAABB( entity )
local value, err = available and query() or nil
local first, second = ( query() )
```

Required:

```lua
local minimum, maximum
if Coords and Coords.EntityWorldAABB then
	minimum, maximum = Coords.EntityWorldAABB( entity )
end
if not isvector( minimum ) or not isvector( maximum ) then
	minimum, maximum = entity:WorldSpaceAABB()
end
```

Single-result capability checks may still use `and`/`or`. If the number of
returns is unknown, use the explicit branch form. Pay particular attention to
coordinate APIs because bounds, cell coordinates, and mutation APIs commonly
return two or more values.
