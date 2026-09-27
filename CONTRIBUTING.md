# Contributing

Issues and pull requests are welcome.

- **Before opening a PR,** run `swift test` and `.build/debug/ShippersShip --keytest`. CI runs both.
- **Status logic** (what a PR's headline says and whether it needs you) lives in `Sources/ShipKit/ShipStatus.swift`. Please add a test in `Tests/ShipKitTests` when you change it.
- **New filter qualifiers** go in `Sources/ShipKit/PRFilter.swift`, with tests in `PRFilterTests.swift`. Also update the syntax help in `SettingsView.swift` and the README.
- **UI changes:** regenerate the README screenshot with `.build/debug/ShippersShip --snapshot docs/screenshot.png --demo`, and extend `DemoData.swift` if you need a new state to show off.
- **Releases** are cut by pushing a `v*` tag. The Release workflow tests, builds, zips, and publishes the app.
