# Health Import

A native Swift / SwiftUI proof of concept for importing Strava workouts into Apple Health. The current trial connects directly to Strava, lists a selected day (yesterday by default), and imports one reviewed run or ride. TCX exports remain an optional fallback.

**No app backend, analytics, advertising, crash-reporting service or third-party dependencies.** Authentication and activity requests go directly from the iPhone to Strava. Previews are held in memory without a disk cache. A small, protected local journal supports duplicate protection, interrupted-import recovery and undo; it is excluded from device backups.

Apple Health can sync through iCloud when the user enables it. Files selected from a cloud provider may be downloaded by that provider. The promise is **“this app never uploads your activities”**, not a promise about Apple's services or other apps. See [PRIVACY.md](PRIVACY.md).

## First milestone

Connect Strava, review yesterday’s workout, save it to Health, then check the result. A completed Strava import blocks further Strava imports until it is undone. Full-history sync comes after this acceptance check. This is a POC, not a complete archive migration tool or an available App Store release.

Currently supported:

* Native Strava sign-in, with a system browser fallback and validated OAuth state/callback/scope
* Direct activity reads with `activity:read_all`, Keychain token storage and coordinated token refresh
* A one-day activity list with pagination, local-calendar date boundaries and individual preview
* Individual UTF-8 TCX activity files containing runs or rides
* Original timestamps, distance, recorded heart-rate samples and GPS route; TCX timer duration or Strava elapsed duration
* Cycling power (with an estimated-power marker when applicable), cadence, speed, elevation gain and indoor/outdoor status from Strava
* Estimated pause/resume events from Strava movement samples and stationary recording gaps, with a preview and an option to retain elapsed duration
* Strava calories shown in preview, with an explicit choice to interpret them as active energy
* A review screen and explicit user confirmation before any Health write
* Stable per-activity identifiers, a persistent import journal and conservative matching against visible Health workouts
* Undo for this app's workout, route and associated samples, including interrupted imports
* A clearly labelled synthetic 2018 example (read-only on physical devices; writable only to simulator Health)

Limits:

* Up to 20 files, 20 MB combined, 100 activities and 100,000 track points per selection; each activity is confirmed individually
* FIT, GPX, ZIP archives, sports other than runs/rides, full-history/ongoing sync and edited-workout reconciliation are not implemented
* Strava does not provide Garmin's original timer events. Full-resolution movement samples and stationary recording gaps can estimate pauses; these are shown before importing and can be disabled. Health receives real pause/resume events without shifting sample timestamps. Workout duration excludes enabled pauses; Strava moving time remains separate. Fitness controls graph presentation
* Missing streams produce a summary-only preview. No heart-rate or route samples are invented
* TCX calories, cadence and power remain unsupported. Strava’s calorie value has no active/resting split: active energy is written only when the user enables that interpretation. No resting calories are fabricated
* Only available cycling streams become Health samples. Summary-only power/cadence averages are not expanded into invented time series. Device/Strava estimates retain their source limitations
* Route altitudes preserve the source's elevation profile, including zero and negative elevations. Missing altitudes remain invalid. Strava and TCX do not supply recording accuracy: imported route points use a documented 50 m accuracy assumption so Core Location treats supplied coordinates/altitudes as valid. Route metadata labels this assumption; it is not measured sensor precision or a guaranteed error bound
* No fabricated sensor readings, calorie totals or missing altitude values. Inferred pauses are explicitly labelled as estimates in the preview and Health event metadata
* Ambiguous duplicates are blocked, with no override in this first POC
* Read permission can be denied or limited without a distinguishable empty-result error. Users must allow full workout history and review the date in Health. Cross-app duplicate prevention cannot be guaranteed when Health hides data
* When compiled with Xcode 27.1 / Swift 6.4 or later, the app also checks iOS 27's earliest-authorised-date API and blocks imports outside a known limited history window. Older toolchains retain the explicit user review safeguard
* Activity rings, awards and physical-device behaviour need separate acceptance testing
* Uninstalling the app does not delete its Health data, but removes its local undo journal. Check results and undo unwanted imports before uninstalling

## Run

Open `HealthImport.xcodeproj` in Xcode 16 or later (Swift 6). The deployment target is iOS 17. Select the `HealthImport` scheme and an iPhone simulator.

For a physical device, copy `Config/LocalSigning.xcconfig.example` to `Config/LocalSigning.xcconfig` and set your development team ID. The local file is ignored by Git and supplies signing for the app and test target. Sign into Xcode's Apple Accounts settings, select your iPhone as the run destination and run. HealthKit must be enabled in the app's explicit provisioning profile; a wildcard profile cannot sign it. If command-line automatic provisioning reports no accounts despite an existing Xcode account, select the team once in Xcode's Signing & Capabilities editor to let Xcode create the profile.

### Local Strava setup

Copy `Config/LocalStrava.plist.example` to `Config/LocalStrava.plist`, fill in the existing developer app’s client ID, secret and callback hostname, and restrict the file to your user (`chmod 600 Config/LocalStrava.plist`). The file is ignored by Git. No user access/refresh tokens should be copied from another app.

The local Debug build copies this configuration into its bundle; Release builds remove it and do not enable Strava. This is a personal development setup: an embedded client secret is recoverable from the bundle, so do not distribute this Debug app or publish its build artifacts. Production OAuth needs a separately reviewed credential strategy.

The redirect is `healthimport-strava://YOUR_CALLBACK_HOST/oauth/callback`. It uses the existing allowed hostname with an app-specific scheme; the callback is handled on the iPhone and does not visit that website. There is no relay, server, webhook or change to Stitch’s callback domain. OAuth asks only for activity read access. The shared developer app name will appear in Strava’s consent screen. Shared app quotas and grants still apply; do not revoke that grant to sign out of this trial. **Forget connection on this device** deletes only this app’s tokens and preview.

