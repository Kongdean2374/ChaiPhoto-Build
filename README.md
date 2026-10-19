# ChaiPhoto Build

Public, independently buildable source snapshot for ChaiPhoto. The private
development repository remains the authoritative development and history source.
No private Git history, feedback, credentials or existing build artifacts are included.

The code is available for public inspection. No additional reuse license is granted.
No MIT/GPL or other open-source license has been added.

## Manual workflows

All delivery workflows accept only this repository's main branch and the exact
40-character public commit SHA entered as expected_sha. There are no push, PR,
schedule, tag or workflow_run delivery triggers.

| Workflow | Result | Credentials | Publication |
|---|---|---|---|
| Build Unsigned IPA | iPhoneOS ARM64 Beta-flavor IPA | No Apple credentials | Public Release, checksum and build summary |
| Upload TestFlight | Manual signed upload | testflight environment | Apple only |
| Upload App Store | Production-flavor signed upload | appstore environment | Apple only |
| Validate Reviewed Snapshot | Both unsigned iPhoneOS flavors, XCTest and lifecycle UI tests | No Apple credentials | Synthetic simulator PNGs (3 days) |

Unsigned IPA files cannot be installed directly. Downloaders supply their own signing
and provisioning. Release assets and this source are publicly downloadable.

## Versions

Marketing version remains 1.2.7 by explicit owner instruction. Both Apple delivery
channels now share one increasing build sequence; parity has no channel meaning.
Use an unused positive integer from 1 to 9999, greater than Apple's highest build
across both channels. The current target is 67 only if still unused and above the
live Apple maximum; Build 66 is already uploaded and must not be reused.
Source and validation commits do not reserve build numbers. Never rerun a previous
upload; dispatch the exact validated main SHA with the newly confirmed build.
The repository build setting is only a placeholder.

Existing live Apple preflight still runs before certificate import and compilation.
It rejects a used or lower build, closed marketing-version trains, unknown states,
inaccessible APIs and incomplete/paginated metadata. Both workflows retain the same
Apple-upload concurrency group, protected environments, local signing and one upload
attempt. Cross-repository/manual uploads still require coordination. No secret,
identity, permission or production-release authorization changes are implied.

## Apple setup — not configured or executed during initial delivery

Configure testflight and appstore environments with a required maintainer reviewer,
main-only deployment branches, self-review allowed for the current single maintainer,
and administrator bypass disabled where supported. Until these controls are verified,
do not configure signing credentials or run either Apple workflow.

Set these secrets separately in each environment, from your secure original backups:

- APP_STORE_CONNECT_API_KEY_P8
- BUILD_CERTIFICATE_BASE64
- P12_PASSWORD
- PROVISIONING_PROFILE_BASE64

Set APP_STORE_CONNECT_KEY_ID, APP_STORE_CONNECT_ISSUER_ID and APPLE_TEAM_ID as
environment variables (the workflows also accept environment secrets for these IDs).
These IDs are identifiers, not private keys. Repository-level Apple secrets are not used.
Secrets are not inherited from the private repository and cannot be recovered through
the GitHub secret-read API. Do not paste credentials into issues, source or chat.

Use the existing App Store distribution certificate and profile for
tw.chai2374.ChaiPhoto. The workflow will not create an Apple app, certificate or profile.
API permissions must permit existing app/build reads and uploads.
Each GitHub secret must fit its size limit; never commit an encrypted credential
file as a workaround. Oversized values require a separately reviewed secrets-only setup.

Upload success does not guarantee Apple processing, TestFlight availability,
App Review approval or production release. Select and release builds in Apple
through the established authorized process.

Website version synchronization is not deployed in this initial three-workflow
delivery. After confirming TestFlight availability, update the existing website
through the established authorized process. No feedback or website token is held here.

## Local build and snapshot updates

This snapshot starts each new process in Sort and keeps the current tab when
returning from the background. Fresh installs get a resumable three-step setup;
existing preferences and sorting progress are preserved. The General setup page
shares its controls with Settings: preload speed and always-download permissions
appear together, with display/language, sorting and playback in compact groups.
Inline notes explain on/off behavior; photo access warnings remain separate.
Preloading has only four modes: Off, Low, Balanced and Aggressive, with no manual
count controls. Balanced observes battery, charging, Low Power Mode, thermal state
and network cost/Low Data Mode; Aggressive uses the existing 8-photo/4-video cap.
Off cancels background preparation and requires item-specific cloud consent even
when a saved permanent or session permission exists. Local display still works;
Off does not blank the library. Item grants remain in memory and never permit the
next asset or background preloading. With an active speed, missing permanent
permissions are requested once per process after onboarding, photo access and
modal presentation allow it. Declining makes the unapproved media preload budgets
zero without changing the selected speed. Manual item grants never resume future
preloading. The next process asks again; returning from the background does not.
Permanent photo and video permissions remain independent. Preload intensity never
grants download permission. Beta updates use the existing Beta API;
App Store updates use Apple's public Lookup with app identity and link validation.

