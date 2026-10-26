import Foundation

extension ProjectExportExecutor {
    static func overwriteBlockedArtifact(
        _ artifact: ProjectExportPlanArtifact,
        plan: ProjectExportPlan,
        options: Options
    ) -> RunArtifact? {
        guard plan.collisionPolicy == "fail_if_exists" else { return nil }
        if artifact.filenamesLateBound == true {
            let existingAudio = ProjectExportArtifactPathPolicy.supportedAudioEntries(
                in: artifact.destination ?? artifact.path,
                fileManager: options.fileManager
            )
            switch existingAudio {
            case .unreadable(let reason):
                return failedArtifact(
                    artifact,
                    error: "overwrite_check_unavailable: collision_policy=fail_if_exists requires a readable late-bound stem destination: \(reason)"
                )
            case .files(let files) where !files.isEmpty:
                return failedArtifact(
                    artifact,
                    error: "overwrite_blocked: collision_policy=fail_if_exists and the late-bound stem destination contains \(files.count) suffix-qualified top-level audio entry/entries"
                )
            case .files:
                break
            }
            return artifact.verification.wouldOverwrite
                ? failedArtifact(
                    artifact,
                    error: "overwrite_blocked: collision_policy=fail_if_exists and the late-bound stem destination already contained audio at plan time"
                )
                : nil
        }
        switch ProjectExportArtifactPathPolicy.preferredExistingVariant(
            for: artifact.path,
            fileManager: options.fileManager
        ) {
        case .found(let blockingPath):
            return failedArtifact(
                artifact,
                error: "overwrite_blocked: collision_policy=\(plan.collisionPolicy) and artifact already exists at \(blockingPath)"
            )
        case .unreadable(let reason):
            return failedArtifact(
                artifact,
                error: "overwrite_check_unavailable: collision_policy=\(plan.collisionPolicy) requires a readable destination: \(reason)"
            )
        case .absent:
            break
        }
        if artifact.verification.wouldOverwrite {
            return failedArtifact(
                artifact,
                error: "overwrite_blocked: collision_policy=\(plan.collisionPolicy) and artifact already exists"
            )
        }
        return nil
    }

    static func preflightArtifactOutcome(
        _ artifact: ProjectExportPlanArtifact,
        plan: ProjectExportPlan,
        options: Options
    ) -> RunArtifact? {
        if let overwriteBlocked = overwriteBlockedArtifact(artifact, plan: plan, options: options) {
            return overwriteBlocked
        }
        if artifact.filenamesLateBound == true {
            guard artifact.verification.issues.isEmpty else {
                return failedArtifact(
                    artifact,
                    error: artifact.planningReason ?? "late_bound_stem_blocked: \(artifact.verification.issues.joined(separator: ","))"
                )
            }
            return nil
        }
        if artifact.verification.exists {
            guard artifact.verification.issues.isEmpty else {
                return failedArtifact(
                    artifact,
                    error: "artifact_blocked: \(artifact.verification.issues.joined(separator: ","))"
                )
            }
            return skippedArtifact(artifact, options: options, outputRoot: plan.outputRoot)
        }
        guard artifact.verification.issues.isEmpty else {
            return failedArtifact(
                artifact,
                error: "artifact_blocked: \(artifact.verification.issues.joined(separator: ","))"
            )
        }
        return nil
    }

    static func produceArtifacts(
        artifact: ProjectExportPlanArtifact,
        plan: ProjectExportPlan,
        router: ChannelRouter,
        options: Options
    ) async -> [RunArtifact] {
        if artifact.filenamesLateBound == true {
            return await produceStem(artifact: artifact, plan: plan, options: options)
        }
        return [await produce(artifact: artifact, plan: plan, router: router, options: options)]
    }

