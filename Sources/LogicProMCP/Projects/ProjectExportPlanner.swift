import Foundation
import MCP

enum ProjectExportPlanner {
    static let schema = "logic_pro_mcp_export_manifest.v1"
    static let supportedArtifactKinds: Set<String> = ["bounce", "stem", "preview", "variant"]

    static func plan(
        params: [String: Value],
        fileManager: FileManager = .default,
        stemSubjects: ProjectExportStemSubjectInventory? = nil
    ) throws -> ProjectExportPlan {
        let projects = try projectPaths(from: params)
        let outputRoot = try outputRoot(from: params, fileManager: fileManager)
        let artifacts = try artifactKinds(from: params)
        let collisionPolicy = stringParam(params, "collision_policy", default: "fail_if_exists")
        guard ["fail_if_exists", "skip_existing"].contains(collisionPolicy) else {
            throw ExportPlanError.invalid("collision_policy must be fail_if_exists or skip_existing")
        }
        let namingPolicy = try namingPolicy(from: params)
        let stemScope = try stemExportScope(from: params, artifactKinds: artifacts)
        try validateStemRequest(
            projects: projects,
            artifactKinds: artifacts,
            collisionPolicy: collisionPolicy,
            outputRoot: outputRoot,
            fileManager: fileManager,
            stemSubjects: stemSubjects
        )

        let rootURL = URL(fileURLWithPath: outputRoot).standardizedFileURL
        let projectPlans = projects.enumerated().map { index, path in
            projectPlan(
                index: index,
                path: path,
                outputRoot: rootURL,
                artifactKinds: artifacts,
                collisionPolicy: collisionPolicy,
                fileManager: fileManager,
                stemSubjects: stemSubjects,
                stemScope: stemScope
            )
        }

        // PR99-C1 / PR99-edge-2 / PR99-edge-3: aggregate every resolved artifact
        // path across ALL projects and flag any path produced by 2+ artifacts so
        // batch exports cannot silently overwrite each other (defeating
        // no_silent_overwrite). Comparison is case-insensitive because the default
        // macOS volumes (APFS/HFS+) are case-insensitive, so 'Song' and 'song'
        // collide on disk too. Each colliding artifact gets a forced issue, which
        // flips the plan to "degraded" via the existing non-empty-issues predicate.
        let resolvedProjectPlans = flagIntraPlanCollisions(projectPlans)

        let surfacedConstraints = unsupportedOrBlockedSteps(artifactKinds: artifacts)
        let status = resolvedProjectPlans.contains { project in
            project.validationStatus != "valid" ||
                project.expectedArtifacts.contains { !$0.verification.issues.isEmpty }
        }
            ? "degraded"
            : "planned"

        return ProjectExportPlan(
            schema: schema,
            runID: deterministicRunID(projects: projects, outputRoot: outputRoot, artifacts: artifacts),
            // C3: real run-window anchor so the advertised mtime_within_run_window
            // gate is evaluable — an executor bounds post-export mtime to >= this.
            generatedAt: ISO8601DateFormatter.cacheFormatter.string(from: Date()),
            status: status,
            executionMode: "dry_run_only",
            outputRoot: outputRoot,
            collisionPolicy: collisionPolicy,
            namingPolicy: namingPolicy,
            projectCount: resolvedProjectPlans.count,
            projects: resolvedProjectPlans,
            requiredConfirmations: requiredConfirmations(artifactKinds: artifacts),
            unsupportedOrBlockedSteps: surfacedConstraints,
            executionPreconditions: executionPreconditions(artifactKinds: artifacts),
            baselineVerification: [
                "artifact_exists",
                "file_size_non_zero",
                "mtime_within_run_window",
                "path_under_output_root",
                "no_silent_overwrite",
            ],
            enhancementPath: [
                "After a real bounce/export, verify each produced artifact with logic_audio.analyze_file (logic_pro_mcp_audio_analysis.v1) for duration, non-silence, peak/clipping, sample-rate, channels, and honest loudness estimates.",
            ],
            nextSafeAction: "review_export_plan"
        )
    }

    private static func projectPlan(
        index: Int,
        path: String,
        outputRoot: URL,
        artifactKinds: [String],
        collisionPolicy: String,
        fileManager: FileManager,
        stemSubjects: ProjectExportStemSubjectInventory?,
        stemScope: StemExportScope
    ) -> ProjectExportPlanProject {
        var issues: [String] = []
        if !AppleScriptSafety.isValidProjectPath(path, requireExisting: false) {
            issues.append("project_path_must_be_absolute_logicx")
        }
        if !fileManager.fileExists(atPath: path) {
            issues.append("project_path_not_found")
        }

        let projectURL = URL(fileURLWithPath: path).standardizedFileURL
        let displayName = projectURL.deletingPathExtension().lastPathComponent
        let artifactPlans = artifactKinds.map { kind in
            artifact(
                kind: kind,
                displayName: displayName,
                outputRoot: outputRoot,
                collisionPolicy: collisionPolicy,
                fileManager: fileManager,
                projectPath: path,
                stemSubjects: stemSubjects,
                stemScope: stemScope
            )
        }

        return ProjectExportPlanProject(
            index: index,
            projectPath: path,
            displayName: displayName,
            validationStatus: issues.isEmpty ? "valid" : "invalid",
            validationIssues: issues,
            expectedArtifacts: artifactPlans,
            workflowSteps: workflowSteps(for: index, artifactKinds: artifactKinds),
            manifestStatus: "pending"
        )
    }