### Try yesterday’s activity

1. Tap **Connect with Strava** and approve the activity read permission
2. Choose yesterday’s activity (or adjust the trial date and tap **Find activities**)
3. Review the timestamp, distance, duration, detected breaks, cycling sample counts and elevation. **Treat detected breaks as pauses** is enabled when breaks are found; disable it to retain elapsed duration. Enable **Use Strava calories as active energy** only if that interpretation matches the recording
4. Check the date in Apple Health, then confirm **Save to Health** and grant the requested Health access
5. Check the workout in Health/Fitness, including its source and available heart rate/route. The trial blocks a second Strava import
6. Use **Undo import** if needed. Full-history sync stays disabled until this trial is accepted

### Device diagnostics

Debug builds keep the last 200 diagnostic events from the current app session in `Library/Caches/health-import-diagnostics.log`, protected while the phone is locked and excluded from backups. The log contains fixed event names, timestamps and HTTP/error status numbers only. No response bodies, URLs, tokens, activity identifiers, names, coordinates or Health measurements are logged. Release builds write no diagnostic file.

Read the log from an authorised connected phone without restarting the app:

```sh
xcrun devicectl device copy from --device YOUR_DEVICE_ID \
  --domain-type appDataContainer --domain-identifier com.barclayd.healthimport \
  --source Library/Caches/health-import-diagnostics.log \
  --destination /tmp/health-import-diagnostics.log
```

The Xcode project is checked in. `project.yml` is its XcodeGen source; after changing project configuration, run `xcodegen generate` and commit the generated project too.

```sh
swift test
xcodebuild -project HealthImport.xcodeproj -scheme HealthImport \
  -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build
```

For the HealthKit integration tests, first import the synthetic run and ride in a dedicated simulator and grant Health access, enabling active energy for the ride. Tests check saved values, cycling statistics, duplicate matching, round-trip route altitudes, pause-adjusted duration with unchanged dates/totals and scoped undo. They skip on physical devices and simulators without write permission. Use that simulator's ID:

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

Pause detection requires original stream timing and a median sample interval of at most 10 seconds. Contiguous `moving == false` intervals become estimated pauses. Gaps of at least 30 seconds and ten times the normal sample interval require no more than 20 metres of cumulative travel (or endpoint displacement when distance is absent). A gap without a nonmoving flag retains one normal sampling interval before the estimated pause. Downsampled, sparse, unlocated or moving gaps are not automatically treated as breaks. Leading/trailing missing samples are not extrapolated into pauses, and an all-paused result is rejected. These rules cannot distinguish every sensor dropout from a recording pause, so the preview retains the user's choice

When pauses are enabled, distance and chosen active-energy totals are apportioned across unpaused intervals in proportion to their durations. HealthKit would otherwise prorate a whole-workout summary sample and discard part of its total. The original totals are preserved; sample metadata labels their temporal distribution as estimated. Recorded route, heart-rate, power, cadence and speed timestamps are never shifted

`ActivityImportCore` contains the bounded XML parser, Strava API client and mapping, OAuth validation, stable identity, duplicate matching and durable import journal. It is a local Swift package with no dependencies and can be tested on macOS without HealthKit. API tests use synthetic responses and never call Strava.

API requests use an ephemeral session with no cookies or disk cache, reject redirects, time out, and cap response bodies at 20 MB. Strava IDs are the stable identity for API imports; conservative date/sport matching also catches visible workouts imported by other routes. Tokens are stored as one Keychain item with `WhenUnlockedThisDeviceOnly`; refreshed credentials are saved before subsequent activity requests. Rate limiting fails visibly without a retry loop.

`App` contains the SwiftUI interface and the HealthKit writer. All import operations are serialised by the model. A journal entry is persisted before writing to Health, and every sample carries an app-specific transaction marker. On failure, cleanup targets that marker and the app's own Health source. An interrupted entry remains available for retrying cleanup. New imports are blocked while cleanup is pending.

Strava imports use `HKWorkoutBuilder` to produce native cycling statistics from timestamped samples. The Strava elapsed interval is preserved. Energy is one source-total sample, not an invented calorie curve. Zero power/cadence/speed samples are retained; zero heart rate is treated as missing. All samples and the workout carry the same undo transaction marker.

TCX imports retain HealthKit's deprecated explicit-duration initializer and sample association API because TCX supplies timer duration and an elapsed interval without an exact pause timeline. This preserves both without inventing pauses. Subtracting pauses from the end timestamp would corrupt chronology. Xcode reports the two expected deprecation warnings for that fallback.

The parser rejects malformed XML, DTDs/entities, unsupported sports, non-finite measurements, invalid coordinates, unordered track timestamps, overlapping laps, inconsistent dates and oversized input. It never resolves external entities. The test fixture is entirely invented, not a user's export.

## References

* [Strava's export instructions](https://support.strava.com/en-us/articles/15401919-how-do-i-export-my-strava-data)
* [Strava authentication](https://developers.strava.com/docs/authentication/)
* [Strava API reference](https://developers.strava.com/docs/reference/)
* [HealthKit permissions and limited history](https://developer.apple.com/documentation/healthkit/authorizing-access-to-health-data)
* [HealthKit sync identifiers](https://developer.apple.com/documentation/healthkit/hkmetadatakeysyncidentifier)
* [Manage Apple Health data and iCloud settings](https://support.apple.com/en-us/108779)