    private static func produce(
        artifact: ProjectExportPlanArtifact,
        plan: ProjectExportPlan,
        router: ChannelRouter,
        options: Options
    ) async -> RunArtifact {
        if let overwriteBlocked = overwriteBlockedArtifact(artifact, plan: plan, options: options) {
            return overwriteBlocked
        }
        if !artifact.verification.issues.isEmpty {
            return failedArtifact(
                artifact,
                error: "artifact_blocked: \(artifact.verification.issues.joined(separator: ","))"
            )
        }

        // Settings read off the Bounce dialog by the helper, carried on EVERY return path below.
        // A failed render still knows which settings were attempted, and discarding them is the
        // habit this record exists to break.
        var bounceSettings: [String: String]? = nil
        var bounceSettingsReadStatus: String? = nil

        let producedPath: String
        if let bounce = options.bounceToPath {
            let bounceResult = await bounce(artifact.path)
            bounceSettings = bounceResult.settings
            bounceSettingsReadStatus = bounceResult.settings == nil ? "unreadable" : "ok"
            guard let produced = bounceResult.artifactPath else {
                return RunArtifact(
                    kind: artifact.kind,
                    path: artifact.path,
                    state: "C",
                    verified: false,
                    bounceFired: bounceResult.bounceFired,
                    writeAttempted: bounceResult.bounceFired,
                    error: "bounce_helper_failed: \(bounceResult.error ?? "no verified artifact produced for \(artifact.path)")",
                    reason: nil,
                    evidence: nil,
                    bounceSettings: bounceSettings,
                    bounceSettingsReadStatus: bounceSettingsReadStatus
                )
            }
            guard ProjectExportArtifactPathPolicy.helperProducedPathMatchesPlannedStem(
                producedPath: produced,
                plannedPath: artifact.path
            ) else {
                return failedArtifact(
                    artifact,
                    error: "bounce_helper_unexpected_artifact_path: expected stem \(ProjectExportArtifactPathPolicy.standardizedStemPath(artifact.path)) but helper returned \(produced)",
                    bounceFired: true,
                    bounceSettings: bounceSettings,
                    bounceSettingsReadStatus: bounceSettingsReadStatus
                )
            }
            producedPath = produced
        } else {
            let bounceResult = await router.route(operation: "project.bounce")
            guard bounceResult.isSuccess else {
                return RunArtifact(
                    kind: artifact.kind,
                    path: artifact.path,
                    state: "C",
                    verified: false,
                    bounceFired: false,
                    writeAttempted: false,
                    error: "bounce_failed: \(bounceResult.message)",
                    reason: nil,
                    evidence: nil
                )
            }
            let appeared = await waitForArtifact(path: artifact.path, options: options)
            guard appeared else {
                return RunArtifact(
                    kind: artifact.kind,
                    path: artifact.path,
                    state: "B",
                    verified: false,
                    bounceFired: true,
                    writeAttempted: true,
                    error: nil,
                    reason: "artifact_not_observed_within_poll_window",
                    evidence: nil
                )
            }
            producedPath = artifact.path
        }

        let analysis = options.analyze(producedPath, analysisPolicy(plan: plan, options: options))
        if analysis.verification.reasons.contains("unsafe_path") {
            return failedArtifact(
                artifact,
                error: "artifact_path_unsafe: \(analysis.verification.detail ?? analysis.verification.reasons.joined(separator: ","))",
                bounceFired: true,
                bounceSettings: bounceSettings,
                bounceSettingsReadStatus: bounceSettingsReadStatus
            )
        }
        let evidence = ArtifactEvidence(from: analysis, source: "audio_analyzer")
        if analysis.verification.status == .pass {
            return RunArtifact(
                kind: artifact.kind,
                path: producedPath,
                state: "A",
                verified: true,
                bounceFired: true,
                writeAttempted: true,
                error: nil,
                reason: nil,
                evidence: evidence,
                bounceSettings: bounceSettings,
                bounceSettingsReadStatus: bounceSettingsReadStatus
            )
        }
        return RunArtifact(
            kind: artifact.kind,
            path: producedPath,
            state: "B",
            verified: false,
            bounceFired: true,
            writeAttempted: true,
            error: nil,
            reason: "artifact_unverified: \(analysis.verification.reasons.joined(separator: ","))",
            evidence: evidence,
            bounceSettings: bounceSettings,
            bounceSettingsReadStatus: bounceSettingsReadStatus
        )
    }

