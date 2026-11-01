# Contributing

- Run tests: `python3 -m unittest discover -s tests`. They cover profile validation, the curve math and file handling; they never touch the device.
- All device and file access goes through `kraken_cooler.py`. The QML UI only calls the `kraken-profile` CLI,
  so a behavior change belongs in the CLI first.
- Device limits (curve 20-59 C, pump 20-100%) come from liquidctl's `kraken3` driver; recheck there before changing them.
- Check UI changes on the real window: `kraken-cooler`, then a screenshot. Mouse interaction has no automated test.
