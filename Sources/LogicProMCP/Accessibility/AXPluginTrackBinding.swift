import ApplicationServices
import Foundation

/// Plugin operations address Arrange tracks; Mixer ordinals are observations, never identity.
enum AXPluginTrackBinding {
    struct Binding: @unchecked Sendable {
        /// The Arrange track this strip belongs to. `nil` for the master Stereo Output strip,
        /// which has no Arrange header — a synthesized `0` there would name track 0 instead.
        let trackIndex: Int?
        let trackName: String
        let mixerStripIndex: Int
        /// The Arrange header the binding was joined through. `nil` for the master strip, whose
        /// only identity is its Mixer strip.
        let header: AXUIElement?
        /// The acquired Mixer surface. A floating and embedded Mixer can expose different AX
        /// elements for the same track; global rediscovery must not switch between them mid-write.
        let mixer: AXUIElement
        let strip: AXUIElement
    }

    static func resolve(
        track: Int, mixer: AXUIElement, runtime: AXLogicProElements.Runtime,
        onRefusal: ((String) -> Void)? = nil,
        onRefusalHeaderIndex: ((Int) -> Void)? = nil
    ) -> Binding? {
        guard track >= 0 else { onRefusal?("invalid_track_index"); return nil }
        let windowRead = AXLogicProElements.arrangeWindowVerifiedRead(runtime: runtime)
        guard case .found(let window) = windowRead else {
            if case .unreadable(let stage, let status) = windowRead {
                onRefusal?("arrange_window_unavailable/\(stage)/\(status)")
            } else { onRefusal?("arrange_window_unavailable") }
            return nil
        }
        let headerRead = AXLogicProElements.allTrackHeadersVerifiedRead(in: window, runtime: runtime)
        guard case .read(let headers) = headerRead else {
            if case .unreadable(let stage, let status) = headerRead {
                onRefusal?("arrange_headers_unavailable/\(stage)/\(status)")
            } else { onRefusal?("arrange_headers_unavailable") }
            return nil
        }
        guard track < headers.count else { onRefusal?("track_index_absent"); return nil }

        var headerNames: [String] = []
        for (headerIndex, header) in headers.enumerated() {
            let nameRead = AXValueExtractors.extractTrackNameResult(
                from: header, runtime: runtime.ax
            )
            guard case .success(.some(let name)) = nameRead else {
                onRefusalHeaderIndex?(headerIndex)
                if case .failure(let error) = nameRead {
                    onRefusal?("arrange_name_unavailable/\(error.diagnosticLabel)")
                } else { onRefusal?("arrange_name_unavailable") }
                return nil
            }
            headerNames.append(name)
        }
        let name = headerNames[track]
        guard headerNames.filter({ $0.utf8.elementsEqual(name.utf8) }).count == 1 else {
            onRefusalHeaderIndex?(track)
            onRefusal?("arrange_name_ambiguous"); return nil
        }

        // Reuse the existing noting seam so legacy role reads in stripEnumeration cannot turn
        // an AX failure into an absent sibling and thereby hide a duplicate target name.
        let failures = AXPluginInstanceIdentity.FailedReads()
        let ax = AXPluginInstanceIdentity.noting(failures, over: runtime.ax)
        guard let enumeration = AXLogicProElements.stripEnumeration(in: mixer, runtime: ax),
              enumeration.unreadableChildren == 0, !failures.any else {
            onRefusal?("mixer_strips_unavailable"); return nil
        }
        var matching: [(Int, AXUIElement)] = []
        for (index, strip) in enumeration.strips.enumerated() {
            let nameRead = AXPluginInstanceIdentity.stripNameResult(
                strip, runtime: runtime.ax
            )
            guard case .success(.some(let stripName)) = nameRead else {
                if case .failure(let error) = nameRead {
                    onRefusal?("strip_name_unavailable/\(error.diagnosticLabel)")
                } else { onRefusal?("strip_name_unavailable") }
                return nil
            }
            if stripName.utf8.elementsEqual(name.utf8) { matching.append((index, strip)) }
        }
        guard matching.count == 1 else { onRefusal?("strip_name_not_unique"); return nil }
        return Binding(trackIndex: track, trackName: name, mixerStripIndex: matching[0].0,
                       header: headers[track], mixer: mixer, strip: matching[0].1)
    }

