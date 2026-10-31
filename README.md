# Health Import

A native Swift / SwiftUI proof of concept for importing historic Strava activity exports into Apple Health. Everything the app does with your activities happens on your device.

**No account, backend, analytics, advertising, crash-reporting service or networking code.** No third-party dependencies. Export files are read in memory, not copied into the app. A small, protected local journal supports duplicate protection, interrupted-import recovery and undo; it is excluded from device backups.

Apple Health can sync through iCloud when the user enables it. Files selected from a cloud provider may be downloaded by that provider. The promise is **“this app never uploads your activities”**, not a promise about Apple's services or other apps. See [PRIVACY.md](PRIVACY.md).

## First milestone

Import one years-old workout, repeat without creating another copy, then undo it. This is a POC, not a complete archive migration tool or an available App Store release.

Currently supported:

* Individual UTF-8 TCX activity files containing runs or rides
* Original timestamps, timer duration, distance, recorded heart-rate samples and GPS route
* A review screen and explicit user confirmation before any Health write
* Stable per-activity identifiers, a persistent import journal and conservative matching against visible Health workouts
* Undo for this app's workout, route and associated samples, including interrupted imports
* A clearly labelled synthetic 2018 example (read-only on physical devices; writable only to simulator Health)

Limits:

* Up to 20 files, 20 MB combined, 100 activities and 100,000 track points per selection; each activity is confirmed individually
* FIT, GPX, ZIP archives, other sports, ongoing Strava sync and edited-workout reconciliation are not implemented
* Calories, cadence and power are not imported; TCX does not distinguish active from total calories
* No fabricated sensor readings, pause events, calories, location accuracy or missing data
* Ambiguous duplicates are blocked, with no override in this first POC
* Read permission can be denied or limited without a distinguishable empty-result error. Users must allow full workout history and review the date in Health. Cross-app duplicate prevention cannot be guaranteed when Health hides data
* When compiled with Xcode 27.1 / Swift 6.4 or later, the app also checks iOS 27's earliest-authorised-date API and blocks imports outside a known limited history window. Older toolchains retain the explicit user review safeguard
* Activity rings, awards and physical-device behaviour need separate acceptance testing
* Uninstalling the app does not delete its Health data, but removes its local undo journal. Check results and undo unwanted imports before uninstalling

## Run

Open `HealthImport.xcodeproj` in Xcode 16 or later (Swift 6). The deployment target is iOS 17. Select the `HealthImport` scheme and an iPhone simulator.

For a physical device, copy `Config/LocalSigning.xcconfig.example` to `Config/LocalSigning.xcconfig` and set your development team ID. The local file is ignored by Git and supplies signing for the app and test target. Sign into Xcode's Apple Accounts settings, select your iPhone as the run destination and run. HealthKit must be enabled in the app's explicit provisioning profile; a wildcard profile cannot sign it. If command-line automatic provisioning reports no accounts despite an existing Xcode account, select the team once in Xcode's Signing & Capabilities editor to let Xcode create the profile.

The Xcode project is checked in. `project.yml` is its XcodeGen source; after changing project configuration, run `xcodegen generate` and commit the generated project too.

```sh
swift test
xcodebuild -project HealthImport.xcodeproj -scheme HealthImport \
  -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build
```

For the HealthKit integration test, first import the synthetic example in a dedicated simulator and grant Health access. The test checks saved values, duplicate matching, route/sample counts and scoped undo. It skips on physical devices and simulators without write permission. Use that simulator's ID:

```sh
xcodebuild -project HealthImport.xcodeproj -scheme HealthImport \
  -destination 'platform=iOS Simulator,id=YOUR_SIMULATOR_ID' \
  -parallel-testing-enabled NO test
```

Signing-team settings are machine-local. There is no App Store Connect app record or TestFlight delivery workflow configured in this repository. A local development installation and a simulator build are separate from a TestFlight beta.

Keep default ad-hoc signing enabled when running or testing in a simulator; `CODE_SIGNING_ALLOWED=NO` above is only a compilation check and does not embed the simulated HealthKit entitlement.

## Try an export

1. Export one of your own activities as TCX from the Strava website. Strava documents appending `/export_tcx` to its activity URL. Do not commit the export; `PrivateExports/` is ignored for local work
2. Transfer it to Files on the iPhone and choose it in Health Import
3. Review the date and measurements, check that date in Apple Health, and confirm the import
4. Allow the requested writes and full workout read access in the Health permission sheet
5. Verify the workout in Health/Fitness, then try the same file again. It should be blocked
6. Return to import history and undo. Verify removal of the workout and associated samples

The TCX export endpoint may be unavailable for activities without GPS; use original FIT files for those once FIT support is implemented. Original exported measurements may differ from Strava's subsequently corrected or recalculated values.

## Design

`ActivityImportCore` contains the bounded XML parser, stable identity, duplicate matching and durable import journal. It is a local Swift package with no dependencies and can be tested on macOS without HealthKit.

`App` contains the SwiftUI interface and the HealthKit writer. All import operations are serialised by the model. A journal entry is persisted before writing to Health, and every sample carries an app-specific transaction marker. On failure, cleanup targets that marker and the app's own Health source. An interrupted entry remains available for retrying cleanup. New imports are blocked while cleanup is pending.

The writer intentionally uses HealthKit's deprecated but available explicit-duration workout initializer and sample association API. TCX exports supply timer duration and an elapsed interval without an exact pause timeline. This preserves both without inventing pause events. A future `HKWorkoutBuilder` migration must retain this distinction; subtracting pauses from the end timestamp would corrupt chronology. Xcode currently reports the two expected deprecation warnings.

The parser rejects malformed XML, DTDs/entities, unsupported sports, non-finite measurements, invalid coordinates, unordered track timestamps, overlapping laps, inconsistent dates and oversized input. It never resolves external entities. The test fixture is entirely invented, not a user's export.

## References

* [Strava's export instructions](https://support.strava.com/en-us/articles/15401919-how-do-i-export-my-strava-data)
* [HealthKit permissions and limited history](https://developer.apple.com/documentation/healthkit/authorizing-access-to-health-data)
* [HealthKit sync identifiers](https://developer.apple.com/documentation/healthkit/hkmetadatakeysyncidentifier)
* [Manage Apple Health data and iCloud settings](https://support.apple.com/en-us/108779)
