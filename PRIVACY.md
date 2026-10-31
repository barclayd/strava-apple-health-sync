# Privacy

Health Import reads activities directly from Strava, processes them on your iPhone or iPad, and writes only the activities you select and import to Apple Health. It does not upload activities or Health data to the developer or any other server.

## No data collection

The app has no separate account system, backend, analytics, advertising, crash-reporting SDK or third-party dependencies. Network requests go directly to Strava for authorisation, token exchange/refresh and activity reads. No activity content, filenames, coordinates or Health query results are logged by the app. Apple's own system diagnostics are controlled by your device settings.

## Strava connection

You authorise activity read access through Strava, including private activities. The app initially requests five activity summaries. Month/year and date-range browsing filters requests on Strava and replaces the visible five-item page. You can select all history, individual rides across pages, or a date range. It then loads the workout, calories, elevation, heart rate, route and cycling power/cadence/speed you choose to import. After you tap import, full-history and date-range imports read pages of up to 50 summaries and fetch one detailed activity at a time. Each page and its detailed measurements are released as processing advances; the full archive is never accumulated. Responses are held in memory; the ephemeral network session has no disk cache or cookies. Requests contain credentials and the identifiers/date filters needed by Strava, never Apple Health data. Strava may collect information about API usage under its own policy.

Access and refresh tokens are kept in this device’s Keychain, available while unlocked, with syncing and device migration disabled. The personal Debug build also contains an ignored local developer configuration for direct OAuth. That bundle must not be distributed; Release builds exclude the configuration and disable this trial connection.

**Disconnect Strava** removes the tokens and Strava activity list from this app. It does not revoke the shared Strava developer app grant used by Stitch. You can revoke that grant in Strava’s connected-app settings, which also affects other uses of the same developer app. Imported Health records stay under your control; use the app’s import history to undo them before uninstalling. Keychain entries can survive uninstalling, so forget the connection first.

## Local history

The app stores only the activity identifier, sport, start date, transaction identifier and completion state in its local import journal. This supports duplicate prevention, undo and recovery if an import is interrupted. The five-item preview, current import page, selected IDs and progress counts are held in memory. Completed activity payloads and a per-activity outcome list are not retained. After relaunch, starting an import uses the durable completed-import entries to skip prior imports; no workout payload cache or server job is created. The journal uses iOS complete file protection and is excluded from device backups. It is not stored in iCloud Drive or CloudKit.

Disconnecting or closing the app releases the activity list. Undo removes a selected import's Health records and local journal entry. Uninstalling removes the local journal but does not remove already imported Health records. Undo unwanted imports before uninstalling.

## Local development diagnostics

Debug builds keep up to 200 fixed diagnostic events from the current app session in a protected local cache file, excluded from backups. It contains timestamps, operation stages, fixed timestamp-validation categories and HTTP/error status numbers only, with no tokens, URLs, activity identifiers, names, route or Health measurements. An authorised developer can retrieve this file through Xcode’s device tools to diagnose the trial. It is replaced on the next launch and may be removed by iOS. Release builds do not write it. No log is sent to a server by the app.

## Health permissions

The app requests workout read access to detect potential duplicates. It requests write access only for the workout and the distance, heart rate, route and cycling measurements present in the activity being imported. When Strava supplies calories, they are always imported as active energy. The API does not provide an active/resting split; resting calories are not added or estimated. Permissions can be changed in Settings.

The same calorie mapping and estimated pause handling apply to every selected activity. Original timestamps are preserved. Imports run sequentially; leaving the app, a request limit or an error pauses the batch. Completed imports remain available for individual Undo.

An empty Health query does not prove there is no existing workout. Denied or limited read permission can hide history. Checks run automatically without a manual review checkbox. Cross-app duplicate detection cannot guarantee a match when Health hides the existing workout.

Each imported object is labelled with this app's source and transaction marker. Undo is restricted to that source and marker; it does not remove another app's records. Samples read from other apps for matching are not retained.

## Services you control

Apple Health may sync the imported data with iCloud if you have enabled that feature. Other apps you authorise to read Health may access the imported data. These are separate from Health Import's behaviour and follow your settings and those services' policies.

This project therefore says **“no uploads by this app”**, rather than promising that data can never leave the device.

## Development and review

Only invented fixtures belong in the repository and public previews. Real exports must not be attached to public issues or pull requests. Changes that introduce networking, third-party SDKs, logging of health information, backup behaviour or different retention require an explicit review of this privacy commitment.