    /// The master Stereo Output strip, identified only by what the Mixer exposes.
    ///
    /// There is no Arrange header to join through, so the identity question is answered by the
    /// strip itself: exactly one Mixer strip must carry the measured default name AND expose a
    /// readable, non-empty insert section. The insert-section requirement is not decoration — it
    /// is what separates `Stereo Out` from the `Master` strip beside it, which has no insert row at
    /// all (docs/tickets/issue-234/axdump234b.out, 2026-07-04).
    ///
    /// A user-renamed output strip, a locale whose default name this build has not measured, or a
    /// second strip with the same name all refuse. None of them may become "the last strip in the
    /// list": a mastering chain applied to the wrong strip is worse than no chain.
    static func resolveOutputStrip(
        mixer: AXUIElement,
        runtime: AXLogicProElements.Runtime,
        onRefusal: ((String) -> Void)? = nil
    ) -> Binding? {
        // Reuse the existing noting seam so legacy role reads in stripEnumeration cannot turn
        // an AX failure into an absent sibling and thereby hide a duplicate target name.
        let failures = AXPluginInstanceIdentity.FailedReads()
        let ax = AXPluginInstanceIdentity.noting(failures, over: runtime.ax)
        guard let enumeration = AXLogicProElements.stripEnumeration(in: mixer, runtime: ax),
              enumeration.unreadableChildren == 0, !failures.any else {
            onRefusal?("mixer_strips_unavailable"); return nil
        }
        var matching: [(Int, AXUIElement, String)] = []
        for (index, strip) in enumeration.strips.enumerated() {
            let nameRead = AXPluginInstanceIdentity.stripNameResult(strip, runtime: runtime.ax)
            guard case .success(.some(let stripName)) = nameRead else {
                if case .failure(let error) = nameRead {
                    onRefusal?("strip_name_unavailable/\(error.diagnosticLabel)")
                } else { onRefusal?("strip_name_unavailable") }
                return nil
            }
            if AXLocalePolicy.stereoOutStripName.matches(stripName, mode: .exact) {
                matching.append((index, strip, stripName))
            }
        }
        guard matching.count == 1 else {
            onRefusal?(matching.isEmpty ? "output_strip_absent" : "output_strip_name_not_unique")
            return nil
        }
        let (stripIndex, strip, stripName) = matching[0]
        // Structural corroboration: the strip must expose an enumerable, non-empty insert section.
        // A zero-slot reading here is the same `insert_section_not_enumerable` condition the
        // inventory reports, and it is never evidence that the strip has no inserts.
        guard case .success(let children) = AXHelpers.childrenResult(strip, runtime: runtime.ax) else {
            onRefusal?("output_strip_children_unreadable"); return nil
        }
        let slots = AXLogicProElements.audioPluginInsertSlots(children: children, runtime: runtime.ax)
        guard !slots.isEmpty, !slots.contains(where: { $0.readStatus == .unclassified }) else {
            onRefusal?("output_strip_insert_section_unavailable"); return nil
        }
        return Binding(trackIndex: nil, trackName: stripName, mixerStripIndex: stripIndex,
                       header: nil, mixer: mixer, strip: strip)
    }

