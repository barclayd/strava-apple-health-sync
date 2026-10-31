# Health Import

A native Swift / SwiftUI proof of concept for importing Strava workouts into Apple Health. Connect directly to Strava, choose all history, individual rides or a date range, then import into Health with one button.

**No app backend, analytics, advertising, crash-reporting service or third-party dependencies.** Authentication and activity requests go directly from the iPhone to Strava. Previews are held in memory without a disk cache. A small, protected local journal supports duplicate protection, interrupted-import recovery and undo; it is excluded from device backups.

Apple Health can sync through iCloud when the user enables it. The promise is **“this app never uploads your activities”**, not a promise about Apple's services or other apps. See [PRIVACY.md](PRIVACY.md).

## Current POC

The individual cycling trial has been checked on a physical iPhone, including calories, route elevation and pause markers. The single-screen importer uses that mapping for the selected batch. This is a local development POC, not an available App Store release; ongoing background sync and complete archive reconciliation remain out of scope.

Currently supported:

* Native Strava sign-in, with a system browser fallback and validated OAuth state/callback/scope
* Direct activity reads with `activity:read_all`, Keychain token storage and coordinated token refresh
* One five-summary request after connection; recent rides grouped by month, with direct month/year selection and replacement pages
* All-history, individual and inclusive local-date selection with one import button, progress counts, automatic duplicate skipping and pause/resume
* Shared Strava quota headroom: pauses at 90% of the advertised short-term or daily budget; no retry loop
* Original timestamps, distance, recorded heart-rate samples and GPS route
* Cycling power (with an estimated-power marker when applicable), cadence, speed, elevation gain and indoor/outdoor status from Strava
* Estimated pause/resume events from Strava movement samples and stationary recording gaps, enabled automatically
* Available Strava calories saved as active energy automatically
* A fixed import button showing the selected scope or individual count; no additional review checkbox or confirmation sheet. Apple’s required Health permission sheet remains
* Stable per-activity identifiers, a persistent import journal and conservative matching against visible Health workouts
* Undo for this app's workout, route and associated samples, including interrupted imports
* Clearly labelled synthetic 2018 rides, available only with Debug simulator launch arguments

Limits:

* The app UI uses Strava only. The TCX parser remains in the core package for development; file opening, FIT, GPX, ZIP archives, other sports, ongoing background sync and edited-workout reconciliation are outside this flow
* History import streams pages of at most 50 summaries and one detailed activity at a time. It stops on an empty page, including after short pages; a failed request pauses at that page or activity. A 10,000-page guard stops pathological responses without claiming completion
* Browsing retains at most five summaries, not the full archive. Import retains one page, bounded recent-page identifiers and scalar progress; individual choices retain IDs only. The protected undo journal still stores minimal identifiers and timestamps for completed imports. After relaunch, a new import skips those IDs before fetching details. Unfinished transactions require scoped Undo before resuming
* Keep the app open for a batch. Leaving the foreground requests a pause after the current transaction. API errors and quota limits pause the batch; resume manually when resolved. The shared Stitch app may consume quota concurrently
* Strava does not provide Garmin's original timer events. Full-resolution movement samples and stationary recording gaps can estimate pauses; these are imported automatically. Health receives real pause/resume events without shifting sample timestamps. Workout duration excludes enabled pauses; Strava moving time remains separate. Fitness controls graph presentation
* Missing streams produce a summary-only import. No heart-rate or route samples are invented
* TCX calories, cadence and power remain unsupported. Strava’s calorie value has no active/resting split: the app always treats the supplied value as active energy. No resting calories are fabricated
* Only available cycling streams become Health samples. Summary-only power/cadence averages are not expanded into invented time series. Device/Strava estimates retain their source limitations
* Route altitudes preserve the source's elevation profile, including zero and negative elevations. Missing altitudes remain invalid. Strava and TCX do not supply recording accuracy: imported route points use a documented 50 m accuracy assumption so Core Location treats supplied coordinates/altitudes as valid. Route metadata labels this assumption; it is not measured sensor precision or a guaranteed error bound
* No fabricated sensor readings, calorie totals or missing altitude values. Inferred pauses are labelled as estimates in Health event metadata
* Ambiguous duplicates are blocked, with no override in this first POC
* Read permission can be denied or limited without a distinguishable empty-result error. Duplicate checks run automatically and can only inspect authorised workouts. Cross-app duplicate prevention cannot be guaranteed when Health hides data
* When compiled with Xcode 27.1 / Swift 6.4 or later, the app also checks iOS 27's earliest-authorised-date API and blocks imports outside a known limited history window. Older toolchains cannot check this boundary
* Activity rings, awards and physical-device behaviour need separate acceptance testing
* Uninstalling the app does not delete its Health data, but removes its local undo journal. Check results and undo unwanted imports before uninstalling

## Run

Open `HealthImport.xcodeproj` in Xcode 16 or later (Swift 6). The deployment target is iOS 17. Select the `HealthImport` scheme and an iPhone simulator.

