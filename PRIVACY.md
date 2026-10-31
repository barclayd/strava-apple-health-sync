# Privacy

Health Import processes selected activity files on your iPhone or iPad and writes the records you confirm to Apple Health. It does not upload activities or Health data to the developer or any other server.

## No data collection

The app has no account system, backend, analytics, advertising or crash-reporting SDK. It contains no networking code or third-party dependencies. No activity content, filenames, coordinates or Health query results are logged by the app. Apple's own system diagnostics are controlled by your device settings.

## Files and local history

You choose the export files the app can open. Security-scoped access is released after reading. The app reads these files in memory and does not retain a copy. File-size and activity-count limits bound processing.

The app stores only the activity identifier, sport, start date, transaction identifier and completion state in its local import journal. This supports duplicate prevention, undo and recovery if an import is interrupted. The journal uses iOS complete file protection and is excluded from device backups. It is not stored in iCloud Drive or CloudKit.

Clearing the preview releases the parsed activities. Undo removes a selected import's Health records and local journal entry. Uninstalling removes the local journal but does not remove already imported Health records. Undo unwanted imports before uninstalling.

## Health permissions

The app requests workout read access to detect potential duplicates. It requests write access only for the workout and the distance, heart rate and route present in the activity being imported. Permissions can be changed in Settings.

An empty Health query does not prove there is no existing workout. Denied or limited read permission can hide history. The app explains this and requires a review confirmation before importing.

Each imported object is labelled with this app's source and transaction marker. Undo is restricted to that source and marker; it does not remove another app's records. Samples read from other apps for matching are not retained.

## Services you control

Apple Health may sync the imported data with iCloud if you have enabled that feature. Other apps you authorise to read Health may access the imported data. If you select a file from iCloud Drive or another cloud provider, Files may download it. These are separate from Health Import's behaviour and follow your settings and those services' policies.

This project therefore says **“no uploads by this app”**, rather than promising that data can never leave the device.

## Development and review

Only invented fixtures belong in the repository and public previews. Real exports must not be attached to public issues or pull requests. Changes that introduce networking, third-party SDKs, logging of health information, backup behaviour or different retention require an explicit review of this privacy commitment.