The manual validation workflow compiles both Release-TestFlight and Release-AppStore
for iPhoneOS without signing, then runs synthetic XCTest and simulator lifecycle
tests for both configurations. It uses a standard macos-26 runner, no environment
secrets, uploads, persisted artifacts, dependency caches or automatic retries.
Physical iCloud, photo permissions, large text and real upgrade data still require
device verification; passing synthetic tests does not certify those scenarios.

Install the approved Xcode and XcodeGen versions listed in build/toolchain.json.
Set RELEASE_BUILD_NUMBER and RELEASE_FLAVOR=unsigned, run the version resolver,
then xcodegen generate and build the ChaiPhoto scheme in Release with signing disabled.
Builds require only this public source and publicly available tooling.

Updates are prepared in a private workspace from an approved immutable source
commit by selecting exact files, applying reviewed build configuration changes,
scanning the final candidate and approving its diff before publication.
Unknown files, symlinks, submodules, LFS pointers and source hash changes fail closed.
App source changes require renewed source-manifest review; never automatically
regenerate a manifest to bypass a failed check.

The public workflows verify the file allowlist and generated Xcode sources/resources.
They do not clone a private repository and contain no private-repository PAT or deploy key.
External contributions must first be reviewed in the authoritative private development
process and exported as a newly approved snapshot.

## Cost and privacy

Only standard macos-26 runners are selected. No larger runners, Actions artifacts,
dependency caches, Git LFS, Packages or paid build services are used.
Unsigned files are uploaded directly to GitHub Releases. Signing files, archives
and raw signing logs stay in the temporary runner environment and are cleaned.
Public Actions logs and release/source history are public; published copies cannot
be reliably recalled. Existing private-repository CI and Apple membership costs
are separate from this public build design.

App policies: https://photo.chaihome.cc/privacy and https://photo.chaihome.cc/terms

Runner policy: https://docs.github.com/en/actions/reference/runners/github-hosted-runners
Release limits: https://docs.github.com/en/repositories/releasing-projects-on-github/about-releases
Environment protection: https://docs.github.com/en/actions/reference/workflows-and-actions/deployments-and-environments

## Delivery failures and retries

The API key file uses the conventional AuthKey_<Key ID>.p8 filename. Export keeps
app-store-connect, destination=export, manual signing, the existing distribution
identity/profile and manageAppVersionAndBuildNumber=false. No automatic signing
repair or certificate creation is enabled. Export is local and does not use an
Xcode account or upload credentials. The exported IPA is checked again for the
expected iPhoneOS device, flavor and version before a separate Apple altool upload.
The existing API key is discovered in the private signing directory's private_keys
folder; no Apple ID password, replacement certificate or new secret is required.

The stages archive, export, ipa-validation and apple-upload are reported separately.
On archive or export failure, the workflow preserves the original exit code
and prints a structured summary containing only the stage, exit code, ITMS codes,
allowlisted NSError domain/code pairs, HTTP error statuses and fixed diagnostic
signals and fixed vocabulary hints. Signals are hints, not a confirmed root cause.
The uploader reads Apple's XML receipt and reports only numeric product error codes.
Success requires both a zero exit code and an explicit structured success receipt
with no product errors. A zero exit with errors or unrecognized output stops the
workflow instead of silently claiming delivery. It does not retry automatically.
Raw message excerpts,
UserInfo, URLs, paths, identifiers, credentials and original log files are never
published. Unknown errors may have empty code lists. Logs remain temporary and
are deleted by the signing cleanup trap; no log artifact is uploaded.

An export/upload exit code alone does not prove Apple rejected or never received
the binary. Before a new manually authorized attempt, check TestFlight Build Uploads
and processing status, confirm the newest build sequence, and reserve a fresh
explicit build number. The workflow does not retry uploads or reuse build numbers
automatically. Do not rerun a historical job: dispatch the updated main SHA and
your newly confirmed number. Both channels use the shared increasing build sequence.

Apple upload methods: https://developer.apple.com/help/app-store-connect/manage-builds/upload-builds/
Apple delivery status: https://developer.apple.com/help/app-store-connect/manage-builds/view-builds-and-metadata/

## 1.2.7 follow-up: remove analysis and refine the interface

App-generated photo/video similarity analysis, comparison views and its filter
entries have been removed, using stable source 6dfcd4996951e130fe12db0cf816c7ae503b5088
as the integration baseline. Existing sorting, ordinary/date/album filters,
onboarding, preloading and decisions/history remain. Retired saved filter kinds
normalize to all items of the same media source while keeping dates and ordinary
resume cursors. A utility cleanup removes only the retired analysis JSON and
UUID-named feature folders from app storage, never Photos or sorting files.

Visual refinement uses adaptive opaque surfaces, restrained static gradients,
thin borders and consistent typography/spacing. There are no looping animations,
new scan tasks or heavy blur effects in the new styling.

Manual validation uses a fresh iPhone 17 Pro simulator containing only six
generated landscape/portrait PNGs. Real UI tests capture sorting, filters, review
and settings in light Traditional Chinese and dark English with large text.
Only exported PNG attachments are retained for three days; no original media,
signing data or full result/log bundles are published. This is a validation-only
artifact, not an App Store screenshot submission. Compilation/test success is
separate from human visual inspection and physical-device performance acceptance.
