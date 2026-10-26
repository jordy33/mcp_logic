@preconcurrency import ApplicationServices
import Foundation
import MCP
import Testing
@testable import LogicProMCP

// mix-master T1 — a per-track stem run binds each produced file to the track it came from.
//
// The binding is by construction, not by filename: the driver proves an exclusive selection of one
// subject before the menu opens, so exactly one new file during that subject's own export window can
// only be that subject's output. These tests drive the state machine and the executor against
// semantic fakes; they do NOT exercise AXSurface's live menu walk, which remains for the user's live
// acceptance.

// MARK: - Driver surface

private final class PerTrackSurfaceFake: ProjectStemExportPanelDriver.Surface, @unchecked Sendable {
    var events: [String] = []
    /// The Arrange selection as the fake reports it. nil models an unreadable flag.
    var selection: [Int]? = []
    var selectRefusal: String?
    var restoreFailure: String?
    var restoreIsProven = true
    var panelPresent = true

    func captureSelection() -> ProjectStemExportPanelDriver.SelectionSnapshot? {
        events.append("capture_selection")
        return selection.map(ProjectStemExportPanelDriver.SelectionSnapshot.init(indices:))
    }

    func selectSubject(index: Int, name: String) -> ProjectStemExportPanelDriver.SubjectSelection {
        events.append("select_subject_\(index)_\(name)")
        if let selectRefusal { return .refused(selectRefusal) }
        selection = [index]
        return .selected
    }

    func restoreSelection(_ snapshot: ProjectStemExportPanelDriver.SelectionSnapshot) -> String? {
        events.append("restore_selection_\(snapshot.indices)")
        if restoreFailure == nil { selection = snapshot.indices }
        return restoreFailure
    }

    func selectionMatches(_ snapshot: ProjectStemExportPanelDriver.SelectionSnapshot) -> Bool {
        events.append("selection_matches")
        return restoreIsProven && selection == snapshot.indices
    }

    func openFileMenu() -> Bool {
        events.append("file_open")
        return true
    }

    func openExportMenu() -> ProjectStemExportPanelDriver.MenuAvailability {
        events.append("export_open")
        return .available
    }

    func resolveStemLeaf() -> ProjectStemExportPanelDriver.MenuAvailability {
        events.append("leaf_read")
        return .available
    }

    func pickStemLeaf() {
        events.append("leaf_pick")
    }

    func exportPanelPresence() -> ProjectStemExportPanelDriver.PanelPresence {
        events.append("panel_read")
        return panelPresent ? .present : .absent
    }

    func destinationPopupValue() -> String? {
        events.append("destination_popup_read")
        return "/Stems"
    }

    func selectDestinationBrowserElement(
        at path: String
    ) -> ProjectStemExportPanelDriver.DestinationSelection {
        events.append("destination_select")
        return .selected
    }

    func oneFilePerTrackIsActive() -> Bool {
        events.append("per_track_read")
        return true
    }

    func pressExport() {
        events.append("export_press")
    }

    func progressWindowPresence() -> ProjectStemExportPanelDriver.ProgressPresence {
        events.append("progress_read")
        return events.filter { $0 == "progress_read" }.count == 1 ? .present : .absent
    }

    func closeExportPanel() {
        events.append("panel_close")
        panelPresent = false
    }
}

private func driveWithScope(
    _ surface: PerTrackSurfaceFake,
    scope: StemExportScope,
    subject: ProjectExportStemSubject?,
    destination: String = "/Stems"
) async -> ProjectStemExportPanelDriver.Outcome {
    await ProjectStemExportPanelDriver.drive(
        destination: destination,
        scope: scope,
        subject: subject,
        surface: surface,
        progressPollAttempts: 4,
        sleep: { _ in },
        pollIntervalNanos: 1,
        monotonicNowNanos: { 0 }
    )
}

// MARK: - Driver

