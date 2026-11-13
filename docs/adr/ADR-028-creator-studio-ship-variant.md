# ADR-028: Logic Pro Creator Studio as Primary Ship Variant

## Status
`Accepted`

## Context
Historically, ADR-001 established Desktop Logic Pro (`com.apple.logic10`, `/Applications/Logic Pro.app`) as the sole qualified ship variant, treating Apple Creator Studio (`com.apple.mobilelogic`, `/Applications/Logic Pro Creator Studio.app`) as out of scope. 

However, Apple has updated macOS environments to Logic Pro Creator Studio 13.0, replacing desktop Logic Pro on upgraded machines. Real-world target deployments now run Creator Studio as the exclusive available host. Restricting qualification strictly to `.desktop` causes qualification gates and release tooling to fail or reject valid installations.

## Decision
1. **Primary Ship Variant:** Supersede ADR-001's desktop-only restriction by officially recognizing Logic Pro Creator Studio (`LogicVariant.creatorStudio`, `com.apple.mobilelogic`) as a supported and qualified ship variant alongside Desktop Logic Pro (`LogicVariant.desktop`, `com.apple.logic10`).
2. **Qualification Matrix:** Update `ReleaseQualificationAttestation.shipVariants` to include both `.creatorStudio` and `.desktop` so that test matrices and release validation cover both installed variants depending on the host environment.
3. **Runtime Target Selection:** Maintain runtime flexibility via `LogicProTarget` to target running or installed variants, with preference for detected/running instances.