For a physical device, copy `Config/LocalSigning.xcconfig.example` to `Config/LocalSigning.xcconfig` and set your development team ID. The local file is ignored by Git and supplies signing for the app and test target. Sign into Xcode's Apple Accounts settings, select your iPhone as the run destination and run. HealthKit must be enabled in the app's explicit provisioning profile; a wildcard profile cannot sign it. If command-line automatic provisioning reports no accounts despite an existing Xcode account, select the team once in Xcode's Signing & Capabilities editor to let Xcode create the profile.

### Local Strava setup

Copy `Config/LocalStrava.plist.example` to `Config/LocalStrava.plist`, fill in the existing developer app’s client ID, secret and callback hostname, and restrict the file to your user (`chmod 600 Config/LocalStrava.plist`). The file is ignored by Git. No user access/refresh tokens should be copied from another app.

The local Debug build copies this configuration into its bundle; Release builds remove it and do not enable Strava. This is a personal development setup: an embedded client secret is recoverable from the bundle, so do not distribute this Debug app or publish its build artifacts. Production OAuth needs a separately reviewed credential strategy.

The redirect is `healthimport-strava://YOUR_CALLBACK_HOST/oauth/callback`. It uses the existing allowed hostname with an app-specific scheme; the callback is handled on the iPhone and does not visit that website. There is no relay, server, webhook or change to Stitch’s callback domain. OAuth asks only for activity read access. The shared developer app name will appear in Strava’s consent screen. Shared app quotas and grants still apply; do not revoke that grant to sign out of this trial. **Disconnect Strava** in the Options menu deletes only this app’s tokens and activity list.

### Import activities

1. Tap **Connect with Strava** and approve activity read access. The app requests only the latest five activity summaries; this does not write to Health
2. Choose **All history**, **Individual** or **Date range**. Individual mode opens the latest month: tap the month heading to jump directly to a month/year, or use its arrows. **Older / Newer** replaces the visible page with up to five rides. Selected IDs persist across pages/months. Date ranges include both complete local days and filter on Strava before paging
3. Tap **Import all history**, **Import date range** or **Import … rides**. Import starts immediately, with no extra app confirmation. Grant Apple’s required Health permissions when prompted. Available Strava calories are always imported as active energy, and detected pauses preserve the original timestamps
4. Keep the app open. **Pause import** finishes the current transaction first. Network, permission and quota errors pause automatically; **Resume import** retries the pending activity. **Skip this activity** omits a failed item for this session
5. Existing journal entries and matching visible Health workouts are skipped automatically. All-history and date-range imports fetch each small page only when needed and release it before the next. Counts report actual progress, without claiming to know an unfetched total
6. Open **Options → Import history** for per-workout **Undo import** or interrupted-import cleanup. **Options → Privacy** explains local processing and permissions

The importer supports runs as well as rides. Unsupported sports are left out. No batch starts just by connecting, loading or changing the selection.

For synthetic UI review, launch a Debug simulator build with `--preview`. Its connect button browses eighteen invented rides, five at a time without OAuth or Strava requests. `--preview-connected` opens the list directly. These flags have no effect on physical devices or Release builds; demo imports write only to simulator Health.

### Browsing and loading decisions