@Suite("mix-master T1 per-track stem leaf and selection custody")
struct StemPerTrackDriverTests {
    @Test("the per-track scope resolves the singular leaf and never the all-tracks one")
    func leafMatcherIsScopeSpecific() {
        #expect(ProjectStemExportPanelDriver.stemLeafTitleMatches(
            "1 Track as Audio File…", scope: .perTrack))
        #expect(!ProjectStemExportPanelDriver.stemLeafTitleMatches(
            "All Tracks as Audio Files…", scope: .perTrack))
        #expect(!ProjectStemExportPanelDriver.stemLeafTitleMatches(
            "1 Track as Audio File…", scope: .allTracks))
        #expect(ProjectStemExportPanelDriver.stemLeafTitleMatches(
            "All Tracks as Audio Files…", scope: .allTracks))
    }

    @Test("a per-track surface that finds only the all-tracks leaf refuses instead of picking it")
    func perTrackSurfaceRefusesTheAllTracksLeaf() {
        let builder = FakeAXRuntimeBuilder()
        let app = builder.element(40001)
        let leaf = builder.element(40002)
        builder.setAttribute(leaf, kAXRoleAttribute as String, kAXMenuItemRole as String)
        builder.setAttribute(leaf, kAXTitleAttribute as String, "All Tracks as Audio Files…")
        builder.setAttribute(leaf, kAXEnabledAttribute as String, true)
        builder.setChildren(app, [leaf])
        let runtime = builder.makeLogicRuntime(appElement: app)

        let perTrack = AXSurface(scope: .perTrack, runtime: runtime)
        #expect(perTrack.resolveStemLeaf() == .unavailable(
            ProjectStemExportPanelDriver.stemScopeLeafMismatchReason))

        // The same tree is the ordinary available leaf for an all-tracks run: the refusal is
        // about the scope mismatch, not about the leaf being unreadable.
        let allTracks = AXSurface(scope: .allTracks, runtime: runtime)
        #expect(allTracks.resolveStemLeaf() == .available)
    }

    @Test("a leaf the label set never measured is refused as unmeasured, not picked as a near-miss")
    func unmeasuredPerTrackLeafRefuses() {
        let builder = FakeAXRuntimeBuilder()
        let app = builder.element(40011)
        let leaf = builder.element(40012)
        builder.setAttribute(leaf, kAXRoleAttribute as String, kAXMenuItemRole as String)
        // No locale has a measured singular leaf beyond en-US. This is a synthetic near-miss
        // (the canonical title without its ellipsis) standing in for any such locale: matching
        // must be exact, so nothing here may resolve.
        builder.setAttribute(leaf, kAXTitleAttribute as String, "1 Track as Audio File")
        builder.setAttribute(leaf, kAXEnabledAttribute as String, true)
        builder.setChildren(app, [leaf])
        let runtime = builder.makeLogicRuntime(appElement: app)

        let perTrack = AXSurface(scope: .perTrack, runtime: runtime)
        #expect(perTrack.resolveStemLeaf() == .unavailable(
            ProjectStemExportPanelDriver.stemPerTrackLeafLabelNotMeasuredReason))
    }

    @Test("a per-track drive selects its subject before the menu opens and restores afterwards")
    func perTrackSelectsAndRestores() async throws {
        let surface = PerTrackSurfaceFake()
        surface.selection = [3]

        let outcome = await driveWithScope(
            surface, scope: .perTrack, subject: .init(index: 1, name: "Bass / DI")
        )

        #expect(outcome == .completed)
        let selectIndex = try #require(surface.events.firstIndex(of: "select_subject_1_Bass / DI"))
        let openIndex = try #require(surface.events.firstIndex(of: "file_open"))
        #expect(selectIndex < openIndex, "the selection must be proven before anything is opened")
        let restoreIndex = try #require(surface.events.firstIndex(of: "restore_selection_[3]"))
        #expect(restoreIndex > openIndex)
        #expect(surface.events.contains("selection_matches"))
    }

    @Test("an unprovable exclusive selection refuses without touching the UI")
    func refusedSelectionDoesNotOpenTheMenu() async {
        let surface = PerTrackSurfaceFake()
        surface.selectRefusal = "subject_selection_not_exclusive"

        let outcome = await driveWithScope(
            surface, scope: .perTrack, subject: .init(index: 0, name: "Studio Grand")
        )

        #expect(outcome == .refused("subject_selection_not_exclusive"))
        #expect(!surface.events.contains("file_open"))
        #expect(!surface.events.contains("export_press"))
    }

    @Test("an unreadable pre-run selection refuses before selecting anything")
    func unreadableSelectionRefuses() async {
        let surface = PerTrackSurfaceFake()
        surface.selection = nil

        let outcome = await driveWithScope(
            surface, scope: .perTrack, subject: .init(index: 0, name: "Studio Grand")
        )

        #expect(outcome == .refused("subject_selection_unreadable"))
        #expect(!surface.events.contains("file_open"))
    }

    @Test("a restore that cannot be proven is reported on the outcome, not dropped")
    func unprovenRestoreIsReported() async {
        let surface = PerTrackSurfaceFake()
        surface.restoreIsProven = false

        let outcome = await driveWithScope(
            surface, scope: .perTrack, subject: .init(index: 0, name: "Studio Grand")
        )

        #expect(outcome == .completedSelectionRestoreUnproven("selection_restore_unproven"))
    }

    @Test("an all-tracks drive keeps no selection custody at all")
    func allTracksKeepsNoCustody() async {
        let surface = PerTrackSurfaceFake()

        let outcome = await driveWithScope(surface, scope: .allTracks, subject: nil)

        #expect(outcome == .completed)
        #expect(!surface.events.contains("capture_selection"))
        #expect(!surface.events.contains { $0.hasPrefix("restore_selection") })
        #expect(!surface.events.contains("selection_matches"))
    }
}

