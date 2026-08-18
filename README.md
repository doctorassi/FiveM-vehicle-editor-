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
- **Always saved** — every edit autosaves to `data/handling.meta` and is reloaded on startup.
- **Live application** — saved values take effect immediately for every player, no restart needed.
- **Server-side authority** — ace-gated, with every value re-validated and clamped on the server.

## Requirements

- [ox_lib](https://github.com/overextended/ox_lib)

## Installation

1. Drop this folder into your `resources` directory.
2. Add it to `server.cfg` **after** ox_lib:

   ```cfg
   ensure ox_lib
   ensure fivem-vehicle-editor
   ```

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
| Save to handling.meta | Forces an immediate write (edits autosave anyway) |
| Reload from handling.meta | Throws away in-memory state and re-reads the file |

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
| `vehedit_save` | Write `data/handling.meta` now |
| `vehedit_reload` | Re-read `data/handling.meta` from disk |

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

## How saving works

`data/handling.meta` is both the file the game loads and the editor's save file.
It is registered in `fxmanifest.lua` as:

```lua
files { 'data/handling.meta' }
data_file 'HANDLING_FILE' 'data/handling.meta'
```

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

### Notes and limits

- `data/handling.meta` is **generated**. Entries carrying a `vehicle-editor`
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

## Tests

The pure logic — unit conversion, clamping, tier rolls and the `handling.meta`
round trip — runs offline under plain Lua, with the natives stubbed:

```sh
lua5.4 tests/run.lua
```

Covers tier rolls staying inside their bands, values being clamped server-side,
non-finite input being rejected, originals never being overwritten once
captured, a save-then-restart restoring identical state, and foreign entries
surviving a rewrite.

## Project layout

```
fxmanifest.lua        manifest, registers data/handling.meta as HANDLING_FILE
config.lua            vehicles, tiers, ace, mod types
shared/fields.lua     handling field catalogue and unit metadata
shared/util.lua       conversion, clamping, tier rolls, formatting
client/originals.lua  vanilla snapshot via a throwaway vehicle
client/apply.lua      live application sweep over the vehicle pool
client/menu.lua       ox_lib menus
server/store.lua      authoritative state, validation, tier rolls
server/meta.lua       handling.meta writer and parser
server/main.lua       callbacks, autosave, startup load
tests/                offline test suite
```
