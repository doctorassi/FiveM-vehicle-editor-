# FiveM Vehicle Editor

An in-game handling and performance editor for FiveM, built on **ox_lib**.

Pick the vehicles you want to manage in a config file, give each one a tier from
1 to 5, and tune it in game. Every field shows its **vanilla value next to its
current value**, so you can always see exactly what you changed and by how much.
Edits are written to a real `handling.meta`, which means they are still there
after a restart — applied by the game itself, before a single line of script
runs.

## Features

- **ox_lib menus** throughout — context menus, input dialogs, confirmations and notifications.
- **Config-driven vehicle list** — only the vehicles you list are managed.
- **Tiers 1–5**, each with its own absolute performance band and default mod loadout.
- **Original vs current** shown on every field, with the percentage change and the tier band.
- **Automatic generation** — roll the whole fleet at once, each car inside its own tier band.
- **Per-vehicle rolls** on request, at any tier you pick.
- **Performance mods** — engine, brakes, transmission, suspension, armour and turbo, with tier defaults and per-vehicle overrides.
- **Always saved** — every edit autosaves to `tunes.json` and is reloaded on startup, with `handling.meta` generated alongside it.
- **Live application** — saved values take effect immediately for every player, no restart needed.
- **Server-side authority** — ace-gated, with every value re-validated and clamped on the server.
- **ox_core support** (optional) — tunes apply the instant an ox_core vehicle spawns, player-owned mods are respected, and tier-aware wrappers around `Ox.CreateVehicle` / `Ox.SpawnVehicle` are exported.

## Requirements