// MARK: - Planner / executor

private func perTrackSubjects(for project: URL) -> ProjectExportStemSubjectInventory {
    .scanned(
        projectPath: project.path,
        subjects: [
            ProjectExportStemSubject(index: 0, name: "Vox Lead"),
            ProjectExportStemSubject(index: 1, name: "Kick"),
        ]
    )
}

private func stemPlan(
    project: URL,
    outputRoot: URL,
    extra: [String: Value] = [:]
) throws -> ProjectExportPlan {
    var params: [String: Value] = [
        "project": .string(project.path),
        "output_root": .string(outputRoot.path),
        "artifact": .string("stem"),
    ]
    params.merge(extra) { _, new in new }
    return try ProjectExportPlanner.plan(params: params, stemSubjects: perTrackSubjects(for: project))
}

@Suite("mix-master T1 stem_scope contract and per-track binding")
struct StemPerTrackExportTests {
    @Test("a per_track plan says it promises N selection-bound exports, not a file list")
    func planEchoesScope() throws {
        let project = try makeLogicxProject(in: try makeExecTempDir(), named: "Scope")
        let outputRoot = try makeExecTempDir()

        let plan = try stemPlan(project: project, outputRoot: outputRoot,
                                extra: ["stem_scope": .string("per_track")])
        let artifact = try #require(plan.projects.first?.expectedArtifacts.first)

        #expect(artifact.stemScope == .perTrack)
        #expect(artifact.analysis["stem_scope"] == "per_track")
        let echo = try #require(artifact.analysis["stem_scope_plan"])
        #expect(echo.contains("2 export(s), one per subject"))
    }

    @Test("all_tracks stays the default, and its plan says the binding is not established")
    func defaultScopeIsAllTracks() throws {
        let project = try makeLogicxProject(in: try makeExecTempDir(), named: "Default Scope")
        let outputRoot = try makeExecTempDir()

        let plan = try stemPlan(project: project, outputRoot: outputRoot)
        let artifact = try #require(plan.projects.first?.expectedArtifacts.first)

        #expect(artifact.stemScope == .allTracks)
        #expect(artifact.analysis["stem_scope"] == "all_tracks")
        #expect(artifact.analysis["stem_scope_plan"]?.contains("not established") == true)
    }

    @Test("stem_scope without a stem artifact and an unknown value are both refused")
    func scopeValidation() throws {
        let project = try makeLogicxProject(in: try makeExecTempDir(), named: "Bad Scope")
        let outputRoot = try makeExecTempDir()

        func refusal(artifact: String, scope: String) -> String? {
            do {
                _ = try ProjectExportPlanner.plan(params: [
                    "project": .string(project.path),
                    "output_root": .string(outputRoot.path),
                    "artifact": .string(artifact),
                    "stem_scope": .string(scope),
                ], stemSubjects: perTrackSubjects(for: project))
                return nil
            } catch {
                return String(describing: error)
            }
        }

        #expect(refusal(artifact: "bounce", scope: "per_track")?.contains("stem_scope_requires_a_stem_artifact") == true)
        #expect(refusal(artifact: "stem", scope: "sideways")?.contains("must be all_tracks or per_track") == true)
    }