    /// Produce a stem batch exactly once, then record the eligible files in
    /// the destination's before/after delta. The file list is observed only
    /// after the progress window disappears; it is never fabricated from track
    /// names or mistaken for a filename-to-subject binding.
    private static func produceStem(
        artifact: ProjectExportPlanArtifact,
        plan: ProjectExportPlan,
        options: Options
    ) async -> [RunArtifact] {
        let destination = artifact.destination ?? artifact.path
        guard let subjects = artifact.subjects, !subjects.isEmpty else {
            return [failedArtifact(
                artifact,
                error: "stem_subject_list_unavailable_at_execution: refusing export without populated-track subjects"
            )]
        }
        guard artifact.verification.issues.isEmpty else {
            return stemSubjectArtifacts(
                artifact: artifact,
                destination: destination,
                subjects: subjects,
                state: "C",
                bounceFired: false,
                writeAttempted: false,
                error: artifact.planningReason ?? "late_bound_stem_blocked: \(artifact.verification.issues.joined(separator: ","))",
                reason: nil,
                observations: nil
            )
        }
        guard let drive = options.driveStemExport else {
            return stemSubjectArtifacts(
                artifact: artifact,
                destination: destination,
                subjects: subjects,
                state: "C",
                bounceFired: false,
                writeAttempted: false,
                error: "stem_export_panel_unavailable: refusing to use project.bounce for a stem artifact",
                reason: nil,
                observations: nil
            )
        }
        // A per-track run exports one subject at a time. It is the only route on
        // which a produced file can be attributed to a track, because the driver
        // proves an exclusive selection of that track before the menu opens.
        if artifact.stemScope == .perTrack {
            return await produceStemPerTrack(
                artifact: artifact,
                plan: plan,
                subjects: subjects,
                drive: drive,
                options: options
            )
        }

        // The plan's collision read can become stale before the panel opens.
        // This later, immediately-pre-export snapshot is authoritative: if it
        // is no longer empty under fail_if_exists, do not drive the panel.
        let before: [String]
        switch ProjectExportArtifactPathPolicy.supportedAudioEntries(
            in: destination,
            fileManager: options.fileManager
        ) {
        case .files(let files) where plan.collisionPolicy == "fail_if_exists" && !files.isEmpty:
            return stemSubjectArtifacts(
                artifact: artifact,
                destination: destination,
                subjects: subjects,
                state: "C",
                bounceFired: false,
                writeAttempted: false,
                error: "overwrite_blocked: collision_policy=fail_if_exists and the authoritative immediately-pre-export stem snapshot contains \(files.count) suffix-qualified top-level audio entry/entries",
                reason: nil,
                observations: nil
            )
        case .files(let files):
            before = files
        case .unreadable(let reason):
            return stemSubjectArtifacts(
                artifact: artifact,
                destination: destination,
                subjects: subjects,
                state: "C",
                bounceFired: false,
                writeAttempted: false,
                error: "stem_output_snapshot_unavailable_before_export: \(reason)",
                reason: nil,
                observations: nil
            )
        }

        switch await drive(destination, .allTracks, nil) {
        case .refused(let error):
            return stemSubjectArtifacts(
                artifact: artifact,
                destination: destination,
                subjects: subjects,
                state: "C",
                bounceFired: false,
                writeAttempted: false,
                error: error,
                reason: nil,
                observations: nil
            )
        case let .uncertain(reason, exportEffectObserved):
            return stemSubjectArtifacts(
                artifact: artifact,
                destination: destination,
                subjects: subjects,
                state: "B",
                // A status-success AXPress is not evidence that the export
                // fired. `bounceFired` is true only when the driver observed
                // the progress dialog after the press. `writeAttempted` records
                // the distinct fact that the driver had reached the Export
                // actuator before this post-press observation phase.
                bounceFired: exportEffectObserved,
                writeAttempted: true,
                error: nil,
                reason: reason,
                observations: nil
            )
        case .completed, .completedSelectionRestoreUnproven:
            // The all-tracks route keeps no selection custody, so the second case
            // cannot arise here; the artifact still follows its normal path.
            break
        }

        let after: [String]
        switch ProjectExportArtifactPathPolicy.supportedAudioEntries(
            in: destination,
            fileManager: options.fileManager
        ) {
        case .files(let files):
            after = files
        case .unreadable(let reason):
            return stemSubjectArtifacts(
                artifact: artifact,
                destination: destination,
                subjects: subjects,
                state: "B",
                bounceFired: true,
                writeAttempted: true,
                error: nil,
                reason: "stem_output_snapshot_unavailable_after_export: \(reason)",
                observations: nil
            )
        }

        let beforeSet = Set(before)
        let appeared = after.filter { !beforeSet.contains($0) }
        let observations = appeared.map {
            stemOutputObservation(path: $0, plan: plan, options: options)
        }
        let reason: String
        if appeared.isEmpty {
            reason = "stem_audio_files_not_observed_after_progress_completion: observed=0 expected=\(subjects.count)"
        } else if appeared.count != subjects.count {
            reason = "stem_subject_count_mismatch: observed=\(appeared.count) expected=\(subjects.count); file-to-subject binding and output attribution were not established, so post-snapshot entries may have been created concurrently"
        } else {
            reason = "stem_subject_file_binding_unestablished: observed=\(appeared.count) expected=\(subjects.count); filenames are late-bound, no name-matching rule is used, and post-snapshot entries may have been created concurrently"
        }
        // One result per populated track is preserved, but none is promoted to
        // State A: the observed output list has no evidence that a particular
        // file belongs to a particular subject. The observations carry the
        // real per-file analyzer results without inventing that association.
        return stemSubjectArtifacts(
            artifact: artifact,
            destination: destination,
            subjects: subjects,
            state: "B",
            bounceFired: true,
            writeAttempted: true,
            error: nil,
            reason: reason,
            observations: observations
        )
    }

