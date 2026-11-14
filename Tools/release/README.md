# Personal TestFlight builds

The release script creates an iOS **Release** archive and exports an IPA. Upload
requires `--upload`. It uses the account signed into Xcode; no account email or
password is stored in this repository. Archiving/exporting with automatic signing
can create or update provisioning profiles on the selected team.

## Personal configuration

Copy the tracked example to the ignored local file:

```sh
cp Config/Personal.xcconfig.example Config/Personal.xcconfig
```

The approved personal identity is:

| Setting | Value |
| --- | --- |
| Main bundle ID | `net.specters312.lively` |
| Widget bundle ID | `net.specters312.lively.widgets` |
| App Group | `group.net.specters312.lively` |
| URL scheme | `lively-specters` |
| App Store Connect name | `Lively – Specters` |
| Home Screen name | `Lively` |
| Developer Team ID | `72D8527G28` |

The App Store Connect app record must use the main bundle ID. The widget and App
Group must belong to the same developer team. The project does not create an App
Store Connect app record or change the store listing.

The example disables the upstream key broker with an empty
`LIVELY_KEY_BROKER_URL`. This allows on-device translation and user-provided API
keys without using the original account/subscription service. Download offline
language and voice packs before going offline. To use an owned broker, configure
its HTTPS URL; the example explains xcconfig's `//` escaping.

Without overrides, upstream builds keep `sh.ian.lively`,
`group.sh.ian.lively`, the `lively` scheme, and the existing broker. The personal
scheme and App Group keep widget links and shared preferences separate when both
copies are installed. The widget bundle ID always follows the main app ID with
`.widgets` appended.

## Review the command, then archive

Choose a build number higher than any previously uploaded for the version. The
script requires it explicitly and accepts one to three numeric components, within
the documented 4/2/2 digit limits, such as `1` or `42.1`.

```sh
Tools/release/testflight.sh \
  --config Config/Personal.xcconfig \
  --team 72D8527G28 --build-number 1 --dry-run

Tools/release/testflight.sh \
  --config Config/Personal.xcconfig \
  --team 72D8527G28 --build-number 1
```

`--dry-run` validates inputs and prints the generated configuration and commands
without invoking Xcode, creating artifacts, or changing provisioning. Normal
execution writes the archive, export options, generated xcconfig, IPA export, and
logs under `build/release/`, which Git ignores. Existing archive/export paths for
the same build number are rejected.

After reviewing the export and signing results, an explicit upload is:

```sh
Tools/release/testflight.sh \
  --config Config/Personal.xcconfig \
  --team 72D8527G28 --build-number 2 --upload
```

This command creates a new archive before uploading. App Store Connect processes
the build before it appears in TestFlight; tester access and any required review
are managed there separately.

## Overrides

Run `Tools/release/testflight.sh --help` for the full option list. Flags override
environment values, which override the selected xcconfig and then the project
defaults. The script includes the local config in a generated xcconfig and writes
explicit overrides after it; it never sources the file as shell code.

Team and build number always come from `--team` / `--build-number` or
`LIVELY_TEAM_ID` / `LIVELY_BUILD_NUMBER`. Bundle ID, App Group, URL scheme, broker
URL, output directory, and config path also have CLI/environment overrides.
`--broker-url ''` explicitly disables the broker; omitting it preserves the
selected config/project value. There is no Debug distribution mode.

Keep signing certificates, private keys, account credentials, and API keys out of
xcconfig files and version control. The example contains only public identifiers.

## Validation

Run the release command's regression tests before changing signing or upload behavior:

```sh
python3 Tools/tests/test_release_script.py
```

These tests replace Xcode with a temporary stub. They verify configuration
precedence, input validation, archive/export arguments, explicit upload selection,
and failure handling without building an app or contacting Apple. A real signed
archive, exported IPA inspection, and App Store Connect processing remain separate
release checks.
