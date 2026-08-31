Bartering = Bartering or {}

Bartering.Weapons = {
    {
        item = "Base.Pistol",
        weaponType = "Pistol",
        primaryType = "handgun",
        projectileCount = 1,
        ammoItem = "Base.Bullets9mm",
    },
    {
        item = "Base.Shotgun",
        weaponType = "Rifle",
        primaryType = "rifle",
        projectileCount = 5,
        ammoItem = "Base.ShotgunShells",
    },
    {
        item = "Base.AssaultRifle",
        weaponType = "Rifle",
        primaryType = "rifle",
        projectileCount = 1,
        ammoItem = "Base.223Bullets",
    },
}

Bartering.DEFAULT_WEAPON_CHOICE = 3

function Bartering.getBartererWeapon(bartererId)
    local choice = Bartering.getSandboxNumber(tostring(bartererId or "") .. "Weapon", Bartering.DEFAULT_WEAPON_CHOICE)
    return Bartering.Weapons[choice] or Bartering.Weapons[Bartering.DEFAULT_WEAPON_CHOICE]
end

local function initBarterer(def)
    local loc = def.spawnLocations[1]
    def.x = loc.x
    def.y = loc.y
    def.z = loc.z
    return def
end

Bartering.Barterers = {
    Barterer1 = initBarterer({
        id = "Barterer1",
        spawnLocations = {
            {x = 10168, y = 12634, z = 0},
            {x = 10616, y = 9829, z = 1},
        },
        travelSecondsPerTile = 30 / 82.855,
        stockWeight = Bartering.Stock.getEffectiveCapacity(),
        stockCount = 4,
        requiredLevel = 0,
        gender = "male",
        equipment = {
            knife = "Base.HuntingKnife",
        },
    }),
    Barterer2 = initBarterer({
        id = "Barterer2",
        spawnLocations = {
            {x = 8150, y = 11317, z = 0},
        },
        travelSecondsPerTile = 30 / 82.855,
        stockWeight = Bartering.Stock.getEffectiveCapacity(),
        stockCount = 5,
        requiredLevel = 3,
        gender = "male",
        equipment = {
            knife = "Base.HuntingKnife",
        },
    }),
    Barterer3 = initBarterer({
        id = "Barterer3",
        spawnLocations = {
            {x = 11065, y = 10638, z = 0},
            {x = 11243, y = 8954, z = 0},
        },
        travelSecondsPerTile = 30 / 82.855,
        stockWeight = Bartering.Stock.getEffectiveCapacity(),
        stockCount = 6,
        requiredLevel = 6,
        gender = "male",
        equipment = {
            knife = "Base.HuntingKnife",
        },
    }),
    Barterer4 = initBarterer({
        id = "Barterer4",
        spawnLocations = {
            {x = 12428, y = 1303, z = 1},
            {x = 12419, y = 1318, z = 0},
        },
        travelSecondsPerTile = 30 / 82.855,
        stockWeight = Bartering.Stock.getEffectiveCapacity(),
        stockCount = 7,
        requiredLevel = 9,
        gender = "male",
        equipment = {
            knife = "Base.HuntingKnife",
        },
    }),


}