    /// Export one subject at a time, binding the file to the subject by
    /// construction: the driver proves an exclusive selection of that subject
    /// before the panel opens, so exactly one new file in the destination during
    /// that subject's own window can only be that subject's output.
    ///
    /// `fail_if_exists` is deliberately NOT weakened here. A per-subject delta
    /// cannot distinguish "a new file appeared" from "an existing file was
    /// overwritten", because Logic's filename is unknown before the export runs;
    /// allowing a non-empty destination would turn an overwrite into a silent
    /// zero-file observation. The pre-run refusal therefore stays.
    private static func produceStemPerTrack(
        artifact: ProjectExportPlanArtifact,
        plan: ProjectExportPlan,
        subjects: [ProjectExportStemSubject],
        drive: StemExportDrive,
        options: Options
    ) async -> [RunArtifact] {
        let destination = artifact.destination ?? artifact.path
        if plan.collisionPolicy == "fail_if_exists" {
            switch ProjectExportArtifactPathPolicy.supportedAudioEntries(
                in: destination,
                fileManager: options.fileManager
            ) {
            case .files(let files) where !files.isEmpty:
                return stemSubjectArtifacts(
                    artifact: artifact,
                    destination: destination,
                    subjects: subjects,
                    state: "C",
                    bounceFired: false,
                    writeAttempted: false,
                    error: "overwrite_blocked: collision_policy=fail_if_exists and the authoritative immediately-pre-export stem snapshot contains \(files.count) suffix-qualified top-level audio entry/entries",
                    reason: nil,
                    observations: nil
                )
            case .unreadable(let reason):
                return stemSubjectArtifacts(
                    artifact: artifact,
                    destination: destination,
                    subjects: subjects,
                    state: "C",
                    bounceFired: false,
                    writeAttempted: false,
                    error: "stem_output_snapshot_unavailable_before_export: \(reason)",
                    reason: nil,
                    observations: nil
                )
            case .files:
                break
            }
        }

        /// Every artifact the run produced carries a run-level restore warning, so
        /// a selection the user left where it was never becomes a silent change.
        var runWarnings: [String] = []
        var results: [RunArtifact] = []
        for subject in subjects {
            let result = await produceStemForSubject(
                subject: subject,
                artifact: artifact,
                plan: plan,
                destination: destination,
                drive: drive,
                options: options,
                runWarnings: &runWarnings
            )
            results.append(result)
        }
        guard !runWarnings.isEmpty else { return results }
        return results.map { result in
            RunArtifact(
                kind: result.kind,
                path: result.path,
                state: result.state,
                verified: result.verified,
                bounceFired: result.bounceFired,
                writeAttempted: result.writeAttempted,
                error: result.error,
                reason: result.reason,
                evidence: result.evidence,
                subject: result.subject,
                observedStemOutputs: result.observedStemOutputs,
                bounceSettings: result.bounceSettings,
                bounceSettingsReadStatus: result.bounceSettingsReadStatus,
                warnings: (result.warnings ?? []) + runWarnings
            )
        }
    }

