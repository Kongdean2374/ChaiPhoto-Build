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
| Validate Reviewed Snapshot | Both unsigned iPhoneOS flavors, XCTest and lifecycle UI tests | No Apple credentials | No release or artifact |

Unsigned IPA files cannot be installed directly. Downloaders supply their own signing
and provisioning. Release assets and this source are publicly downloadable.

## Versions

Marketing version is 1.3.0. The owner confirmed 1.2.5 is already approved; raising
only a build number cannot reopen that approved version's upload train.
Enter an explicit positive build number from 1 to
9999; this conservative project limit is not a claim about all Apple formats.
TestFlight uses even numbers; App Store uses odd numbers. Neither Apple workflow
uses the repository run number. Check the existing Apple build sequence and reserve
a number before dispatch. Read-only Apple API checks verify the latest approved
iOS marketing version and the build sequence before certificate import or compilation.
The marketing version must exceed every approved/released version, including versions
pending release or removed from distribution. Unknown states, incomplete metadata,
inaccessible APIs or pagination limits stop delivery. Both current and legacy Apple
state field names are supported. The checks cannot guarantee final Apple validation
or prevent cross-repository races.

The owner reports 1.2.6 (58) is already in TestFlight; builds 60 and 62 were also uploaded.
Never reuse these numbers. Each new TestFlight upload must use an unused even build
above Apple's highest existing build, confirmed by live preflight. Source changes
and validation builds do not reserve a number. The repository build setting remains
a placeholder; Apple uploads require separate owner authorization.

The concurrency lock is shared between the two Apple workflows only within this
repository. Never deliver from the private and public repositories at the same time.
Cross-repository Apple fallback remains unverified; private workflow changes require
separate authorization.

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
your newly confirmed number. TestFlight retains the even-number policy.

Apple upload methods: https://developer.apple.com/help/app-store-connect/manage-builds/upload-builds/
Apple delivery status: https://developer.apple.com/help/app-store-connect/manage-builds/view-builds-and-metadata/

## 1.3.0 local-preview analysis

Opt-in analysis indexes PHAsset dates, dimensions, types, bursts, Favorite state and
album membership before comparing bounded candidates. It uses existing local
384 px Photos thumbnails/posters, Vision revision 2 and a thumbnail hash for close
matches. Analysis/preheating never enables network access. A current/next 100-item
window bounds thumbnail preparation; unchanged successful features are stored in
individual local files and reused by identifier/modification date. Missing local
previews are expected coverage limits, not reasons to download originals.

Video candidates combine duration, resolution, date/album metadata and poster
features. Only available local file-backed AVAssets can provide five small sampled
frames; unavailable/composed assets remain poster-only. UI distinguishes similar,
highly suspected duplicate, poster-only and sampled-frame evidence. None proves
byte-identical originals. Long/high-resolution filters do not measure file sizes.
The comparison grid is local-thumbnail-only; explicitly opening a full preview or
playback uses the existing download consent flow. Analysis can be stopped, disabled
or cleared without changing photos, review choices or history. Leaving the active
app, Low Power Mode and serious thermal states pause work.

Candidate counts, metadata families, album keys and preheat windows are bounded;
cross-date/different-type/distant copies can be missed. Vision thresholds are
heuristics, not probabilities. Physical-device iCloud coverage, match quality,
large-library throughput and power usage are not established by synthetic tests.
Local analysis stores identifiers, metadata, feature prints and group results in
the app sandbox; it neither uploads those data nor performs identity recognition.
Disabling retains cache; Settings > App analysis > Clear removes it. No originals
are stored by analysis and no automatic deletion occurs.