    @Test("all_tracks keeps today's State B reason for every subject")
    func allTracksReasonIsUnchanged() async throws {
        let project = try makeLogicxProject(in: try makeExecTempDir(), named: "Batch")
        let outputRoot = try makeExecTempDir()
        var options = fastOptions(identity: { project.path })
        options.driveStemExport = { destination, _, _ in
            _ = try? writeToneWav(at: URL(fileURLWithPath: destination).appendingPathComponent("batch-1.wav"))
            _ = try? writeToneWav(at: URL(fileURLWithPath: destination).appendingPathComponent("batch-2.wav"))
            return .completed
        }

        let run = await ProjectExportExecutor.run(
            params: [
                "project": .string(project.path),
                "output_root": .string(outputRoot.path),
                "artifact": .string("stem"),
                "confirmed": .bool(true),
            ],
            router: await makeExportRouter(),
            resume: false,
            options: options,
            stemSubjects: perTrackSubjects(for: project)
        )

        let artifacts = try #require(run.projects.first?.artifacts)
        #expect(artifacts.count == 2)
        #expect(artifacts.allSatisfy { $0.state == "B" })
        #expect(artifacts.allSatisfy {
            ($0.reason ?? "").contains("stem_subject_file_binding_unestablished")
        })
    }

    @Test("per_track gives each subject its own State A artifact bound to the file it produced")
    func perTrackBindsEachFileToItsSubject() async throws {
        let project = try makeLogicxProject(in: try makeExecTempDir(), named: "Per Track")
        let outputRoot = try makeExecTempDir()
        var options = fastOptions(identity: { project.path })
        options.driveStemExport = { destination, scope, subject in
            guard scope == .perTrack, let subject else { return .refused("unexpected_scope") }
            let name = subject.name.replacingOccurrences(of: " ", with: "_")
            _ = try? writeToneWav(at: URL(fileURLWithPath: destination).appendingPathComponent("\(name).wav"))
            return .completed
        }

        let run = await ProjectExportExecutor.run(
            params: [
                "project": .string(project.path),
                "output_root": .string(outputRoot.path),
                "artifact": .string("stem"),
                "stem_scope": .string("per_track"),
                "confirmed": .bool(true),
            ],
            router: await makeExportRouter(),
            resume: false,
            options: options,
            stemSubjects: perTrackSubjects(for: project)
        )

        let artifacts = try #require(run.projects.first?.artifacts)
        #expect(artifacts.count == 2)
        #expect(artifacts.allSatisfy { $0.state == "A" && $0.verified && $0.bounceFired })
        #expect(artifacts.map(\.subject?.name) == ["Vox Lead", "Kick"])
        #expect(artifacts[0].path.hasSuffix("Vox_Lead.wav"))
        #expect(artifacts[1].path.hasSuffix("Kick.wav"))
        #expect(Set(artifacts.map(\.path)).count == 2)
        #expect(run.status == "completed")
    }

    @Test("a subject whose window produces no file is State B, and the next subject still runs")
    func zeroFileWindowDoesNotAbortTheRun() async throws {
        let project = try makeLogicxProject(in: try makeExecTempDir(), named: "Zero File")
        let outputRoot = try makeExecTempDir()
        var options = fastOptions(identity: { project.path })
        options.driveStemExport = { destination, _, subject in
            // The first subject's own window produces nothing; the second one does.
            if subject?.index == 1 {
                _ = try? writeToneWav(at: URL(fileURLWithPath: destination).appendingPathComponent("only-second.wav"))
            }
            return .completed
        }

        let run = await ProjectExportExecutor.run(
            params: [
                "project": .string(project.path),
                "output_root": .string(outputRoot.path),
                "artifact": .string("stem"),
                "stem_scope": .string("per_track"),
                "confirmed": .bool(true),
            ],
            router: await makeExportRouter(),
            resume: false,
            options: options,
            stemSubjects: perTrackSubjects(for: project)
        )

        let artifacts = try #require(run.projects.first?.artifacts)
        #expect(artifacts.count == 2)
        #expect(artifacts[0].state == "B")
        #expect((artifacts[0].reason ?? "").contains("per_track_export_observed_n_files: observed=0 expected=1"))
        #expect(artifacts[1].state == "A", "the following subject still runs")
    }

    @Test("two new files in one window are not attributed to the subject")
    func twoFileWindowIsNotAttributed() async throws {
        let project = try makeLogicxProject(in: try makeExecTempDir(), named: "Two Files")
        let outputRoot = try makeExecTempDir()
        var options = fastOptions(identity: { project.path })
        options.driveStemExport = { destination, _, subject in
            if subject?.index == 0 {
                _ = try? writeToneWav(at: URL(fileURLWithPath: destination).appendingPathComponent("a.wav"))
                _ = try? writeToneWav(at: URL(fileURLWithPath: destination).appendingPathComponent("b.wav"))
            }
            return .completed
        }

        let run = await ProjectExportExecutor.run(
            params: [
                "project": .string(project.path),
                "output_root": .string(outputRoot.path),
                "artifact": .string("stem"),
                "stem_scope": .string("per_track"),
                "confirmed": .bool(true),
            ],
            router: await makeExportRouter(),
            resume: false,
            options: options,
            stemSubjects: perTrackSubjects(for: project)
        )

        let artifacts = try #require(run.projects.first?.artifacts)
        #expect(artifacts[0].state == "B")
        #expect((artifacts[0].reason ?? "").contains("per_track_export_observed_n_files: observed=2 expected=1"))
    }

    @Test("an unproven selection restore is a warning on every artifact, not a downgrade")
    func unprovenRestoreCarriesWarnings() async throws {
        let project = try makeLogicxProject(in: try makeExecTempDir(), named: "Restore Warning")
        let outputRoot = try makeExecTempDir()
        var options = fastOptions(identity: { project.path })
        options.driveStemExport = { destination, _, subject in
            let name = subject?.name.replacingOccurrences(of: " ", with: "_") ?? "x"
            _ = try? writeToneWav(at: URL(fileURLWithPath: destination).appendingPathComponent("\(name).wav"))
            return .completedSelectionRestoreUnproven("selection_restore_unavailable_for_multi_selection")
        }

        let run = await ProjectExportExecutor.run(
            params: [
                "project": .string(project.path),
                "output_root": .string(outputRoot.path),
                "artifact": .string("stem"),
                "stem_scope": .string("per_track"),
                "confirmed": .bool(true),
            ],
            router: await makeExportRouter(),
            resume: false,
            options: options,
            stemSubjects: perTrackSubjects(for: project)
        )

        let artifacts = try #require(run.projects.first?.artifacts)
        #expect(artifacts.allSatisfy { $0.state == "A" })
        #expect(artifacts.allSatisfy { artifact in
            artifact.warnings?.contains {
                $0.contains("selection_restore_unproven: selection_restore_unavailable_for_multi_selection")
            } == true
        })
    }

    @Test("per_track keeps the fail_if_exists refusal for a non-empty destination")
    func perTrackDoesNotWeakenFailIfExists() async throws {
        let project = try makeLogicxProject(in: try makeExecTempDir(), named: "Non Empty")
        let outputRoot = try makeExecTempDir()
        _ = try writeToneWav(at: outputRoot.appendingPathComponent("already-there.wav"))
        let panelReached = BoolFlag()
        var options = fastOptions(identity: { project.path })
        options.driveStemExport = { _, _, _ in
            panelReached.set()
            return .completed
        }

        let run = await ProjectExportExecutor.run(
            params: [
                "project": .string(project.path),
                "output_root": .string(outputRoot.path),
                "artifact": .string("stem"),
                "stem_scope": .string("per_track"),
                "confirmed": .bool(true),
            ],
            router: await makeExportRouter(),
            resume: false,
            options: options,
            stemSubjects: perTrackSubjects(for: project)
        )

        let artifacts = try #require(run.projects.first?.artifacts)
        #expect(!panelReached.isSet)
        #expect(artifacts.allSatisfy { $0.state == "C" && !$0.writeAttempted })
        // Either the plan-time or the immediately-pre-export refusal, whichever the run
        // reaches first: both keep fail_if_exists intact for the per-track route.
        #expect(artifacts.allSatisfy { ($0.error ?? "").contains("fail_if_exists") })
    }
}