    private static func produceStemForSubject(
        subject: ProjectExportStemSubject,
        artifact: ProjectExportPlanArtifact,
        plan: ProjectExportPlan,
        destination: String,
        drive: StemExportDrive,
        options: Options,
        runWarnings: inout [String]
    ) async -> RunArtifact {
        func artifactResult(
            state: String,
            path: String,
            verified: Bool,
            bounceFired: Bool,
            writeAttempted: Bool,
            error: String?,
            reason: String?,
            evidence: ProjectExportArtifactEvidence? = nil,
            observations: [ProjectExportObservedStemOutput]? = nil
        ) -> RunArtifact {
            RunArtifact(
                kind: artifact.kind,
                path: path,
                state: state,
                verified: verified,
                bounceFired: bounceFired,
                writeAttempted: writeAttempted,
                error: error,
                reason: reason,
                evidence: evidence,
                subject: subject,
                observedStemOutputs: observations
            )
        }

        // The fence around THIS subject's export window. A later snapshot that
        // gains more than one file means the attribution this route depends on
        // did not hold, and that is reported rather than picked apart.
        let before: [String]
        switch ProjectExportArtifactPathPolicy.supportedAudioEntries(
            in: destination,
            fileManager: options.fileManager
        ) {
        case .files(let files):
            before = files
        case .unreadable(let reason):
            return artifactResult(
                state: "C",
                path: destination,
                verified: false,
                bounceFired: false,
                writeAttempted: false,
                error: "stem_output_snapshot_unavailable_before_export: \(reason)",
                reason: nil
            )
        }

        var exportCompleted = false
        switch await drive(destination, .perTrack, subject) {
        case .refused(let error):
            return artifactResult(
                state: "C",
                path: destination,
                verified: false,
                bounceFired: false,
                writeAttempted: false,
                error: error,
                reason: nil
            )
        case let .uncertain(reason, exportEffectObserved):
            return artifactResult(
                state: "B",
                path: destination,
                verified: false,
                bounceFired: exportEffectObserved,
                writeAttempted: true,
                error: nil,
                reason: reason
            )
        case let .completedSelectionRestoreUnproven(warning):
            runWarnings.append("selection_restore_unproven: \(warning)")
            exportCompleted = true
        case .completed:
            exportCompleted = true
        }
        guard exportCompleted else {
            return artifactResult(
                state: "B",
                path: destination,
                verified: false,
                bounceFired: false,
                writeAttempted: true,
                error: nil,
                reason: "stem_export_completion_not_established"
            )
        }

        let after: [String]
        switch ProjectExportArtifactPathPolicy.supportedAudioEntries(
            in: destination,
            fileManager: options.fileManager
        ) {
        case .files(let files):
            after = files
        case .unreadable(let reason):
            return artifactResult(
                state: "B",
                path: destination,
                verified: false,
                bounceFired: true,
                writeAttempted: true,
                error: nil,
                reason: "stem_output_snapshot_unavailable_after_export: \(reason)"
            )
        }

        let beforeSet = Set(before)
        let appeared = after.filter { !beforeSet.contains($0) }
        guard appeared.count == 1, let produced = appeared.first else {
            return artifactResult(
                state: "B",
                path: destination,
                verified: false,
                bounceFired: true,
                writeAttempted: true,
                error: nil,
                reason: "per_track_export_observed_n_files: observed=\(appeared.count) expected=1 for subject index=\(subject.index) name=\(subject.name); the file-to-subject binding this route rests on did not hold"
            )
        }

        // `supportedAudioEntries` returns absolute paths, so the appeared entry is
        // already the file this subject produced.
        let producedPath = produced
        let observation = stemOutputObservation(path: producedPath, plan: plan, options: options)
        guard observation.verified else {
            return artifactResult(
                state: "B",
                path: producedPath,
                verified: false,
                bounceFired: true,
                writeAttempted: true,
                error: nil,
                reason: observation.reason,
                evidence: observation.evidence,
                observations: [observation]
            )
        }
        // State A: the selection was proven exclusive for this subject before the
        // menu opened, exactly one file appeared in that subject's own window, and
        // the analyzer verified it. That chain is what the batch route lacks.
        return artifactResult(
            state: "A",
            path: producedPath,
            verified: true,
            bounceFired: true,
            writeAttempted: true,
            error: nil,
            reason: nil,
            evidence: observation.evidence,
            observations: [observation]
        )
    }

