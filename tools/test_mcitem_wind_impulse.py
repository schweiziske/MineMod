"""Wind charge/mace regression: python tools/test_mcitem_wind_impulse.py.

Loads production Lua with LuaJIT 2.1. Tests movement snapshot ordering, launch
conversion and fall protection. Engine collision/networking are test doubles.
"""
from pathlib import Path
from lupa import luajit21

ROOT = Path(__file__).resolve().parents[1]
BOOT = r'''
SERVER = true
CLIENT = false
FCVAR_ARCHIVE = 1
FCVAR_NOTIFY = 2
FCVAR_REPLICATED = 4
MOVETYPE_FLY = 4
MOVETYPE_FLYGRAVITY = 5
MOVETYPE_NOCLIP = 8
DMG_SHOCK = 256
DMG_FALL = 32
DMG_CLUB = 128
NULL = {}
unpack = unpack or table.unpack

function istable(value) return type(value) == "table" end
function isfunction(value) return type(value) == "function" end
function isstring(value) return type(value) == "string" end
function isnumber(value) return type(value) == "number" end

local vectorMeta = {}
vectorMeta.__index = vectorMeta
function Vector(x, y, z) return setmetatable({ x = x or 0, y = y or 0, z = z or 0 }, vectorMeta) end
vector_origin = Vector(0, 0, 0)
function isvector(value) return getmetatable(value) == vectorMeta end
function vectorMeta.__add(left, right) return Vector(left.x + right.x, left.y + right.y, left.z + right.z) end
function vectorMeta.__sub(left, right) return Vector(left.x - right.x, left.y - right.y, left.z - right.z) end
function vectorMeta.__mul(left, right)
    if type(left) == "number" then return Vector(left * right.x, left * right.y, left * right.z) end
    if type(right) == "number" then return Vector(left.x * right, left.y * right, left.z * right) end
    error("vector multiplication requires one scalar")
end
function vectorMeta:LengthSqr() return self.x * self.x + self.y * self.y + self.z * self.z end

function math.Clamp(value, minimum, maximum)
    if value < minimum then return minimum end
    if value > maximum then return maximum end
    return value
end
function math.Rand(minimum, maximum) return minimum + (maximum - minimum) * math.random() end
function CurTime() return 10 end
function GetConVar(name)
    if name == "sv_gravity" then return { GetFloat = function() return 600 end } end
end

function table.Copy(value)
    if type(value) ~= "table" then return value end
    local copied = {}
    for key, nested in pairs(value) do copied[key] = table.Copy(nested) end
    return copied
end

local timers = {}
timer = {}
function timer.Simple(_delay, callback) timers[#timers + 1] = callback end
local function runTimers(limit)
    limit = limit or 256
    local count = 0
    while #timers > 0 do
        count = count + 1
        assert(count <= limit, "timer fixture did not terminate")
        local callback = table.remove(timers, 1)
        callback()
    end
end

local hooks = {}
hook = {}
function hook.Add(event, identifier, callback)
    hooks[event] = hooks[event] or {}
    hooks[event][identifier] = callback
end
function hook.Remove(event, identifier)
    if hooks[event] then hooks[event][identifier] = nil end
end
function hook.Run(event, ...)
    for _, callback in pairs(hooks[event] or {}) do
        local result = callback(...)
        if result ~= nil then return result end
    end
end

util = { AddNetworkString = function() end }
resource = { AddFile = function() end }
sound = { Play = function() end }
game = { GetWorld = function() return { valid = true } end }
ents = { FindInBox = function() return {} end }
local arrowDefinition = {}
function arrowDefinition:HitEntity(target)
    if target.acceptArrow ~= false then target.health = target.health - 1 end
    return target
end
scripted_ents = {
    GetStored = function(className)
        if className == "mcitem_arrow" then return { t = arrowDefinition } end
    end,
}

local messages = {}
local currentMessage
net = {}
function net.Start()
    currentMessage = { seedParts = {} }
    messages[#messages + 1] = currentMessage
end
function net.WriteUInt(value, bits)
    if bits == 32 then currentMessage.effectId = value end
    if bits == 24 then currentMessage.seedParts[#currentMessage.seedParts + 1] = value end
end
function net.WriteVector(value) currentMessage.position = value end
function net.WriteFloat(value) currentMessage.duration = value end
function net.SendPVS() currentMessage = nil end

function CreateConVar(_name, default)
    return {
        GetBool = function() return default ~= "0" end,
        GetFloat = function() return tonumber(default) or 0 end,
    }
end

function IsValid(value) return type(value) == "table" and value.valid == true end

MC = { API = { World = {} } }
function MC.API.World.TriggerExplosion(_position, _radius, _options) return true end
function MC.ArmorDamageAfterAbsorb(damage, armor, toughness)
    damage = math.max(0, tonumber(damage) or 0)
    armor = math.Clamp(tonumber(armor) or 0, 0, 20)
    toughness = math.max(0, tonumber(toughness) or 0)
    local effective = math.Clamp(armor - damage / (2 + toughness / 4), armor * 0.2, 20)
    return damage * (1 - effective / 25)
end

MCITEM = {
    BlockSize = function() return 36.5 end,
    KnockbackScale = function() return 0.3 end,
    Explosions = {},
}
function MCITEM.ScaleDamage(value) return (tonumber(value) or 0) * 5 end
function MCITEM.UnscaleDamage(value) return math.max((tonumber(value) or 0) / 5, 0) end
local explodedConfiguration
function MCITEM.Explosions.GetKnockbackResistance() return 0 end
function MCITEM.Explosions.ApplyKnockback(target, velocity, context)
    local scale = tonumber(context and context.velocityScale) or MCITEM.KnockbackScale()
    target:SetVelocity(velocity * scale)
    return true
end
function MCITEM.Explosions.Explode(configuration)
    explodedConfiguration = configuration
    return {}, {}
end

local maceDefinition = {}
function maceDefinition:MCGetAttackDamageBonus()
    return 0, { fallDistance = tonumber(self.testFallDistance) or 4 }
end
function maceDefinition:MCPostAttack() end
weapons = {
    GetStored = function(className)
        if className == "weapon_mcitem_mace" then return maceDefinition end
    end,
}

'''
CHECKS = r'''

-- This fixture intentionally separates the entity and its in-flight MoveData.
-- Direct entity writes cannot repair a movement snapshot already being run.
local luaRoot = TEST_LUA_ROOT
MOVETYPE_WALK = 2
local now, gravity, blockSize = 10, 600, 36.5
function CurTime() return now end
function GetConVar() return { GetFloat = function() return gravity end } end
function MCITEM.BlockSize() return blockSize end
function AddCSLuaFile() end
function include(path)
    if path == 'mcitem/explosions/sv_wind_impulse.lua' then dofile(luaRoot .. path) end
end
function vectorMeta:Length() return math.sqrt(self:LengthSqr()) end
function vectorMeta:Distance(v) return (self-v):Length() end
function vectorMeta:Normalize()
    local n = self:Length()
    if n > 0 then self.x, self.y, self.z = self.x/n, self.y/n, self.z/n end
end
function vectorMeta.__div(a,b) return Vector(a.x/b,a.y/b,a.z/b) end
function MCITEM.PlayRangedSound() end
ents.FindInSphere = function() return {} end
MCITEM.Throwables = { TickSeconds = 0.05 }
dofile(luaRoot .. 'mcitem/explosions/sv_core.lua')
dofile(luaRoot .. 'mcitem/throwables/sv_damage.lua')
SWEP = { BaseClass = { Think = function() end } }
dofile(luaRoot .. 'weapons/weapon_mcitem_mace/shared.lua')
maceDefinition = SWEP
dofile(luaRoot .. 'mcitem/enchantments/sh_runtime.lua')
runTimers()
local Wind = MCITEM.WindImpulse
local function close(a,b,reason) assert(math.abs(a-b)<1e-6, reason..': '..a..' / '..b) end
local function javaRise(v)
    local h = 0
    while v > 0 do h = h+v; v = (v-0.08)*0.98 end
    return h
end

local p = { valid=true, position=Vector(), velocity=Vector(), grounded=false, alive=true, gravity=0 }
function p:IsPlayer() return true end
function p:IsNPC() return false end
function p:IsNextBot() return false end
function p:IsWorld() return false end
function p:IsOnGround() return self.grounded end
function p:Alive() return self.alive end
function p:InVehicle() return false end
function p:WaterLevel() return 0 end
function p:GetMoveType() return MOVETYPE_WALK end
function p:GetGravity() return self.gravity end
function p:GetPos() return self.position end
function p:SetPos(v) self.position=v end
function p:GetVelocity() return self.velocity end
function p:EyePos() return self.position+Vector(0,0,1.62*blockSize) end
function p:SetVelocity() error('wind must not write player basevelocity') end
function p:SetAbsVelocity() error('wind must not write outside MoveData') end
function p:SetGroundEntity() self.grounded=false end
function p:SetSaveValue() end
function p:GetMCExplosionExposure() return self.exposure or 1 end
local function moveSnapshot()
    local move={ v=Vector(p.velocity.x,p.velocity.y,p.velocity.z) }
    function move:GetVelocity() return self.v end
    function move:SetVelocity(v) self.v=v end
    function move:GetOrigin() return p.position end
    return move
end
local target={valid=true}
function target:IsOnGround() return true end
function target:GetPos() return Vector() end
function target:WorldSpaceAABB() return Vector(-10,-10,0),Vector(10,10,60) end
local mace=setmetatable({valid=true,MCITEMEnchantmentStack={item='minecraft:mace',count=1,
    components={['minecraft:enchantments']={levels={}}}}},{__index=maceDefinition})
function mace:GetOwner() return p end
function mace:IsPlayer() return false end
local function attack()
    mace.MCLastFallZ=p.position.z+4*blockSize
    mace:Think()
    local _,context=mace:MCGetAttackDamageBonus(p,target,0,1)
    assert(context and context.fallDistance>=4)
    mace:MCPostAttack(p,target,context,10,true)
end

for _,bs in ipairs({36.5,48}) do
    blockSize=bs
    for _,g in ipairs({600,800}) do
        gravity=g
        for _,personal in ipairs({0,0.6,1.5}) do
            p.gravity=personal
            for level,multiplier in ipairs({1.2,1.75,2.2}) do
                mace.MCITEMEnchantmentStack.components['minecraft:enchantments'].levels['minecraft:wind_burst']=level
                local expected=math.sqrt(2*Wind.Gravity(p)*bs*javaRise(multiplier+.01))
                for _,incoming in ipairs({-80,-450,-850}) do
                    for _,midMove in ipairs({false,true}) do
                        Wind.Clear(p)
                        p.grounded=false; p.velocity=Vector(91,-27,incoming)
                        local mv=moveSnapshot()
                        if midMove then hook.Run('SetupMove',p,mv) end
                        attack()
                        if not midMove then hook.Run('SetupMove',p,mv) end
                        hook.Run('FinishMove',p,mv)
                        close(mv.v.z,expected,'first/repeated smash from any downward speed')
                        close(mv.v.x,91,'preserve horizontal x')
                        close(mv.v.y,-27,'preserve horizontal y')
                        hook.Run('SetupMove',p,mv); hook.Run('FinishMove',p,mv)
                        close(mv.v.z,expected,'do not repeat impulse on subsequent movement')
                        runTimers()
                    end
                end
            end
        end
    end
end
print('PASS: mace I/II/III, 2 block sizes, 2 world gravities, 3 player gravities, 3 incoming speeds, 2 movement timings')

blockSize=36.5; gravity=600; p.gravity=0
local projectile={valid=true,MCThrowableRuntime={kind='wind_charge'}}
function projectile:GetOwner() return p end
function projectile:IsWorld() return false end
ents.FindInBox=function() return {p} end
for _,personal in ipairs({0,0.6,1.5}) do
    p.gravity=personal; p.position=Vector(0,0,0); p.velocity=Vector(); p.grounded=true
    Wind.Clear(p)
    local affected=MCITEM.Throwables.ExplodeWindCharge(Vector(0,0,.25*blockSize),projectile)
    assert(#affected==1 and affected[1].damage==0)
    local mv=moveSnapshot()
    hook.Run('SetupMove',p,mv); hook.Run('FinishMove',p,mv)
    local height=mv.v.z^2/(2*Wind.Gravity(p)*blockSize)
    close(height,javaRise(1.22*(1-.25/2.4)),'charge apex independent of player gravity')
    assert(height>6.8 and height<7.1)
    print(string.format('Charge at feet: player gravity %.2f, calculated height %.4f blocks',personal,height))
    p.position.z=height*blockSize
    hook.Run('SetupMove',p,mv)
    p.position.z=0; p.grounded=true
    hook.Run('OnPlayerHitGround',p)
    assert(hook.Run('GetFallDamage',p)==0,'same-height landing must be safe')
    local damage={amount=100}
    function damage:IsDamageType(t) return t==DMG_FALL end
    function damage:GetDamage() return self.amount end
    function damage:SetDamage(d) self.amount=d end
    function damage:SetDamageForce() end
    assert(hook.Run('EntityTakeDamage',p,damage)==true and damage.amount==0)
    runTimers()
    assert(Wind.FallOrigins[p]==nil,'landed charge protection leaked')
    assert(hook.Run('GetFallDamage',p)==nil,'later ordinary fall was protected')
end

-- Below-origin damage, charge overwrite versus mace minimum, pearl clearing.
p.position=Vector(0,0,10*blockSize); p.grounded=false
Wind.ArmFallProtection(p,false)
p.position.z=20*blockSize; Wind.ArmFallProtection(p,true)
close(Wind.FallOrigins[p].originZ,10*blockSize,'mace preserves lower origin')
p.position.z=30*blockSize; Wind.ArmFallProtection(p,false)
close(Wind.FallOrigins[p].originZ,30*blockSize,'new charge replaces origin')
p.position.z=25*blockSize
assert(hook.Run('GetFallDamage',p)==10,'5 blocks below origin should cost 2 Java HP')
runTimers()
Wind.ArmFallProtection(p,false)
MCITEM.Throwables.TeleportEnderPearlOwner(p,Vector(0,0,0))
assert(not Wind.FallOrigins[p] and not Wind.Pending[p],'pearl must clear wind state before its own damage')

-- Zero-exposure callbacks still arm player charges; Breeze never grants it.
p.exposure=0; p.position=Vector(); p.grounded=true
Wind.Clear(p)
MCITEM.Throwables.ExplodeWindCharge(Vector(0,0,.25*blockSize),projectile)
assert(Wind.FallOrigins[p] and not Wind.Pending[p])
Wind.Clear(p); p.exposure=1
projectile.MCThrowableRuntime={kind='breeze_wind_charge',explosionStrength=3,knockbackMultiplier=1}
MCITEM.Throwables.ExplodeWindCharge(Vector(0,0,.25*blockSize),projectile)
assert(not Wind.FallOrigins[p] and Wind.Pending[p])
hook.Run('PlayerSpawn',p)
assert(not Wind.FallOrigins[p] and not Wind.Pending[p])
print('PASS: actual charge explosion, same/lower landings, damage hooks, chained origins, respawn and pearl cleanup, Breeze exclusion')

-- Two harmless ledges inside the charge grace window are two separate falls.
now=100; p.position=Vector(0,0,10*blockSize); p.grounded=false
Wind.ArmFallProtection(p,false)
for _,height in ipairs({8,6}) do
    now=now+.3; p.position.z=height*blockSize; p.grounded=true
    hook.Run('OnPlayerHitGround',p)
    assert(hook.Run('GetFallDamage',p)==0,'separate short falls were added together')
    runTimers()
    assert(Wind.FallOrigins[p], 'grace should retain origin on safe lower landing')
end
now=103
hook.Run('SetupMove',p,moveSnapshot()); runTimers()
assert(not Wind.FallOrigins[p], 'grace cleanup failed on ground')

-- Fall exemptions must work even when the wind hook answers before others.
for _,exemption in ipairs({'slow_falling','levitation','slime','water','honey'}) do
    p.position=Vector(0,0,20*blockSize); Wind.ArmFallProtection(p,false)
    p.position.z=10*blockSize
    MCITEM.Potions={HasEffect=function(_,id) return id==exemption end}
    MC.BlockPhysics={Enabled=function() return true end,
        SampleEntity=function() return {onName='minecraft:'..exemption..'_block'} end,
        Constants={honeyFallDamageModifier=.2}}
    MC.LiquidMoveContacts={[p]=exemption=='water' or nil}
    local wanted=exemption=='honey' and 5 or 0
    assert(Wind.FallDamage(p)==wanted, 'fall exemption/modifier lost: '..exemption)
    Wind.Clear(p); runTimers()
end
MCITEM.Potions=nil; MC.BlockPhysics=nil; MC.LiquidMoveContacts=nil

-- Contact before FinishMove must not consume protection for that new launch.
p.position=Vector(); p.grounded=true
Wind.ResetPlayerVertical(p,5); Wind.ArmFallProtection(p,true)
Wind.QueuePlayerImpulse(p,Vector(0,0,500),true)
hook.Run('OnPlayerHitGround',p)
hook.Run('FinishMove',p,moveSnapshot()); runTimers()
assert(Wind.FallOrigins[p], 'same-frame contact ate new launch protection')

-- Retain horizontal charge impulse if a smash resets Z in the same frame.
Wind.Clear(p)
Wind.QueuePlayerImpulse(p,Vector(10,20,100))
Wind.ResetPlayerVertical(p,5)
Wind.QueuePlayerImpulse(p,Vector(0,0,500),true)
p.velocity=Vector(91,-27,-400)
local mixed=moveSnapshot(); hook.Run('FinishMove',p,mixed)
close(mixed.v.x,101,'queued horizontal impulse x lost')
close(mixed.v.y,-7,'queued horizontal impulse y lost')
close(mixed.v.z,500,'mace did not replace queued/downward z')
print('PASS: safe repeated ledges, potion/liquid/block exemptions, same-frame ground contact, mixed impulses')
'''

if __name__ == '__main__':
    lua = luajit21.LuaRuntime(unpack_returned_tuples=True)
    lua.globals().TEST_LUA_ROOT = (ROOT / 'addons/mc_item/lua').as_posix() + '/'
    lua.execute(BOOT + CHECKS)
    parse = lua.eval('function(s,n) local f,e=loadstring(s,n); return f ~= nil,e end')
    for relative in ['mcitem/explosions/sv_wind_impulse.lua', 'mcitem/explosions/sv_core.lua',
                     'mcitem/throwables/sv_damage.lua', 'mcitem/enchantments/sh_runtime.lua',
                     'weapons/weapon_mcitem_mace/shared.lua']:
        path = ROOT / 'addons/mc_item/lua' / relative
        ok, error = parse(path.read_text(encoding='utf-8'), str(path))
        assert ok, error
    print('PASS: changed MineMod Lua syntax (LuaJIT 2.1)')