    private static func artifact(
        kind: String,
        displayName: String,
        outputRoot: URL,
        collisionPolicy: String,
        fileManager: FileManager,
        projectPath: String,
        stemSubjects: ProjectExportStemSubjectInventory?,
        stemScope: StemExportScope
    ) -> ProjectExportPlanArtifact {
        if kind == "stem" {
            return stemArtifact(
                outputRoot: outputRoot,
                collisionPolicy: collisionPolicy,
                projectPath: projectPath,
                stemSubjects: stemSubjects,
                stemScope: stemScope,
                fileManager: fileManager
            )
        }
        // PR99-C2: validate containment against the PRE-sanitization candidate so
        // the check is non-vacuous. A raw displayName containing ".." or a path
        // separator can resolve outside outputRoot once standardized; the sanitized
        // url below can never express that, so it alone could only ever be true.
        let rawComponent = "\(displayName)-\(kind).wav"
        let candidate = outputRoot.appendingPathComponent(rawComponent).standardizedFileURL
        let underRoot = candidate.path == outputRoot.path || candidate.path.hasPrefix(outputRoot.path + "/")

        let safeProject = sanitizeFileComponent(displayName)
        let url = outputRoot.appendingPathComponent("\(safeProject)-\(kind).wav").standardizedFileURL
        let existingVariant = ProjectExportArtifactPathPolicy.preferredExistingVariant(
            for: url.path,
            fileManager: fileManager
        )
        let existingPath: String?
        var issues: [String] = []
        switch existingVariant {
        case .found(let path):
            existingPath = path
        case .absent:
            existingPath = nil
        case .unreadable(let reason):
            existingPath = nil
            issues.append("artifact_parent_unreadable")
            issues.append(reason)
        }
        let exists = existingPath != nil
        let attrs = existingPath.flatMap { try? fileManager.attributesOfItem(atPath: $0) }
        let size = (attrs?[.size] as? NSNumber)?.int64Value
        let mtime = (attrs?[.modificationDate] as? Date).map {
            ISO8601DateFormatter.cacheFormatter.string(from: $0)
        }
        if !underRoot {
            issues.append("artifact_path_outside_output_root")
        }
        if exists && collisionPolicy == "fail_if_exists" {
            issues.append("artifact_would_overwrite")
        }
        // PR99-C3: only assert a definite zero-byte artifact when the size is a
        // concrete value. A vanished/unreadable file (TOCTOU, permissions, or a
        // directory/special file at the path) yields a nil size — that is
        // "unknown", not "zero", so emit a distinct token instead of lying.
        if exists, let size, size == 0 {
            issues.append("artifact_zero_bytes")
        } else if exists, size == nil {
            issues.append("artifact_size_unreadable")
        }

        return ProjectExportPlanArtifact(
            kind: kind,
            path: url.path,
            status: exists ? "existing" : "pending",
            verification: ProjectExportArtifactVerification(
                exists: exists,
                fileSizeBytes: size,
                mtime: mtime,
                pathUnderOutputRoot: underRoot,
                wouldOverwrite: exists && collisionPolicy == "fail_if_exists",
                issues: issues,
                existingAudioFileCount: nil
            ),
            analysis: ["issue_29": "not_run_in_dry_run"],
            destination: nil,
            subjects: nil,
            filenamesLateBound: nil,
            stemScope: nil,
            planningReason: nil
        )
    }