    private static func stemOutputObservation(
        path: String,
        plan: ProjectExportPlan,
        options: Options
    ) -> ProjectExportObservedStemOutput {
        let analysis = options.analyze(path, analysisPolicy(plan: plan, options: options))
        let evidence = ArtifactEvidence(from: analysis, source: "audio_analyzer")
        if analysis.verification.reasons.contains("unsafe_path") {
            return ProjectExportObservedStemOutput(
                path: path,
                verified: false,
                reason: "artifact_path_unsafe: \(analysis.verification.detail ?? analysis.verification.reasons.joined(separator: ","))",
                evidence: evidence
            )
        }
        if analysis.verification.status == .pass {
            return ProjectExportObservedStemOutput(
                path: path,
                verified: true,
                reason: nil,
                evidence: evidence
            )
        }
        return ProjectExportObservedStemOutput(
            path: path,
            verified: false,
            reason: "artifact_unverified: \(analysis.verification.reasons.joined(separator: ","))",
            evidence: evidence
        )
    }

    static func stemSubjectArtifacts(
        artifact: ProjectExportPlanArtifact,
        destination: String,
        subjects: [ProjectExportStemSubject],
        state: String,
        bounceFired: Bool,
        writeAttempted: Bool,
        error: String?,
        reason: String?,
        observations: [ProjectExportObservedStemOutput]?
    ) -> [RunArtifact] {
        subjects.map { subject in
            RunArtifact(
                kind: artifact.kind,
                path: destination,
                state: state,
                verified: false,
                bounceFired: bounceFired,
                writeAttempted: writeAttempted,
                error: error,
                reason: reason,
                evidence: nil,
                subject: subject,
                observedStemOutputs: observations
            )
        }
    }

    /// A late-bound stem has one result per requested subject even when it
    /// refuses before the panel opens.  An unscoped preflight result would
    /// otherwise change result cardinality merely because it ran early.
    static func subjectScopedArtifacts(
        _ result: RunArtifact,
        for artifact: ProjectExportPlanArtifact
    ) -> [RunArtifact] {
        guard artifact.filenamesLateBound == true,
              let subjects = artifact.subjects,
              !subjects.isEmpty else {
            return [result]
        }
        return subjects.map { subject in
            RunArtifact(
                kind: result.kind,
                path: result.path,
                state: result.state,
                verified: result.verified,
                bounceFired: result.bounceFired,
                writeAttempted: result.writeAttempted,
                error: result.error,
                reason: result.reason,
                evidence: result.evidence,
                subject: subject,
                observedStemOutputs: result.observedStemOutputs
            )
        }
    }

    static func analysisPolicy(plan: ProjectExportPlan, options: Options) -> AudioAnalyzer.AnalysisPolicy {
        var policy = AudioAnalyzer.AnalysisPolicy.default
        policy.outputRoot = plan.outputRoot
        policy.minimumDurationSeconds = options.minimumDurationSeconds
        policy.minimumFileSizeBytes = 1
        return policy
    }

