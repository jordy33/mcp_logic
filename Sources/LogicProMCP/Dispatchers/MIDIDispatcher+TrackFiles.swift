import Foundation
import MCP

extension MIDIDispatcher {
    static func handleTrackFileCommand(command: String, params: [String: Value],
        export: (@Sendable (String, String, String?) async throws -> MIDITrackFileExport.Result)?) async -> CallTool.Result {
        let allowed: Set<String> = command == "export_track_midi" ? ["project_ref", "target_ref", "path"] : ["project_ref", "target_ref"]
        guard Set(params.keys).isSubset(of: allowed),
              let project = params["project_ref"]?.stringValue, validMIDIReference(project, prefix: "prj_"),
              let track = params["target_ref"]?.stringValue, validMIDIReference(track, prefix: "trk_") else {
            return toolInvalidParamsResult("\(command) requires explicit project_ref and track target_ref UUID references; selection, indices, port and unknown parameters are not supported")
        }
        let path: String?
        if command == "export_track_midi" {
            guard let value = params["path"]?.stringValue, value.hasPrefix("/"), !value.contains("\0"),
                  URL(fileURLWithPath: value).pathExtension.lowercased() == "mid" else {
                return toolInvalidParamsResult("export_track_midi requires an absolute new .mid path")
            }
            path = value
        } else { path = nil }
        let traceID = await startTraceIfEnabled(command: command)
        guard let export else {
            return await finalizeTrace(midiFilePayload(["error": "native_export_unavailable", "success": false,
                "verified": false, "state": "C", "operation": "midi.\(command)",
                "hint": "This command requires the registered request-owned native export provider."], isError: true), traceID: traceID)
        }
        let result: CallTool.Result
        do {
            let exported = try await export(project, track, path)
            let document = exported.document
            var payload: [String: Any] = [
                "success": true, "state": "A", "operation": "midi.\(command)",
                "verified": true, "project_ref": project, "target_ref": track,
                "provider": "native_whole_project_smf_export",
                "verification_scope": "export_artifact_and_track_binding",
                "timing_origin": "smf_tick_zero", "project_timeline_mapping": "unproven",
                "import_comparison": "not_performed", "ppq": document.ticksPerQuarter,
                "smf_format": document.format, "smf_track_count": document.trackCount,
                "empty": document.notes.isEmpty,
                "notes": document.notes.map { ["pitch": Int($0.pitch), "velocity": Int($0.velocity),
                    "channel": $0.channel, "start_tick": $0.startTick,
                    "end_tick": $0.endTick, "duration_ticks": $0.durationTicks] },
                "tempo_changes": document.tempoChanges.map { ["tick": $0.tick, "microseconds_per_quarter": $0.microsecondsPerQuarter] },
                "time_signatures": document.timeSignatures.map { ["tick": $0.tick, "numerator": $0.signature.numerator, "denominator": $0.signature.denominator] },
                "ui_effects": ["export_panel": "closed", "selection_cycle": "not_changed_by_provider", "last_export_folder": "not_restored"],
            ]
            if let path { payload["path"] = path }
            result = midiFilePayload(payload)
        } catch {
            let code: String
            switch error {
            case MIDITrackFileExport.Failure.invalidDestination: code = "invalid_destination"
            case MIDITrackFileExport.Failure.destinationExists: code = "destination_exists"
            case MIDITrackFileExport.Failure.unboundProject: code = "unbound_project"
            case MIDITrackFileExport.Failure.incompleteTrackPopulation: code = "incomplete_track_population"
            case MIDITrackFileExport.Failure.ambiguousTarget: code = "ambiguous_target"
            case MIDITrackFileExport.Failure.staleTarget: code = "stale_target"
            case MIDITrackFileExport.Failure.exportCancelled, is CancellationError: code = "cancelled"
            case MIDITrackFileExport.Failure.unreadableArtifact, is SMFReaderError: code = "unreadable_midi_artifact"
            case SMFReader.TrackExtractionError.instrumentNotFound: code = "track_midi_not_exported"
            case SMFReader.TrackExtractionError.unsupportedFileLayout: code = "unsupported_midi_export_layout"
            case is MIDITrackExportPanel.Failure: code = "native_export_unverified"
            default: code = "midi_export_failed"
            }
            result = midiFilePayload(["error": code, "verified": false, "success": false,
                "state": "C", "operation": "midi.\(command)",
                "hint": "No completed export or note observation is reported. Inspect the explicit destination before retrying after a file-write failure; native UI cleanup may be unconfirmed.",
                "detail": String(describing: error), "ui_effects": ["restoration": "unconfirmed"]], isError: true)
        }
        return await finalizeTrace(result, traceID: traceID)
    }

    private static func validMIDIReference(_ value: String, prefix: String) -> Bool {
        guard value.hasPrefix(prefix), value.count == prefix.count + 36 else { return false }
        return UUID(uuidString: String(value.dropFirst(prefix.count))) != nil
    }

    private static func midiFilePayload(_ payload: [String: Any], isError: Bool = false) -> CallTool.Result {
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]) else {
            return .init(content: [.text(text: "{\"error\":\"midi_result_encoding_failed\"}", annotations: nil, _meta: nil)], isError: true)
        }
        return .init(content: [.text(text: String(decoding: data, as: UTF8.self), annotations: nil, _meta: nil)], isError: isError)
    }
}