    /// A stem is a destination plus live track subjects, never a guessed list
    /// of filenames. Logic assigns names and extensions only after Export.
    private static func stemArtifact(
        outputRoot: URL,
        collisionPolicy: String,
        projectPath: String,
        stemSubjects: ProjectExportStemSubjectInventory?,
        stemScope: StemExportScope,
        fileManager: FileManager
    ) -> ProjectExportPlanArtifact {
        let existingAudio = ProjectExportArtifactPathPolicy.supportedAudioEntries(
            in: outputRoot.path,
            fileManager: fileManager
        )
        let subjectResult = stemSubjects?.subjects(for: projectPath)
            ?? .unavailable("no identity-backed live track scan was supplied for this stem plan")

        var issues: [String] = []
        var planningReason: String?
        let subjects: [ProjectExportStemSubject]?
        switch subjectResult {
        case .scanned(let scanned):
            subjects = scanned
        case .unavailable(let reason):
            subjects = nil
            issues.append("stem_subject_list_unavailable")
            planningReason = "stem export is refused because its subject list must come from an identity-backed live track scan: \(reason)"
        }

        let existingAudioFiles: [String]
        switch existingAudio {
        case .files(let files):
            existingAudioFiles = files
            if !files.isEmpty {
                issues.append("stem_destination_contains_audio")
                planningReason = "fail_if_exists refused stem export because the destination already contains \(files.count) suffix-qualified top-level audio entry/entries. Stem filenames are late-bound, so a clean destination is required."
            }
        case .unreadable(let reason):
            existingAudioFiles = []
            issues.append("stem_destination_unreadable")
            planningReason = "fail_if_exists refused stem export because the destination cannot be enumerated: \(reason)"
        }

        return ProjectExportPlanArtifact(
            kind: "stem",
            // Compatibility field: for a late-bound artifact this names the
            // destination directory, not an individual artifact file.
            path: outputRoot.path,
            status: issues.isEmpty ? "pending" : "blocked",
            verification: ProjectExportArtifactVerification(
                exists: !existingAudioFiles.isEmpty,
                fileSizeBytes: nil,
                mtime: nil,
                pathUnderOutputRoot: true,
                wouldOverwrite: collisionPolicy == "fail_if_exists" && !existingAudioFiles.isEmpty,
                issues: issues,
                existingAudioFileCount: existingAudioFiles.count
            ),
            analysis: [
                "issue_29": "not_run_in_dry_run",
                "filenames": "late_bound_assigned_by_logic",
                "eligible_output_rule": "top-level non-directory entry with suffix wav|wave|aif|aiff|aifc|m4a|mp3",
                "stem_scope": stemScope.rawValue,
                // A stem plan never promises a file list. What it does promise differs by
                // scope, and the dry run says which: all-tracks cannot attribute a file to a
                // subject, per-track fixes each file's provenance before it exists.
                "stem_scope_plan": stemScope == .perTrack
                    ? "no_file_list_promised: \(subjects?.count ?? 0) export(s), one per subject, each driven with a proven-exclusive selection of that subject"
                    : "no_file_list_promised: one batch export for the whole project; file-to-subject binding is not established",
            ],
            destination: outputRoot.path,
            subjects: subjects,
            filenamesLateBound: true,
            stemScope: stemScope,
            planningReason: planningReason
        )
    }

    /// Reads `stem_scope` without letting it mean nothing.
    ///
    /// Absent means `.allTracks`, which is the behaviour every plan written before the parameter
    /// existed already had. Supplying it without a `stem` artifact is refused: a parameter that
    /// changes nothing is worse than no parameter, because the caller believes it did something.
    private static func stemExportScope(
        from params: [String: Value],
        artifactKinds: [String]
    ) throws -> StemExportScope {
        guard let value = params["stem_scope"] else { return .allTracks }
        guard artifactKinds.contains("stem") else {
            throw ExportPlanError.invalid(
                "stem_scope_requires_a_stem_artifact: stem_scope was supplied but the request has no \"stem\" artifact, so it would change nothing"
            )
        }
        guard let raw = value.stringValue, let scope = StemExportScope(rawValue: raw) else {
            throw ExportPlanError.invalid(
                "stem_scope must be all_tracks or per_track"
            )
        }
        return scope
    }

    /// Stem runs cannot acquire the subjects they promise from project metadata,
    /// and dry-run planning deliberately does not open a requested project.
    /// Refuse unsupported inputs before producing a normal-looking manifest.
    private static func validateStemRequest(
        projects: [String],
        artifactKinds: [String],
        collisionPolicy: String,
        outputRoot: String,
        fileManager: FileManager,
        stemSubjects: ProjectExportStemSubjectInventory?
    ) throws {
        guard artifactKinds.contains("stem") else { return }
        guard projects.count == 1 else {
            throw ExportPlanError.invalid(
                "stem_export_requires_one_currently_scanned_project: batch projects are unsupported because dry-run planning does not open projects to obtain a live subject inventory"
            )
        }
        guard collisionPolicy != "skip_existing" else {
            throw ExportPlanError.invalid(
                "stem_skip_existing_unsupported: Logic assigns stem filenames after export, so a dry run cannot establish the identity required to skip an existing stem"
            )
        }
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: outputRoot, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw ExportPlanError.invalid(
                "stem_output_root_must_be_an_existing_directory: a dry plan can validate only an existing filesystem directory; Logic export-browser visibility is an execution-time precondition"
            )
        }
        if case .unreadable(let reason) = ProjectExportArtifactPathPolicy.supportedAudioEntries(
            in: outputRoot,
            fileManager: fileManager
        ) {
            throw ExportPlanError.invalid(
                "stem_destination_unreadable: fail_if_exists requires a readable destination: \(reason)"
            )
        }
        let resolution = stemSubjects?.subjects(for: projects[0])
            ?? .unavailable("no fresh identity-backed populated-track scan was supplied")
        switch resolution {
        case .scanned(let subjects) where !subjects.isEmpty:
            return
        case .scanned:
            throw ExportPlanError.invalid(
                "stem_subject_list_empty: a stem export requires at least one populated track proven by the live region inventory"
            )
        case .unavailable(let reason):
            throw ExportPlanError.invalid("stem_subject_list_unavailable: \(reason)")
        }
    }

}

enum ExportPlanError: Error, CustomStringConvertible {
    case invalid(String)

    var description: String {
        switch self {
        case .invalid(let message):
            return message
        }
    }
}