    static func waitForArtifact(path: String, options: Options) async -> Bool {
        var attempt = 0
        while attempt < max(1, options.pollAttempts) {
            var isDir: ObjCBool = false
            if options.fileManager.fileExists(atPath: path, isDirectory: &isDir), !isDir.boolValue {
                return true
            }
            attempt += 1
            if attempt < options.pollAttempts {
                await options.sleep(options.pollIntervalNanos)
            }
        }
        var isDir: ObjCBool = false
        return options.fileManager.fileExists(atPath: path, isDirectory: &isDir) && !isDir.boolValue
    }

    static func skippedArtifact(
        _ artifact: ProjectExportPlanArtifact,
        options: Options,
        outputRoot: String
    ) -> RunArtifact {
        guard artifact.verification.exists,
              artifact.verification.issues.isEmpty else {
            return RunArtifact(
                kind: artifact.kind,
                path: artifact.path,
                state: "C",
                verified: false,
                bounceFired: false,
                writeAttempted: false,
                error: "skip_precondition_failed",
                reason: nil,
                evidence: nil
            )
        }
        let existingPath: String
        switch ProjectExportArtifactPathPolicy.preferredExistingVariant(
            for: artifact.path,
            fileManager: options.fileManager
        ) {
        case .found(let path):
            existingPath = path
        case .absent:
            return RunArtifact(
                kind: artifact.kind,
                path: artifact.path,
                state: "C",
                verified: false,
                bounceFired: false,
                writeAttempted: false,
                error: "skip_precondition_failed",
                reason: nil,
                evidence: nil
            )
        case .unreadable(let reason):
            return RunArtifact(
                kind: artifact.kind,
                path: artifact.path,
                state: "C",
                verified: false,
                bounceFired: false,
                writeAttempted: false,
                error: "skip_precondition_unavailable: \(reason)",
                reason: nil,
                evidence: nil
            )
        }
        var policy = AudioAnalyzer.AnalysisPolicy.default
        policy.outputRoot = outputRoot
        policy.minimumDurationSeconds = options.minimumDurationSeconds
        policy.minimumFileSizeBytes = 1
        let analysis = options.analyze(existingPath, policy)
        if analysis.verification.reasons.contains("unsafe_path") {
            return RunArtifact(
                kind: artifact.kind,
                path: existingPath,
                state: "C",
                verified: false,
                bounceFired: false,
                writeAttempted: false,
                error: "existing_artifact_path_unsafe: \(analysis.verification.detail ?? analysis.verification.reasons.joined(separator: ","))",
                reason: nil,
                evidence: nil
            )
        }
        let evidence = ArtifactEvidence(from: analysis, source: "skip_reverify")
        guard analysis.verification.status == .pass else {
            return RunArtifact(
                kind: artifact.kind,
                path: existingPath,
                state: "B",
                verified: false,
                bounceFired: false,
                writeAttempted: false,
                error: nil,
                reason: "existing_artifact_unverified: \(analysis.verification.reasons.joined(separator: ","))",
                evidence: evidence
            )
        }
        return RunArtifact(
            kind: artifact.kind,
            path: existingPath,
            state: "A",
            verified: true,
            bounceFired: false,
            writeAttempted: false,
            error: nil,
            reason: "skipped_already_verified",
            evidence: evidence
        )
    }

    static func failedArtifact(
        _ artifact: ProjectExportPlanArtifact,
        error: String,
        bounceFired: Bool = false,
        bounceSettings: [String: String]? = nil,
        bounceSettingsReadStatus: String? = nil
    ) -> RunArtifact {
        RunArtifact(
            kind: artifact.kind,
            path: artifact.path,
            state: "C",
            verified: false,
            bounceFired: bounceFired,
            writeAttempted: bounceFired,
            error: error,
            reason: nil,
            evidence: nil,
            bounceSettings: bounceSettings,
            bounceSettingsReadStatus: bounceSettingsReadStatus
        )
    }
}
