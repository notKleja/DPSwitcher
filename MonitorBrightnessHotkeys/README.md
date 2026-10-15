# Monitor Brightness Hotkeys

A tiny, standalone macOS utility for setting external-monitor brightness to exactly 0% or 100% from global keyboard shortcuts.

## Shortcuts

- `Control-Option-Command-Down Arrow`: set all supported external displays to 0%.
- `Control-Option-Command-Up Arrow`: set all supported external displays to 100%.

The shortcuts use Carbon hot keys and do not require Accessibility permission.

## Runtime behavior

- Only one app instance can run.
- Closing the window keeps the shortcut listener alive and removes the app from the Dock and menu bar.
- The app registers its bundled background helper as a Login Item.
- Login launches stay hidden; opening the app normally reveals the small control window.
- The window also includes 0% and 100% buttons for manual verification.

## MonitorControl relationship

The DDC packet format, Apple Silicon `DCPAVServiceProxy` discovery, and private `IOAVServiceWriteI2C` transport are adapted directly from [MonitorControl](https://github.com/MonitorControl/MonitorControl). No code or backend from DPSwitcher is used. MonitorControl is MIT licensed; the required license text is included in `LICENSE-MonitorControl.txt` and in the built app's Resources directory.

The utility writes VESA MCCS brightness command `0x10` to every external DDC service, matching MonitorControl's all-displays shortcut behavior. Because this uses the same private Apple display APIs as MonitorControl, a future macOS update can require an app update.

## Build and test

```sh
./test.sh
./build.sh
```

The build output is `build/MonitorBrightnessHotkeys.app`. `build.sh` signs the nested Login Item first, then signs the containing app ad hoc.
