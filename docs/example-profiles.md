# Example Kraken profiles

These examples record how a Windows NZXT CAM curve was adapted for Linux and blended with the local `sweep-tuned` curve.
The TOML files use liquid temperature in °C and duty in percent.
To add either example to the profile list, copy its TOML file to `~/.config/kraken/profiles/` under an unused name.

## Windows CAM curve

[`windows-cam.toml`](../examples/profiles/windows-cam.toml) comes from the custom cooling graphs in a Windows NZXT CAM screenshot for the Kraken Plus.
Both channels used liquid temperature, and the pump graph showed 100% throughout.
Fan duties were estimated from the plotted points and rounded to whole percentages.

| Liquid temperature (°C) | 20–35 | 40 | 45 | 50 | 55 | 60 | 65 | 70 | 75 | 80 | 85 | 90–100 |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| CAM fan duty (%) | 30 | 35 | 42 | 50 | 57 | 63 | 69 | 75 | 78 | 84 | 90 | 100 |

Linear interpolation between 55°C and 60°C gives 61% at 58°C after rounding.
The Linux example ends at 59°C and 100% duty, matching the [driver's 59°C limit](https://github.com/liquidctl/liquidctl/blob/v1.16.0/liquidctl/driver/kraken3.py#L74) and its [100% failsafe](https://github.com/liquidctl/liquidctl/blob/v1.16.0/liquidctl/util.py#L185-L208).
The app's default warning is expected because the example calls for 42% fan duty at 45°C, below the app's 70% threshold.

## Blend with the local tuning curve

[`cam-sweep.toml`](../examples/profiles/cam-sweep.toml) averages the Linux CAM example and the local `sweep-tuned` profile.
The blend keeps fan duty close to CAM at low temperatures and ramps up sooner as the liquid warms.
The tuning profile used an 80% pump and these fan points.

| Liquid temperature (°C) | 25 | 28 | 32 | 36 | 40 |
| --- | ---: | ---: | ---: | ---: | ---: |
| `sweep-tuned` fan duty (%) | 25 | 35 | 55 | 75 | 100 |

The mean of the two pump settings is 90%.
At each stored fan point, interpolate each input curve linearly and hold its endpoint duty outside its range.
Average the two duties and round to the nearest integer, rounding halves up.
At 40°C, for example, 35% and 100% average to 67.5%, stored as 68%.
The example uses ten points to fit the editor's limit and retains the 59°C failsafe.
