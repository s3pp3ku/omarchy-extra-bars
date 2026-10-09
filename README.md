# Omarchy Extra Bars

Add more bars to the [Omarchy](https://omarchy.org) shell, on the **bottom, left or right** edge, and put your existing bar widgets in them. Omarchy runs one bar; this service adds the rest, so you can get a bar on every side of the screen.

Each widget is hosted as it is. It gets a bar interface that reports the real edge, so its popups open **away from the bar** (upward from a bottom bar), clicks and companion services work, and the bar uses your theme colors and size.

## Install

```sh
omarchy plugin add https://github.com/s3pp3ku/omarchy-extra-bars.git --enable --yes
```

Then create `~/.config/omarchy/extra-bars.json`:

```json
{
  "bars": [
    {
      "position": "bottom",
      "left": ["com.example.clock"],
      "center": ["io.github.someone.music"],
      "right": ["danielmrdev.sysinfo", { "id": "s3pp3ku.mlb", "favoriteTeam": "CLE" }]
    }
  ]
}
```

- `position`: `bottom`, `left` or `right` (your main bar owns the other edge; `omarchy bar position` moves it).
- `left` / `center` / `right`: widget ids, or objects with an `id` plus per-widget settings. Find ids with `omarchy plugin list`.
- The file is watched, so edits apply without a restart. Side bars lay widgets out vertically.

To avoid duplicates, take a widget off your main bar when you move it here (for example by editing `~/.config/omarchy/shell.json`).

## What works

- Popups flip away from the bar, and widgets that register click targets (like the system info widget) get their clicks.
- Widgets that read data from a companion service (for example Omaudix) get their own copy of it.
- Widgets with a text input can take the keyboard: the bar uses On-Demand keyboard focus plus a Hyprland focus grab, so clicking anywhere else gives the keyboard back.

## Pairs well with

[BarTerm](https://github.com/s3pp3ku/omarchy-barterm): a command prompt widget for the bar, with an output popup that opens above a bottom bar.

## Limits

- Hover tooltips are not shown on extra bars.
- Widgets that call host features beyond the bar interface (such as `bar.shellQuote`) may need adapting.
- One bar per screen edge per monitor; layouts are edited in the JSON file.

## License

MIT

## Transparency

Extra bars follow the main bar's transparency setting (`bar.transparent` in `shell.json`, toggled from Omarchy's Style > Menu Bar > Transparency), so every edge is either transparent or opaque together.

## Trays

Any bar can hold any number of **trays**: a chevron that slides a group of widgets out of it. Each tray keeps its own list:

```json
{ "id": "tray:t1", "widgets": ["com.leafbox.f1", "s3pp3ku.mlb"] }
```

Put the entry in a bar section next to the plain widget ids. A tray opens toward the middle of its bar (right or down from the start half, left or up from the end half), and its chevron points the way it will open, so dragging or moving it to the other side flips both. Click the chevron to keep it open; hovering also opens it. An empty tray shows just its chevron.

[Bar Manager](https://github.com/s3pp3ku/omarchy-bar-manager) can add, move and remove trays and put widgets into them (`barctl addtray`, `intray`, `rmtray`, or the `+ Tray` button and the tray column in its panel).