    /// The acquired Mixer's owning window, not whichever Mixer a global search currently finds.
    /// Only structural AXWindow absence permits the bounded parent fallback; unread ownership
    /// never becomes permission to raise a different window. The owner must still be in AXWindows.
    static func owningWindow(_ binding: Binding, runtime: AXLogicProElements.Runtime) -> AXUIElement? {
        func liveWindow(_ candidate: AXUIElement) -> AXUIElement? {
            guard case .success(.some(let role)) = AXHelpers.getAttributeResult(
                candidate, kAXRoleAttribute as String, runtime: runtime.ax
            ) as Result<String?, AXHelpers.AXStatusError>, role == kAXWindowRole as String,
                  let app = AXLogicProElements.appRoot(runtime: runtime),
                  case .success(.elements(let windows)) = AXHelpers.getAXUIElementArrayRead(
                    app, kAXWindowsAttribute as String, runtime: runtime.ax
                  ),
                  windows.allSatisfy({ CFGetTypeID($0) == AXUIElementGetTypeID() }),
                  windows.contains(where: { CFEqual($0, candidate) }) else { return nil }
            return candidate
        }

        switch AXHelpers.getAttributeResult(binding.mixer, kAXWindowAttribute as String, runtime: runtime.ax)
            as Result<AnyObject?, AXHelpers.AXStatusError> {
        case .success(.some(let value)):
            guard CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
            return liveWindow(unsafeDowncast(value, to: AXUIElement.self))
        case .success(.none): break
        case .failure(let error) where error.isDefinitiveAbsence: break
        case .failure: return nil
        }

        var child = binding.mixer
        var visited = [child]
        for _ in 0..<16 {
            guard case .success(.some(let parent)) = AXHelpers.getAttributeResult(
                child, kAXParentAttribute as String, runtime: runtime.ax
            ) as Result<AXUIElement?, AXHelpers.AXStatusError>,
                  !visited.contains(where: { CFEqual($0, parent) }),
                  case .success(.some(let role)) = AXHelpers.getAttributeResult(
                    parent, kAXRoleAttribute as String, runtime: runtime.ax
                  ) as Result<String?, AXHelpers.AXStatusError>, !role.isEmpty else { return nil }
            if role == kAXWindowRole as String { return liveWindow(parent) }
            visited.append(parent)
            child = parent
        }
        return nil
    }

    /// Re-resolve uniquely at use time. The same strip may move, but a replacement at the old
    /// ordinal (even with the same name) is not the acquired target.
    static func isStable(_ original: Binding, runtime: AXLogicProElements.Runtime) -> Bool {
        let fresh: Binding?
        switch original.trackIndex {
        case let track?:
            fresh = resolve(track: track, mixer: original.mixer, runtime: runtime)
        case nil:
            fresh = resolveOutputStrip(mixer: original.mixer, runtime: runtime)
        }
        guard let fresh,
              fresh.trackName.utf8.elementsEqual(original.trackName.utf8),
              CFEqual(fresh.strip, original.strip) else { return false }
        // The header is compared only when BOTH sides have one: a binding that gained or lost its
        // Arrange header is not the target the write was authorized against.
        switch (original.header, fresh.header) {
        case let (originalHeader?, freshHeader?): return CFEqual(freshHeader, originalHeader)
        case (nil, nil): return true
        default: return false
        }
    }

    /// Allow transient AX observations after selection to settle, never reacquiring a different
    /// target or Mixer. Every successful poll must still match the original name and CF identities.
    static func waitUntilStable(
        _ original: Binding, runtime: AXLogicProElements.Runtime,
        timeoutMs: Int = 1_200, intervalMs: Int = 100
    ) async -> Bool {
        guard timeoutMs > 0, intervalMs > 0 else { return false }
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .milliseconds(timeoutMs))
        while !Task.isCancelled, clock.now < deadline {
            if isStable(original, runtime: runtime) { return !Task.isCancelled }
            let remaining = clock.now.duration(to: deadline)
            guard remaining > .zero else { return false }
            do {
                try await Task.sleep(for: min(remaining, .milliseconds(intervalMs)))
            } catch {
                return false
            }
        }
        return false
    }
}
