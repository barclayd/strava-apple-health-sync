# Privacy

Health Import reads activities directly from Strava (or from TCX files you choose), processes them on your iPhone or iPad, and writes only the records you confirm to Apple Health. It does not upload activities or Health data to the developer or any other server.

## No data collection

The app has no separate account system, backend, analytics, advertising, crash-reporting SDK or third-party dependencies. Network requests go directly to Strava for authorisation, token exchange/refresh and activity reads. No activity content, filenames, coordinates or Health query results are logged by the app. Apple's own system diagnostics are controlled by your device settings.

## Strava connection

You authorise activity read access through Strava, including private activities. The app lists the day you select and loads the workout, calories, elevation, heart rate, route and cycling power/cadence/speed you choose to review. Responses are held in memory; the ephemeral network session has no disk cache or cookies. Requests contain credentials and the identifiers/date filters needed by Strava, never Apple Health data. Strava may collect information about API usage under its own policy.

Access and refresh tokens are kept in this device’s Keychain, available while unlocked, with syncing and device migration disabled. The personal Debug build also contains an ignored local developer configuration for direct OAuth. That bundle must not be distributed; Release builds exclude the configuration and disable this trial connection.

**Forget connection on this device** removes the tokens and Strava preview from this app. It does not revoke the shared Strava developer app grant used by Stitch. You can revoke that grant in Strava’s connected-app settings, which also affects other uses of the same developer app. Imported Health records stay under your control; use the app’s import history to undo them before uninstalling. Keychain entries can survive uninstalling, so forget the connection first.

## Files and local history

You choose the export files the app can open. Security-scoped access is released after reading. The app reads these files in memory and does not retain a copy. File-size and activity-count limits bound processing.

The app stores only the activity identifier, sport, start date, transaction identifier and completion state in its local import journal. This supports duplicate prevention, undo and recovery if an import is interrupted. The journal uses iOS complete file protection and is excluded from device backups. It is not stored in iCloud Drive or CloudKit.

Clearing the preview releases the parsed activities. Undo removes a selected import's Health records and local journal entry. Uninstalling removes the local journal but does not remove already imported Health records. Undo unwanted imports before uninstalling.

## Local development diagnostics

Debug builds keep up to 200 fixed diagnostic events from the current app session in a protected local cache file, excluded from backups. It contains timestamps, operation stages and HTTP/error status numbers only, with no tokens, URLs, activity identifiers, names, route or Health measurements. An authorised developer can retrieve this file through Xcode’s device tools to diagnose the trial. It is replaced on the next launch and may be removed by iOS. Release builds do not write it. No log is sent to a server by the app.

## Health permissions

The app requests workout read access to detect potential duplicates. It requests write access only for the workout and the distance, heart rate, route and cycling measurements present in the activity being imported. Active energy is requested only when you explicitly choose to interpret the supplied Strava calorie value as active energy; the API does not provide an active/resting split. Permissions can be changed in Settings.

An empty Health query does not prove there is no existing workout. Denied or limited read permission can hide history. The app explains this and requires a review confirmation before importing.

Each imported object is labelled with this app's source and transaction marker. Undo is restricted to that source and marker; it does not remove another app's records. Samples read from other apps for matching are not retained.

## Services you control

Apple Health may sync the imported data with iCloud if you have enabled that feature. Other apps you authorise to read Health may access the imported data. If you select a file from iCloud Drive or another cloud provider, Files may download it. These are separate from Health Import's behaviour and follow your settings and those services' policies.

This project therefore says **“no uploads by this app”**, rather than promising that data can never leave the device.

## Development and review

Only invented fixtures belong in the repository and public previews. Real exports must not be attached to public issues or pull requests. Changes that introduce networking, third-party SDKs, logging of health information, backup behaviour or different retention require an explicit review of this privacy commitment.
