# kraken-cooler

Edit NZXT Kraken Plus pump and fan settings on Linux without NZXT CAM:
a CLI (`kraken-profile`) and a Quickshell window (`kraken-cooler`) for Omarchy.

## Use

- `kraken-cooler` opens the editor (also in the Omarchy menu: Setup, Cooling, Open editor).
  Drag fan-curve points, double-click to add one, right-click to delete one, or type exact values.
  Number fields accept the keypad, with NumLock on or off. `Ctrl+Z` / `Ctrl+Shift+Z` (or the Undo and Redo buttons) step through edits;
  `Revert` goes back to the saved profile and can itself be undone.
  `Apply` writes to the cooler only. `Save` stores a profile.
  `Save & Activate` also makes it the profile restored at login.
- `kraken-profile list|use NAME|apply|status [--json]|save NAME --pump N --fan "T D T D"|delete NAME`.
  `kraken-profile balanced` still works.

Built-in profiles (`quiet`, `balanced`, `performance`, `max`) are read-only; edit one and save it under a new name.
Custom profiles are `~/.config/kraken/profiles/NAME.toml`; the active name is in `~/.config/kraken/profile`.

## Limits

- The fan curve follows **liquid** temperature, 20-59 C, on the device itself; no daemon runs.
  The pump is a fixed duty, 20-100%.
- Warnings (fan under 70% at liquid 45 C, pump under 40%) are arbitrary defaults, not vendor limits.
  Change them under `[warn]` in `~/.config/kraken/config.toml` (`fan_at_temp`, `fan_min`, `pump_min`).
- The device cannot report its stored curve. After `Apply` the editor compares the fan duty the device reports
  with the curve at the current liquid temperature and shows whether they match.

## Install

Needs `liquidctl`, `quickshell` and Python 3.11+. Link the two commands into `~/.local/bin`:

    ln -sf "$PWD/kraken_cooler.py" ~/.local/bin/kraken-profile
    ln -sf "$PWD/kraken-cooler" ~/.local/bin/kraken-cooler

Apply the active profile at login with a user service that runs `kraken-profile apply`.

## AI disclosure

Written with Claude Code, with a human setting the design and testing it on their own cooler.
