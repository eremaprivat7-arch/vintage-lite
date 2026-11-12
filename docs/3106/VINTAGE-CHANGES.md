# VintageLite migration to 3106

Base project QuinnTang74/3106, release 3.2.3, commit bd7727ca7ab6b0477b83a3f2d3da6862db6d8d31.
VintageLite baseline eremaprivat7-arch/vintage-lite, commit bdb99d3db615fc5cb97301d1e782348535d9a731.

This derivative retains the upstream source and third-party notices in this folder and
the GPL-3.0 license at the repository root.

VintageLite modifications
- Integrated its existing license gate, maintenance/update screen and account countdown.
- Retained the licensing server URL, bundle identifier and activation Keychain service.
- Added a persisted device identifier initialized from the existing identifierForVendor.
- Changed the app display name, in-app logo and contact links.
- Connected bundled .3105 resources from the existing ThreeOneOSFive/Patches folder.
- Carried over the existing V9 decoder and its feature validation from VintageLite.
- Retained the known owner-supplied bundle password and protected bundled packages from
  in-app editing, deletion and export. This UI restriction does not prevent extraction
  of resources from a distributed IPA.
- Uses the 3106 application, feature layout and access implementations.
- Builds the new target with the existing GitHub Actions workflow on macos-15-intel.

The license-server directory, D1 schema, reseller bot and existing patch resources
are not part of the migration diff.