The main screen shows up to five recent rides with month headings. The month/year picker appears only in Individual mode; compact date pickers appear in Date range mode. This follows [NN/g’s progressive-disclosure guidance](https://www.nngroup.com/articles/progressive-disclosure/) and [Apple’s picker guidance](https://developer.apple.com/design/human-interface-guidelines/pickers). It avoids a scrolling archive and lets someone jump fifteen years without tapping through every month.

[Strava’s list endpoint](https://developers.strava.com/docs/reference/#api-Activities-getLoggedInAthleteActivities) supports date bounds, page numbers and page sizes. Browsing requests five summaries and replaces them on navigation. Each filter change cancels its predecessor and uses a generation check so late data or errors cannot overwrite the active period. Cancellation is not presented as a broken connection. Successful sign-in, restoration and activity reads clear stale connection errors.

Full-history import uses a fixed upper time bound, pages of 50, one detailed workout at a time and progress counts. There is no up-front full-history scan or accumulated outcome list. Loading/import progress is indeterminate until finished, following [Apple’s loading guidance](https://developer.apple.com/design/human-interface-guidelines/loading). Pause/resume keeps the pending page and activity; after relaunch, the small existing journal provides duplicate protection. The journal contains minimal undo metadata, not a cache of activities or streams. Import history itself displays 20 journal records per page.

### Avoiding a Strava–Health sync loop

Users do not need to turn off Strava's Automatic Uploads. [Strava's current Health integration documentation](https://support.strava.com/en-us/articles/15402024-apple-health-and-strava), checked 31 October 2026, says workouts uploaded to Health by third-party apps do not sync back to Strava. HealthKit assigns our saved workouts and samples the `com.barclayd.healthimport` source; the importer does not impersonate Apple Workout or an Apple Watch. Integration tests check that source after reading the records back.

Our Strava connection requests activity read access and has no activity-upload implementation. The original Strava activity ID also remains attached to our Health records for our own duplicate detection; it is not a cross-app “do not upload” flag. HealthKit does not give this importer a per-workout switch to block another authorised app from reading or uploading it. The loop prevention therefore depends on Strava's documented third-party exclusion, and does not cover a separate sync app configured to upload Health workouts to Strava.

Physical-device acceptance: with Strava's existing Automatic Uploads setting enabled, import a recent activity and confirm it neither appears as a new upload candidate nor creates a duplicate in Strava. Use a recent activity because an old historical workout is also excluded by Strava's 30-day import window. This external-app behaviour must be rechecked if Strava changes its integration; our simulator tests verify source attribution, not Strava's uploader.

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

For the HealthKit integration tests, grant Health write access in a dedicated simulator; a synthetic ride can be imported using `--preview`. Tests check saved values, cycling statistics, duplicate matching, round-trip route altitudes, pause-adjusted duration with unchanged dates/totals and scoped undo. They skip on physical devices and simulators without write permission. Use that simulator's ID:

```sh
xcodebuild -project HealthImport.xcodeproj -scheme HealthImport \
  -destination 'platform=iOS Simulator,id=YOUR_SIMULATOR_ID' \
  -parallel-testing-enabled NO test
```

Signing-team settings are machine-local. There is no App Store Connect app record or TestFlight delivery workflow configured in this repository. A local development installation and a simulator build are separate from a TestFlight beta.

Keep default ad-hoc signing enabled when running or testing in a simulator; `CODE_SIGNING_ALLOWED=NO` above is only a compilation check and does not embed the simulated HealthKit entitlement.

## Design

Pause detection requires original stream timing and a median sample interval of at most 10 seconds. Contiguous `moving == false` intervals become estimated pauses. Gaps of at least 30 seconds and ten times the normal sample interval require no more than 20 metres of cumulative travel (or endpoint displacement when distance is absent). A gap without a nonmoving flag retains one normal sampling interval before the estimated pause. Downsampled, sparse, unlocated or moving gaps are not automatically treated as breaks. Leading/trailing missing samples are not extrapolated into pauses, and an all-paused result is rejected. These rules cannot distinguish every sensor dropout from a recording pause, so event metadata records that pause timing is estimated

When pauses are enabled, distance and chosen active-energy totals are apportioned across unpaused intervals in proportion to their durations. HealthKit would otherwise prorate a whole-workout summary sample and discard part of its total. The original totals are preserved; sample metadata labels their temporal distribution as estimated. Recorded route, heart-rate, power, cadence and speed timestamps are never shifted

`ActivityImportCore` contains the bounded XML parser, Strava API client and mapping, OAuth validation, stable identity, duplicate matching and durable import journal. It is a local Swift package with no dependencies and can be tested on macOS without HealthKit. API tests use synthetic responses and never call Strava.

API requests use an ephemeral session with no cookies or disk cache, reject redirects, time out, and cap response bodies at 20 MB. Strava IDs are the stable identity for API imports; conservative date/sport matching also catches visible workouts imported by other routes. Tokens are stored as one Keychain item with `WhenUnlockedThisDeviceOnly`; refreshed credentials are saved before subsequent activity requests. Rate limiting fails visibly without a retry loop.

`App` contains the SwiftUI interface and the HealthKit writer. All import operations are serialised by the model. A journal entry is persisted before writing to Health, and every sample carries an app-specific transaction marker. On failure, cleanup targets that marker and the app's own Health source. An interrupted entry remains available for retrying cleanup. New imports are blocked while cleanup is pending.

Strava imports use `HKWorkoutBuilder` to produce native cycling statistics from timestamped samples. The Strava elapsed interval is preserved. Energy uses the source total, apportioned across unpaused intervals when necessary; it is not a measured calorie curve. Zero power/cadence/speed samples are retained; zero heart rate is treated as missing. All samples and the workout carry the same undo transaction marker.

TCX imports retain HealthKit's deprecated explicit-duration initializer and sample association API because TCX supplies timer duration and an elapsed interval without an exact pause timeline. This preserves both without inventing pauses. Subtracting pauses from the end timestamp would corrupt chronology. Xcode reports the two expected deprecation warnings for that fallback.

The parser rejects malformed XML, DTDs/entities, unsupported sports, non-finite measurements, invalid coordinates, unordered track timestamps, overlapping laps, inconsistent dates and oversized input. It never resolves external entities. The test fixture is entirely invented, not a user's export.

## References

* [Strava's export instructions](https://support.strava.com/en-us/articles/15401919-how-do-i-export-my-strava-data)
* [Strava authentication](https://developers.strava.com/docs/authentication/)
* [Strava API reference](https://developers.strava.com/docs/reference/)
* [HealthKit permissions and limited history](https://developer.apple.com/documentation/healthkit/authorizing-access-to-health-data)
* [HealthKit sync identifiers](https://developer.apple.com/documentation/healthkit/hkmetadatakeysyncidentifier)
* [Manage Apple Health data and iCloud settings](https://support.apple.com/en-us/108779)