- [ox_lib](https://github.com/overextended/ox_lib)
- [ox_core](https://github.com/overextended/ox_core) — **optional**, detected at runtime

## Installation

1. Drop this folder into your `resources` directory.
2. Add it to `server.cfg` **after** ox_lib:

   ```cfg
   ensure ox_lib
   ensure ox_core            # optional
   ensure fivem-vehicle-editor
   ```

   Start ox_core **before** this resource so the spawn hooks catch vehicles
   created during boot.

3. Grant yourself the ace permission:

   ```cfg
   add_ace group.admin vehicleeditor.admin allow
   ```

4. Start the server and run `/vehedit` in game.

The first time you open the menu the editor spawns each configured vehicle
briefly under the map to read its vanilla handling, then deletes it. This
happens once per vehicle and is what makes the "original value" column real
rather than guessed.

## Usage

### `/vehedit`

| Menu item | What it does |
|---|---|
| Edit *&lt;vehicle&gt;* | Jumps straight to the car you are sitting in or standing next to |
| Vehicles | Every vehicle in `Config.Vehicles` |
| Auto-generate every vehicle | Rolls random values for the whole fleet, each at its own tier |
| Save now | Forces an immediate write (edits autosave anyway) |
| Reload from disk | Throws away in-memory state and re-reads the saved tunes |

Inside a vehicle you get its tier, a **Randomize this vehicle** action, a
performance mods submenu, and the handling fields grouped into Engine,
Transmission, Brakes, Traction, Suspension and Chassis. Every field row reads:

```
Drive Force
0.3000  →  0.4200   +40.0%
```

with the vanilla value, the current value, the change, and the tier's band shown
in the side panel. Edited fields are marked with an icon in the tier's colour.
Selecting a field opens a number input; if the field has been changed, the
dialog also offers to restore the vanilla value.

### Console commands

| Command | Effect |
|---|---|
| `vehedit_autoall` | Roll every configured vehicle at its own tier |
| `vehedit_save` | Write `tunes.json` and `handling.meta` now |
| `vehedit_reload` | Re-read the saved tunes from disk |
| `vehedit_diag` | Report why saving is failing, then attempt a write |

## Configuration

Everything lives in `config.lua`.

### Vehicles

```lua
Config.Vehicles = {
    { model = 'sultan',  label = 'Karin Sultan',   tier = 3 },
    { model = 'adder',   label = 'Truffade Adder', tier = 5 },
}
```

`model` is the spawn name. `tier` is the starting tier, used by the automatic
generator and as the source of default performance mods.

Optionally add `handling = 'SOMETHING'` if a model's handling id differs from its
model name. It defaults to the uppercased spawn name, which is correct for
almost every vehicle.

### Tiers

Each tier defines **absolute** min/max bands, in `handling.meta` units, plus its
default mod levels:

```lua
[5] = {
    label = 'Tier 5 — Hyper',
    mods = { engine = 3, brakes = 2, transmission = 2, suspension = 3, armour = -1, turbo = true },
    fields = {
        fInitialDriveForce      = { min = 0.42,  max = 0.50 },
        fInitialDriveMaxFlatVel = { min = 196.0, max = 215.0 },
        fBrakeForce             = { min = 1.32,  max = 1.55 },
    },
},
```

Randomizing rolls a uniform random value inside each band, so every tier-5 car
lands in the same performance window regardless of what it was in vanilla. A
field with no band in a tier is left at its current value when rolling.

Mod level `-1` is stock; `0` is the first upgrade. A per-vehicle override set in
the menu always wins over the tier default.

## ox_core integration

Picked up automatically when `ox_core` is running, ignored entirely otherwise.
Configure it under `Config.OxCore`.

### What it does

**Applies on spawn.** ox_core creates vehicles server-side, so without this the
tune only lands on the next client sweep. The editor listens for
`ox:spawnedVehicle` and pushes the tune the moment the entity streams in.

**Respects owned vehicles.** ox_core persists a vehicle's performance mods in
its database as ox_lib `VehicleProperties`. Forcing tier mods onto a car a
player paid to upgrade would fight those saved properties on every spawn, so
vehicles with an `owner` or `group` keep their own mods by default — their
**handling is still tuned to the tier**, only the mods are left alone. Set
`Config.OxCore.ApplyModsToOwned = true` if tiers are meant to override player
upgrades.

**Bakes mods into properties.** For unowned ox_core vehicles the tier's mods are
written into the vehicle's properties via `setProperties`, so ox_core carries
them instead of every client re-forcing them each spawn.

### Exports

```lua
-- Create through ox_core with the tier's mods already in its properties.
-- Mirrors Ox.CreateVehicle(data, coords, heading).
local vehicle, err = exports['fivem-vehicle-editor']:CreateTieredVehicle(
    { model = 'sultan', owner = charId }, coords, heading)

-- Spawn a stored vehicle and guarantee the tune is applied immediately.
-- Mirrors Ox.SpawnVehicle(dbId, coords, heading). Saved mods are untouched.
local vehicle, err = exports['fivem-vehicle-editor']:SpawnTieredVehicle(dbId, coords, heading)

-- Explicitly write the tier's mods into an ox_core vehicle's SAVED properties.
-- This overwrites mods a player may have paid for, which is why it is never
-- automatic for an owned vehicle — a script has to ask.
local ok, err = exports['fivem-vehicle-editor']:ApplyTierProperties(entityId)

-- Read-only, for dealership and garage scripts.
local tune = exports['fivem-vehicle-editor']:GetVehicleTune('sultan')
--> { model, tier, values, edits, originals, mods, properties }
local tier = exports['fivem-vehicle-editor']:GetVehicleTier('sultan')
```

`CreateTieredVehicle` and `SpawnTieredVehicle` return `nil, err` rather than
throwing, so a failed spawn (model missing from ox_core's `vehicles.json`, or
not listed in `Config.Vehicles`) is reported instead of crashing the caller.

### Mod key mapping

This resource spells the config key `armour`; ox_lib uses `modArmor`. The
translation lives in `Util.ModsToProperties`:

| Editor | ox_lib property | Mod type |
|---|---|---|
| `engine` | `modEngine` | 11 |
| `brakes` | `modBrakes` | 12 |
| `transmission` | `modTransmission` | 13 |
| `suspension` | `modSuspension` | 15 |
| `armour` | `modArmor` | 16 |
| `turbo` | `modTurbo` (boolean) | 18 |

## How saving works

There are two files, and only one of them is the source of truth.

**`tunes.json` — the save file.** A plain JSON file written with
`SaveResourceFile`, deliberately **not** declared in the manifest. Everything
lives here: tiers, vanilla originals, edits and mod overrides. It is read on
startup, and clients apply it through the handling natives.

**`handling.meta` — a bonus.** Registered in `fxmanifest.lua` so the game loads
tunes natively at resource start:

```lua
files { 'handling.meta' }
data_file 'HANDLING_FILE' 'handling.meta'
```

The split exists because a file the resource system owns is not reliably
writable at runtime. Anything in `files {}` / `data_file` can refuse a write —
`SaveResourceFile` reports success, and the original content is still on disk
afterwards. When that happens the editor reports it once and carries on:
**nothing is lost**, because the state is in `tunes.json` and the natives apply
it anyway. The only thing missing is the native load-at-startup shortcut.

Diagnostics tell the two failure modes apart by round-tripping a scratch file
the manifest does not declare. If that succeeds, the folder is writable and only
`handling.meta` is locked; if it fails, the server process cannot write into the
resource folder at all.

Tunes from an earlier version are migrated automatically: if there is no
`tunes.json`, `handling.meta` (or the older `data/handling.meta`) is read once
and written out to the new state file.

Each entry is preceded by an XML comment carrying the editor's own state:

```xml
<!-- vehicle-editor {"tier":5,"originals":{…},"edits":{…},"mods":{…}} -->
<Item type="CHandlingData">
  <handlingName>ADDER</handlingName>
  …
</Item>
```

The game's parser ignores XML comments, so it sees an ordinary handling file
while the editor can rebuild tiers, vanilla originals and the list of touched
fields after a restart. There is no database and no second state file.

Because the game only reads `handling.meta` when the resource starts, the editor
also pushes every saved value through the handling natives on all clients. A
save is live within one sweep (`Config.ApplyInterval`, 750 ms by default), and
the same values are already in the file for the next restart.

### If saving fails

The editor writes at boot, so a permissions problem shows up immediately rather
than after you have done work that cannot be kept. On failure it prints a
diagnostic naming the resource path, the target file, and whether the folder is
readable and writable, and every admin in game gets a notification — edits stay
in memory but would be lost on restart.

Saving is attempted twice: first through `SaveResourceFile`, then, if that fails
or writes nothing, directly through the filesystem, which also creates the `data`
folder if it is missing. Run `vehedit_diag` in the server console for the full
report. The usual causes are:

- **No `data` folder** — the direct write creates it; if that fails too, make one
  by hand inside the resource.
- **The resource folder is not writable by FXServer** — on Linux,
  `chown -R fxserver:fxserver <resource folder>`.
- **The resource is on a read-only mount, inside a zip, or escrow-protected** —
  writing is not possible; move it to a normal writable folder.

### Notes and limits

- `handling.meta` is **generated**. Entries carrying a `vehicle-editor`
  comment are rewritten on every save. Entries without one are preserved
  verbatim, so a hand-written entry is safe, but the tidier place for your own
  handling is your own resource.
- A complete `<Item>` is always written. A partial entry would make the game
  default every field it omits, which is why the vanilla snapshot is required
  before a vehicle can be saved.
- `SubHandlingData` is written as `NULL`. Vehicles that rely on subhandling data
  (hydraulics, boats, planes, some bikes) will lose those extras — this resource
  is aimed at cars.
- `AIHandling` is written as `AVERAGE`; there is no native to read the original.
- Handling flags (`strModelFlags`, `strHandlingFlags`, `strDamageFlags`) are
  written to the file faithfully but are not applied live, because swapping what
  a model fundamentally *is* on an already-spawned vehicle is not safe.

## Units

`handling.meta` and the game's runtime disagree about units for a handful of
fields. This resource stores, displays and configures everything in
**`handling.meta` units** — the ones you already know — and converts only at the
native boundary:

| Field | Meta unit | Runtime unit |
|---|---|---|
| `fSteeringLock`, `fTractionCurveLateral` | degrees | radians |
| `fInitialDriveMaxFlatVel` | km/h | m/s |
| `fInitialDragCoeff` | ×10000 | raw |
| `fBrakeBiasFront`, `fTractionBiasFront`, `fSuspensionBiasFront`, `fAntiRollBarBiasFront` | 0–1 | 0–2 |
| `fDriveBiasFront` | 0–1, with pure FWD/RWD special-cased | front/rear pair |

## Runtime notes

The CitizenFX Lua runtime is not full standard Lua: there is no `package`, no
`io`, and no filesystem library. `SaveResourceFile` and `LoadResourceFile` are
the only way to touch a file, which is the pattern this resource uses and
nothing else.

That matters more than it sounds. A reference to a missing library at **file
scope** raises at load time and aborts the rest of that file, so functions
declared below the failure are silently never defined while the ones above keep
working — and the failure surfaces much later, somewhere else, as `attempt to
call a nil value`.

No shipped file references `io`, `os` or `package` at all, and `tests/run.lua`
loads the resource with all three removed to prove it comes up whole.

The same applies to whole scripts. A server script that fails to load — or never
reaches the deployment at all — is not an error in FiveM: the globals it defines
are simply `nil`, and the first caller dies somewhere unrelated. The server
therefore checks on startup that every module it depends on is present and
reports what is missing by name, instead of crashing later:

```
[vehicle-editor] NOT STARTING — the resource did not load completely:
  - State is missing — server/meta.lua did not load
```

Persistence lives in `server/meta.lua` rather than a file of its own for the
same reason: one fewer script for a deployment to miss.

## Tests

The pure logic — unit conversion, clamping, tier rolls and the `handling.meta`
round trip — runs offline under plain Lua, with the natives stubbed:

```sh
lua5.4 tests/run.lua
```

Covers tier rolls staying inside their bands, values being clamped server-side,
non-finite input being rejected, originals never being overwritten once
captured, a save-then-restart restoring identical state, foreign entries
surviving a rewrite, a save being verified by read-back rather than by the
return value, tunes surviving a restart even when `handling.meta` refuses every
write, migration from the older layouts, the resource loading in a runtime
without `package`/`io`/`os`, and the ox_core property mapping and ownership
rules.

## Project layout

```
fxmanifest.lua        manifest, registers handling.meta as HANDLING_FILE
config.lua            vehicles, tiers, ace, mod types
shared/fields.lua     handling field catalogue and unit metadata
shared/util.lua       conversion, clamping, tier rolls, formatting
client/originals.lua  vanilla snapshot via a throwaway vehicle
client/apply.lua      live application sweep over the vehicle pool
client/menu.lua       ox_lib menus
server/store.lua      authoritative state, validation, tier rolls
server/meta.lua       persistence — tunes.json state, handling.meta, diagnostics
server/oxcore.lua     optional ox_core hooks and exports
server/main.lua       callbacks, autosave, startup load
tests/                offline test suite
```
