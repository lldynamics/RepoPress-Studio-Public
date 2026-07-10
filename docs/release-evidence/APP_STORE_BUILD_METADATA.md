# App Store Build Metadata Evidence

This file records local App Store build metadata checks. It does not replace
the required clean Release archive, distribution signing team, hardened runtime,
or Transporter/App Store Connect validation evidence in
`APP_STORE_ARCHIVE_VALIDATION.md`.

## Latest Local Metadata Check

- Status: Local build metadata verified.
- Bundle identifier: `com.jinfang.PersonalSitePublisherMac`
- Marketing version: `1.0`
- Build number: `1`
- Minimum macOS: `14.0`
- App package type: `APPL`
- App icon: bundled AppIcon.icns verified.
- Localized InfoPlist strings: zh-Hans en verified.
- App Sandbox entitlement: enabled.
- Network Client entitlement: enabled.
- User Selected Read/Write entitlement: enabled.

## Boundary

This local metadata evidence does not verify distribution signing team,
hardened runtime on the signed archive, clean checkout archive reproducibility,
or Transporter/App Store Connect validation.
