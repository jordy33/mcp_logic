@preconcurrency import ApplicationServices
import Foundation

extension AccessibilityChannel {
    /// Explicit held-rail selections, not a name/ordinal join or a global census.
    /// A held passive focus plus this Mixer's actual selected-child relationship
    /// can also start an explicitly owned, exposed-header observation.
    final class HeldSelectionAssociation: @unchecked Sendable {
        struct Pair: @unchecked Sendable {
            let track: AXTrackBinding.Binding
            let strip: AXMixerStripBinding.Binding
            var source = "held_exclusive_selection_focus"
        }
        typealias ViewportControl = (element: AXUIElement, value: Double, zoomDescription: String?)
        let logic: AXLogicProElements.Runtime
        let app: AXUIElement
        let pid: pid_t
        let window: AXUIElement
        let document: String
        let title: String
        let rail: AXUIElement
        let railPath: [AXUIElement]
        let headers: [AXUIElement]
        let mixer: AXUIElement
        let strips: [AXUIElement]
        let path: [AXUIElement]
        let originalIndex: Int
        let originalFocus: AXUIElement
        let transport: AXLogicProElements.ObservedTransportActivity
        let transportPaths: [[AXUIElement]]
        let viewport: [ViewportControl]
        let viewportPaths: [[AXUIElement]]
        private var expectedViewport: [ViewportControl]
        private var expectedIndex: Int
        private var expectedFocus: AXUIElement
        private var originalSelectedChild: AXUIElement?
        private var expectedSelectedChild: AXUIElement?
        private let originalRailFocus: AXUIElement?
        private let originalHeaderFocus: OwnedTrackStackObservationNavigation.ReadFocusScope.PassiveHeaderReadFocus?
        private let retainedTrackBindings: [AXTrackBinding.Binding]?
        private var lost = false
        private(set) var effects = SessionPopulationObservation.UIEffects()

        init?(window: AXUIElement, logic: AXLogicProElements.Runtime,
              expectedProject: TargetDescriptor?, requiresProjectReference: Bool,
              allowsSelectedChildRailEntry: Bool = false,
              retainedHeaderFocus: OwnedTrackStackObservationNavigation.ReadFocusScope.PassiveHeaderReadFocus? = nil,
              retainedTrackBindings: [AXTrackBinding.Binding]? = nil,
              restorationBaseline: HeldSelectionAssociation? = nil) {
            // The existing foreground AX probe requires this CLI process's
            // window-server connection; a missing/foreign PID still refuses.
            _ = logic.onScreenWindowList()
            guard (try? SessionPopulationObservation.requireOwnedAcquisition()) != nil,
                  let pid = logic.logicProPID(), let app = AXLogicProElements.appRoot(runtime: logic),
                  let title = AXHelpers.getTitle(window, runtime: logic.ax),
                  case .success(.some(let document)) = AXLogicProElements.projectPickerDocumentRead(window, runtime: logic),
                  let url = URL(string: document), url.isFileURL,
                  url.host == nil || url.host == "" || url.host == "localhost",
                  !requiresProjectReference || (
                    expectedProject?.projectName?.utf8.elementsEqual(AccessibilityChannel.projectName(fromWindowTitle: title).utf8) == true
                    && expectedProject?.projectFilePath?.utf8.elementsEqual(url.path.utf8) == true),
                  let rail = AXLogicProElements.uniqueTrackHeaderRail(in: window, runtime: logic),
                  let railPath = Self.path(rail, to: window, ax: logic.ax),
                  case .read(let headers) = AXLogicProElements.allTrackHeadersVerifiedRead(in: window, runtime: logic),
                  headers.count > 1,
                  retainedTrackBindings.map({ bindings in
                      bindings.count == headers.count && zip(bindings, headers).allSatisfy { binding, header in
                          CFEqual(binding.window, window) && CFEqual(binding.header, header)
                              && binding.document.utf8.elementsEqual(document.utf8)
                              && (binding.exposure?.isCurrent ?? true)
                      }
                  }) ?? true,
                  let selected = Self.exclusiveIndex(headers, ax: logic.ax),
                  let focus: AXUIElement = AXHelpers.getAttribute(app, kAXFocusedUIElementAttribute as String, runtime: logic.ax),
                  retainedHeaderFocus.map({ CFEqual($0.focus, focus) && CFEqual($0.window, window)
                      && CFEqual($0.rail, rail) && CFEqual($0.header, headers[selected]) && $0.permits() }) ?? true,
                  let mixer = Self.entryMixer(focus: focus, window: window, railPath: railPath,
                    logic: logic, allowsSelectedChildRailEntry: allowsSelectedChildRailEntry,
                    retainedHeaderFocus: retainedHeaderFocus),
                  let enumeration = AXLogicProElements.mixerChannelStripsIfCompletelyRead(in: mixer, runtime: logic.ax),
                  enumeration.strips.filter({ CFEqual($0, focus) }).count == 1
                    || (allowsSelectedChildRailEntry && (railPath.contains { CFEqual($0, focus) }
                        || retainedHeaderFocus != nil)),
                  let path = Self.path(mixer, to: window, ax: logic.ax),
                  let viewport = Self.viewport(window, ax: logic.ax),
                  let viewportPaths = Self.viewportPaths(viewport, window: window, ax: logic.ax),
                  let activity = try? AXLogicProElements.observedTransportActivity(in: window, runtime: logic,
                    checking: { try SessionPopulationObservation.requireOwnedAcquisition() }),
                  !activity.isPlaying, !activity.isRecording,
                  let playPath = Self.path(activity.play, to: window, ax: logic.ax),
                  let recordPath = Self.path(activity.record, to: window, ax: logic.ax),
                  playPath.contains(where: { CFEqual($0, activity.controlBar) }),
                  recordPath.contains(where: { CFEqual($0, activity.controlBar) }) else { return nil }
            self.logic = logic; self.app = app; self.pid = pid; self.window = window
            self.title = title; self.document = document; self.rail = rail; self.railPath = railPath; self.headers = headers
            self.mixer = mixer; strips = enumeration.strips; self.path = path
            originalIndex = selected; originalFocus = restorationBaseline?.originalFocus ?? focus
            expectedIndex = selected; expectedFocus = focus
            originalRailFocus = enumeration.strips.contains { CFEqual($0, focus) } ? nil : focus
            originalHeaderFocus = retainedHeaderFocus
            self.retainedTrackBindings = retainedTrackBindings
            transport = activity; self.viewport = viewport
            self.viewportPaths = viewportPaths; expectedViewport = viewport
            transportPaths = [playPath, recordPath]
            if let baseline = restorationBaseline {
                // A verified caller-owned effect may end on another already
                // qualified passive focus. Keep the prior restoration duty,
                // never turn the new focus/viewport into the original baseline.
                guard !baseline.lost, baseline.expectedIndex == baseline.originalIndex,
                      baseline.originalIndex == selected, CFEqual(baseline.app, app), baseline.pid == pid,
                      CFEqual(baseline.window, window), baseline.document.utf8.elementsEqual(document.utf8),
                      baseline.title.utf8.elementsEqual(title.utf8), CFEqual(baseline.rail, rail),
                      CFEqual(baseline.mixer, mixer), Self.same(baseline.headers, headers), Self.same(baseline.strips, strips),
                      Self.same(baseline.railPath, railPath), Self.same(baseline.path, path),
                      Self.sameViewport(baseline.viewport, viewport),
                      Self.sameViewport(baseline.expectedViewport, viewport),
                      baseline.viewportPaths.count == viewportPaths.count,
                      zip(baseline.viewportPaths, viewportPaths).allSatisfy({ Self.same($0, $1) }),
                      baseline.transportPaths.count == transportPaths.count,
                      zip(baseline.transportPaths, transportPaths).allSatisfy({ Self.same($0, $1) }),
                      CFEqual(baseline.transport.play, activity.play), CFEqual(baseline.transport.record, activity.record),
                      baseline.transport.isPlaying == activity.isPlaying,
                      baseline.transport.isRecording == activity.isRecording else { return nil }
            }
            if originalRailFocus != nil {
                // A passive rail focus is never a fallback focus/strip pair.
                // This entry needs this exact Mixer's actual held relationship.
                guard case .observed(let child) = selectedChildRead() else { return nil }
                originalSelectedChild = child; expectedSelectedChild = child
            }
            guard permitsRead(), AXHelpers.isAttributeSettable(rail, kAXSelectedChildrenAttribute as String,
                runtime: logic.ax) == true else { return nil }
        }

        private static func entryMixer(focus: AXUIElement, window: AXUIElement,
                                       railPath: [AXUIElement], logic: AXLogicProElements.Runtime,
                                       allowsSelectedChildRailEntry: Bool,
                                       retainedHeaderFocus: OwnedTrackStackObservationNavigation.ReadFocusScope.PassiveHeaderReadFocus?) -> AXUIElement? {
            guard allowsSelectedChildRailEntry,
                  railPath.contains(where: { CFEqual($0, focus) }) || retainedHeaderFocus != nil else {
                // Preserve scalar/default acquisition exactly: the focus's
                // original physical parent supplies its Mixer candidate.
                return AXHelpers.getAttribute(focus, kAXParentAttribute as String, runtime: logic.ax)
            }
            guard case .found(let mixer) = (try? AXLogicProElements.mixerPopulationAreaLookup(
                in: window, runtime: logic, requiresCompleteAbsence: true,
                checking: { try SessionPopulationObservation.requireOwnedAcquisition() }))?.lookup else { return nil }
            return mixer
        }

        private static func exclusiveIndex(_ headers: [AXUIElement], ax: AXHelpers.Runtime) -> Int? {
            let values = headers.map { AXValueExtractors.extractSelectedState($0, runtime: ax) }
            guard values.allSatisfy({ $0 != nil }), values.filter({ $0 == true }).count == 1 else { return nil }
            return values.firstIndex(where: { $0 == true })
        }

        private static func same(_ lhs: [AXUIElement], _ rhs: [AXUIElement]) -> Bool {
            lhs.count == rhs.count && zip(lhs, rhs).allSatisfy { CFEqual($0, $1) }
        }

        static func path(_ mixer: AXUIElement, to window: AXUIElement, ax: AXHelpers.Runtime) -> [AXUIElement]? {
            var path = [mixer]
            // Preserve the status-bearing childrenResult seam of older runtimes.
            guard ax.attributeValuesResult != nil else {
                while !CFEqual(path.last!, window) {
                    guard (try? SessionPopulationObservation.requireOwnedAcquisition()) != nil,
                          path.count < 32,
                          let parent: AXUIElement = AXHelpers.getAttribute(path.last!, kAXParentAttribute as String, runtime: ax),
                          !path.contains(where: { CFEqual($0, parent) }),
                          case .success(let children) = AXHelpers.childrenResult(parent, runtime: ax),
                          children.filter({ CFEqual($0, path.last!) }).count == 1 else { return nil }
                    path.append(parent)
                }
                return path
            }
            if CFEqual(mixer, window) { return path }
            guard (try? SessionPopulationObservation.requireOwnedAcquisition()) != nil,
                  let firstParent: AXUIElement = AXHelpers.getAttribute(mixer, kAXParentAttribute as String, runtime: ax) else { return nil }
            var parent = firstParent
            while !CFEqual(path.last!, window) {
                guard (try? SessionPopulationObservation.requireOwnedAcquisition()) != nil,
                      path.count < 32,
                      !path.contains(where: { CFEqual($0, parent) }) else { return nil }
                let atWindow = CFEqual(parent, window)
                // Fresh reciprocal witnesses on this original parent, not a
                // cached path or a second hierarchy/name/ordinal lookup. Help
                // remains outside the batch and under its full per-read guard.
                let attributes = atWindow ? [kAXChildrenAttribute as String]
                    : [kAXChildrenAttribute as String, kAXParentAttribute as String]
                let readings = AXHelpers.getNonHelpAttributes(parent, attributes, runtime: ax,
                    permittingRead: { (try? SessionPopulationObservation.requireOwnedAcquisition()) != nil })
                guard case .success(.some(let rawChildren)) = readings[0],
                      CFGetTypeID(rawChildren) == CFArrayGetTypeID(),
                      AXHelpers.decodeChildrenArray(rawChildren).filter({ CFEqual($0, path.last!) }).count == 1 else { return nil }
                path.append(parent)
                if !atWindow {
                    guard case .success(.some(let rawParent)) = readings[1],
                          CFGetTypeID(rawParent) == AXUIElementGetTypeID() else { return nil }
                    parent = unsafeDowncast(rawParent, to: AXUIElement.self)
                }
            }
            return path
        }

        private static func viewport(_ window: AXUIElement, ax: AXHelpers.Runtime,
                                     held: [ViewportControl]? = nil) -> [ViewportControl]? {
            var sliders: [AXUIElement] = []
            guard case .success(let census) = AXHelpers.censusDescendantResult(of: window, role: kAXScrollBarRole as String,
                maxDepth: 32, runtime: ax, requiresCompleteTraversal: true, batchingRoleAndChildren: true,
                permittingRead: { (try? SessionPopulationObservation.requireOwnedAcquisition()) != nil },
                observingRole: { element, role in
                    if role == kAXSliderRole as String { sliders.append(element) }
                }) else { return nil }
            var controls: [(AXUIElement, String?)] = census.matches.map { ($0, nil) }
            let zoomLabels = AXLocalePolicy.horizontalZoomSlider.labels + AXLocalePolicy.verticalZoomSlider.labels
            // Discover own zoom controls before navigation. Inspector selection
            // may redraw unrelated sliders; their descriptions cannot revoke
            // custody of an original, reciprocally held viewport control.
            let zooms = held.map { $0.filter { $0.zoomDescription != nil }.map { ($0.element, $0.zoomDescription) } }
                ?? sliders.map { ($0, nil as String?) }
            for (slider, heldDescription) in zooms {
                guard (try? SessionPopulationObservation.requireOwnedAcquisition()) != nil else { return nil }
                if heldDescription != nil {
                    // A role contradiction sampled by this fresh census is
                    // irreversible; a later role read cannot erase it.
                    guard sliders.filter({ CFEqual($0, slider) }).count == 1,
                          AXHelpers.getRole(slider, runtime: ax) == kAXSliderRole as String else { return nil }
                }
                switch AXHelpers.getAttributeResult(slider, kAXDescriptionAttribute as String,
                    runtime: ax) as Result<AnyObject?, AXHelpers.AXStatusError> {
                case .success(.some(let rawDescription)):
                    guard CFGetTypeID(rawDescription) == CFStringGetTypeID(),
                          let description = rawDescription as? String else { return nil }
                    if let heldDescription {
                        guard description.utf8.elementsEqual(heldDescription.utf8) else { return nil }
                        controls.append((slider, heldDescription))
                    } else if zoomLabels.contains(description) { controls.append((slider, description)) }
                case .success(.none): if heldDescription != nil { return nil }
                case .failure(let error) where error.isDefinitiveAbsence: if heldDescription != nil { return nil }
                default: return nil
                }
            }
            var result: [ViewportControl] = []
            for (control, description) in controls {
                guard case .success(.some(let value)) = AXHelpers.getAttributeResult(control, kAXValueAttribute as String,
                    runtime: ax) as Result<NSNumber?, AXHelpers.AXStatusError>, value.doubleValue.isFinite else { return nil }
                result.append((control, value.doubleValue, description))
            }
            return result
        }

        private static func viewportPaths(_ viewport: [ViewportControl], window: AXUIElement,
                                          ax: AXHelpers.Runtime) -> [[AXUIElement]]? {
            var paths: [[AXUIElement]] = []
            for (control, _, _) in viewport {
                guard let path = Self.path(control, to: window, ax: ax) else { return nil }
                paths.append(path)
            }
            return paths
        }

        private static func sameViewport(_ lhs: [ViewportControl], _ rhs: [ViewportControl],
                                         includingValues: Bool = true) -> Bool {
            lhs.count == rhs.count && zip(lhs, rhs).allSatisfy {
                CFEqual($0.0, $1.0) && $0.2 == $1.2 && (!includingValues || $0.1 == $1.1)
            }
        }

        private func currentViewport() -> [ViewportControl]? {
            guard let current = Self.viewport(window, ax: logic.ax, held: viewport),
                  Self.sameViewport(current, viewport, includingValues: false),
                  let paths = Self.viewportPaths(current, window: window, ax: logic.ax),
                  paths.count == viewportPaths.count,
                  zip(paths, viewportPaths).allSatisfy({ Self.same($0, $1) }) else {
                lost = true; return nil
            }
            return current
        }

        private func currentWindowScopeMatches() -> Bool {
            guard logic.ax.attributeValuesResult != nil else {
                guard AXHelpers.getTitle(window, runtime: logic.ax)?.utf8.elementsEqual(title.utf8) == true,
                      case .success(.some(let currentDocument)) = AXLogicProElements.projectPickerDocumentRead(window, runtime: logic)
                else { return false }
                return document.utf8.elementsEqual(currentDocument.utf8)
            }
            // Fresh values from this exact held window, not an earlier scope
            // receipt. The separate final Document/PID/deadline bookend remains.
            let values = AXHelpers.getNonHelpAttributes(window,
                [kAXTitleAttribute, kAXDocumentAttribute] as [String], runtime: logic.ax,
                permittingRead: { (try? SessionPopulationObservation.requireOwnedAcquisition()) != nil })
            guard case .success(.some(let rawTitle)) = values[0], CFGetTypeID(rawTitle) == CFStringGetTypeID(),
                  let currentTitle = rawTitle as? String, currentTitle.utf8.elementsEqual(title.utf8),
                  case .success(.some(let rawDocument)) = values[1], CFGetTypeID(rawDocument) == CFStringGetTypeID(),
                  let currentDocument = rawDocument as? String else { return false }
            return document.utf8.elementsEqual(currentDocument.utf8)
        }

        private func owned(checkingAssociation: Bool = true, ownedPopup: AXUIElement? = nil,
                           checkingStoppedTransport: Bool = true,
                           nativeOutputSource: AXMixerStripBinding.Binding? = nil) -> Bool {
            func railMatches() -> Bool {
                guard checkingAssociation else { return true }
                guard let currentRailPath = Self.path(rail, to: window, ax: logic.ax), Self.same(railPath, currentRailPath),
                      case .success(let currentHeaders) = AXHelpers.childrenResult(rail, runtime: logic.ax) else { return false }
                return Self.same(headers, currentHeaders)
            }
            func stripCustodyMatches() -> Bool {
                if checkingAssociation || originalRailFocus != nil {
                    guard let current = AXLogicProElements.mixerChannelStripsIfCompletelyRead(in: mixer, runtime: logic.ax) else { return false }
                    return Self.same(strips, current.strips)
                }
                // A focus-moving read is not a rail-selection capability.
                // Renew this exact focus's reciprocal Mixer membership only;
                // never adopt another strip by name or position.
                guard case .success(let children) = AXHelpers.childrenResult(mixer, runtime: logic.ax),
                      children.filter({ CFEqual($0, expectedFocus) }).count == 1,
                      let parent: AXUIElement = AXHelpers.getAttribute(expectedFocus, kAXParentAttribute as String, runtime: logic.ax) else { return false }
                return CFEqual(parent, mixer)
            }
            guard !lost, (try? SessionPopulationObservation.requireOwnedAcquisition()) != nil,
                  retainedTrackBindings?.allSatisfy({ $0.exposure?.isCurrent ?? true }) ?? true,
                  logic.logicProPID() == pid, logic.focusedApplicationPID() == pid,
                  let currentApp = AXLogicProElements.appRoot(runtime: logic), CFEqual(app, currentApp) else {
                lost = true; return false
            }
            let application = AXHelpers.getNonHelpAttributes(app,
                [kAXFrontmostAttribute, kAXWindowsAttribute, kAXMainWindowAttribute, kAXFocusedWindowAttribute] as [String],
                runtime: logic.ax, permittingRead: { (try? SessionPopulationObservation.requireOwnedAcquisition()) != nil })
            guard case .success(.some(let frontmost)) = application[0], frontmost as? Bool == true,
                  case .success(.some(let windowValues)) = application[1], CFGetTypeID(windowValues) == CFArrayGetTypeID(),
                  case .success(.some(let mainValue)) = application[2], CFGetTypeID(mainValue) == AXUIElementGetTypeID() else {
                let states = application.map { reading -> String in
                    switch reading {
                    case .success(.some(let value)): return "type:\(CFGetTypeID(value))"
                    case .success(.none): return "absent"
                    case .failure(let error): return "AX:\(error.raw)"
                    }
                }.joined(separator: ",")
                Log.info("Held association ownership refused: application window attributes [\(states)]", subsystem: "ax")
                lost = true; return false
            }
            let windows = AXHelpers.decodeChildrenArray(windowValues)
            let main = unsafeDowncast(mainValue, to: AXUIElement.self)
            let focusedWindowMatches: Bool
            if AccessibilityChannel.routingFocusedWindowMatches(application[3],
                window: window, ownedPopup: ownedPopup, mixer: mixer, runtime: logic.ax) {
                focusedWindowMatches = true
            } else if case .failure(let error) = application[3], error.raw == AXError.noValue.rawValue,
                      let root = ownedPopup, let source = nativeOutputSource {
                // Like the ordinary menu's measured AXNoValue, this exact
                // response needs a fresh reciprocal native popup/source proof.
                // Missing, unreadable and foreign windows gain no exception.
                focusedWindowMatches = nativeOutputPopupMatches(root, source: source)
            } else {
                focusedWindowMatches = false
            }
            guard
                  windows.filter({ CFEqual($0, window) }).count == 1,
                  CFEqual(main, window), focusedWindowMatches,
                  currentWindowScopeMatches(), !AXLogicProElements.dialogPresent(runtime: logic) else {
                let focusedReading: String
                switch application[3] {
                case .failure(let error): focusedReading = "AX:\(error.raw)"
                case .success(.none): focusedReading = "absent"
                case .success(.some(let value)): focusedReading = "type:\(CFGetTypeID(value))"
                }
                Log.info("Held association ownership refused: window/dialog (main=\(CFEqual(main, window)), focused=\(focusedWindowMatches), reading=\(focusedReading))", subsystem: "ax")
                lost = true; return false
            }
            guard railMatches() else {
                Log.info("Held association ownership refused: original rail census", subsystem: "ax")
                lost = true; return false
            }
            guard let currentPath = Self.path(mixer, to: window, ax: logic.ax), Self.same(path, currentPath) else {
                Log.info("Held association ownership refused: original Mixer path", subsystem: "ax")
                lost = true; return false
            }
            guard stripCustodyMatches() else {
                Log.info("Held association ownership refused: original Mixer strip census", subsystem: "ax")
                lost = true; return false
            }
            guard !checkingStoppedTransport || stoppedTransportPathsMatch() else {
                Log.info("Held association ownership refused: original transport path/value", subsystem: "ax")
                lost = true; return false
            }
            guard case .success(.some(let finalDocument)) = AXLogicProElements.projectPickerDocumentRead(window, runtime: logic),
                  document.utf8.elementsEqual(finalDocument.utf8), logic.logicProPID() == pid,
                  (try? SessionPopulationObservation.requireOwnedAcquisition()) != nil else { lost = true; return false }
            return true
        }

        private func stoppedTransportPathsMatch() -> Bool {
            Self.stoppedTransportPathsMatch(transportPaths, activity: transport, window: window, logic: logic)
        }

        static func stoppedTransportPathsMatch(_ paths: [[AXUIElement]],
            activity: AXLogicProElements.ObservedTransportActivity, window: AXUIElement,
            logic: AXLogicProElements.Runtime) -> Bool {
            guard paths.count == 2, !CFEqual(activity.play, activity.record),
                  paths.allSatisfy({ !$0.isEmpty && CFEqual($0[$0.count - 1], window)
                      && $0.contains(where: { CFEqual($0, activity.controlBar) }) }),
                  CFEqual(paths[0][0], activity.play), CFEqual(paths[1][0], activity.record),
                  (try? SessionPopulationObservation.requireOwnedAcquisition()) != nil else { return false }
            return paths.allSatisfy({ held in
                      guard let control = held.first, let current = Self.path(control, to: window, ax: logic.ax),
                            Self.same(held, current) else { return false }
                      let attributes = AXHelpers.getNonHelpAttributes(control, [kAXRoleAttribute, kAXValueAttribute] as [String],
                          runtime: logic.ax, permittingRead: { (try? SessionPopulationObservation.requireOwnedAcquisition()) != nil })
                      guard case .success(.some(let role)) = attributes[0], role as? String == kAXCheckBoxRole as String,
                            case .success(.some(let rawValue)) = attributes[1], let value = rawValue as? NSNumber else { return false }
                      return value == 0
                  })
        }

        /// The coupled writer already owns its editor. Renew this proof's
        /// complete original source paths/census and stopped controls, never
        /// passive-focus permission, stored values or globally rediscovered rows.
        func permitsCoupledEditorTransportRead(pair: Pair) -> Bool {
            func originalSourceStillHeld() -> Bool {
                guard let role = AXHelpers.getRole(rail, runtime: logic.ax),
                      [kAXGroupRole, kAXListRole, kAXScrollAreaRole].contains(where: { role == $0 as String }),
                      case .read(let currentHeaders) = AXLogicProElements.enumerateTrackHeaderRows(
                    in: rail, runtime: logic.ax) else {
                    lost = true; pair.track.exposure?.end(); return false
                }
                // Feed the actual strict enumeration to the original exposures.
                // A sampled missing acquired header cannot recover on a reread.
                pair.track.exposure?.observeHeaders(currentHeaders)
                retainedTrackBindings?.forEach { $0.exposure?.observeHeaders(currentHeaders) }
                guard Self.same(headers, currentHeaders),
                      owned(checkingStoppedTransport: false) else {
                    lost = true; pair.track.exposure?.end(); return false
                }
                return true
            }
            guard !lost, (try? SessionPopulationObservation.requireOwnedAcquisition()) != nil,
                  CFEqual(pair.track.window, window), CFEqual(pair.strip.window, window),
                  CFEqual(pair.strip.mixer, mixer),
                  pair.track.document.utf8.elementsEqual(document.utf8),
                  pair.strip.document.utf8.elementsEqual(document.utf8),
                  headers.filter({ CFEqual($0, pair.track.header) }).count == 1,
                  strips.filter({ CFEqual($0, pair.strip.strip) }).count == 1,
                  logic.logicProPID() == pid, logic.focusedApplicationPID() == pid,
                  pair.track.runtime.logicProPID() == pid,
                  let currentApp = AXLogicProElements.appRoot(runtime: pair.track.runtime), CFEqual(currentApp, app),
                  case .success(.some(let currentDocument)) = AXLogicProElements.projectPickerDocumentRead(window, runtime: logic),
                  currentDocument.utf8.elementsEqual(document.utf8), stoppedTransportPathsMatch(),
                  // One fresh uniqueness census still rejects an added competing bar,
                  // including one appearing during the deciding Play/Record reads.
                  let currentBar = AXLogicProElements.getControlBar(in: window, runtime: logic.ax),
                  CFEqual(currentBar, transport.controlBar),
                  // Match the original editor guard's ordering: source custody
                  // is decided after the transport reads, not before them.
                  pair.track.exposure?.isCurrent ?? true,
                  originalSourceStillHeld(),
                  pair.track.exposure?.isCurrent ?? true,
                  (try? SessionPopulationObservation.requireOwnedAcquisition()) != nil else { return false }
            return true
        }

        /// Only this explicit association observation uses this request-local focus scope.
        /// It does not itself read Help, and cannot admit an editor, key event or
        /// unheld strip. Requested-strip Help remains under its existing guard.
        func permitsRead() -> Bool {
            // Capability reads do not move focus. Validate complete ownership once,
            // after their bookend, rather than repeating the same population census
            // twice for every caller's guarded AX read. Selection writes also
            // require the final scoped action boundary in select().
            guard !lost, (try? SessionPopulationObservation.requireOwnedAcquisition()) != nil,
                  Self.exclusiveIndex(headers, ax: logic.ax) == expectedIndex,
                  passiveFocusMatches() else { lost = true; return false }
            guard owned(), Self.exclusiveIndex(headers, ax: logic.ax) == expectedIndex,
                  let final: AXUIElement = AXHelpers.getAttribute(app, kAXFocusedUIElementAttribute as String, runtime: logic.ax),
                  CFEqual(final, expectedFocus), selectedChildCustodyMatches() else { lost = true; return false }
            return true
        }

        private func nativeOutputPopupMatches(_ root: AXUIElement, source: AXMixerStripBinding.Binding) -> Bool {
            guard AccessibilityChannel.checkedOutputPopupMenus(in: mixer, runtime: logic.ax)?.isEmpty == true,
                  CFEqual(source.window, window), CFEqual(source.mixer, mixer),
                  source.document.utf8.elementsEqual(document.utf8),
                  strips.filter({ CFEqual($0, source.strip) }).count == 1,
                  AccessibilityChannel.currentOutputMenuAssignment(in: root, runtime: logic.ax) == .noOutput,
                  let popup = AccessibilityChannel.NativeOutputReadPopup.read(
                    physical: source, app: app, pid: pid, runtime: logic),
                  CFEqual(popup.root, root) else { return false }
            return true
        }

        func permitsOwnedPopupRead(_ root: AXUIElement, nativeSource: AXMixerStripBinding.Binding? = nil) -> Bool {
            var stage = "original_selection_root_focus", accepted = false
            defer {
                if nativeSource != nil, !accepted {
                    Log.info("Native output popup read refused at \(stage)", subsystem: "ax")
                }
            }
            func popupMatches() -> Bool {
                guard let menus = AccessibilityChannel.checkedOutputPopupMenus(in: mixer, runtime: logic.ax) else { return false }
                if menus.count == 1 { return CFEqual(menus[0], root) }
                // The neutral output's native popup is not a Mixer AX child.
                // An explicit held source, its checked No Output and the existing
                // native window/hit/reciprocal-wrapper reader must all agree.
                guard menus.isEmpty, let source = nativeSource else { return false }
                return nativeOutputPopupMatches(root, source: source)
            }
            func heldRailChildMatches() -> Bool {
                guard originalRailFocus != nil else { return true }
                guard let expectedSelectedChild, case .observed(let child) = selectedChildRead(),
                      CFEqual(child, expectedSelectedChild),
                      Self.exclusiveIndex(headers, ax: logic.ax) == expectedIndex else { lost = true; return false }
                return true
            }
            // This is not a general editor exemption or a new association. Keep
            // the original complete census and exclusive selection; only allow
            // its reciprocal search field or the original app of a checked
            // native neutral popup, in addition to the original passive strip.
            guard !lost, (try? SessionPopulationObservation.requireOwnedAcquisition()) != nil,
                  Self.exclusiveIndex(headers, ax: logic.ax) == expectedIndex,
                  popupMatches(),
                  let focus: AXUIElement = AXHelpers.getAttribute(app, kAXFocusedUIElementAttribute as String, runtime: logic.ax)
            else {
                Log.info("Input popup ownership refused: original selection/root/focus", subsystem: "ax")
                lost = true; return false
            }
            stage = "original_passive_metadata"
            guard passiveAssociationFocusMatches(expectedFocus), heldRailChildMatches() else {
                Log.info("Input popup ownership refused: original passive association metadata", subsystem: "ax")
                return false
            }
            // Some owned popups keep the original passive strip focused. Its
            // existing full witness also handles native zero insertion metadata;
            // do not classify that qualified strip as an arbitrary editor.
            if CFEqual(focus, expectedFocus) {
                stage = "passive_focus_ownership"
                guard passiveFocusMatches(), owned(ownedPopup: root, nativeOutputSource: nativeSource),
                      Self.exclusiveIndex(headers, ax: logic.ax) == expectedIndex,
                      let final: AXUIElement = AXHelpers.getAttribute(app, kAXFocusedUIElementAttribute as String, runtime: logic.ax),
                      CFEqual(final, expectedFocus), heldRailChildMatches(), passiveAssociationFocusMatches(expectedFocus),
                      let afterChild: AXUIElement = AXHelpers.getAttribute(app, kAXFocusedUIElementAttribute as String, runtime: logic.ax),
                      CFEqual(afterChild, expectedFocus),
                      nativeSource == nil || popupMatches() else { lost = true; return false }
                accepted = true
                return true
            }
            let focusRole = AXHelpers.getRole(focus, runtime: logic.ax)
            stage = "search_field_role_\(focusRole ?? "unread")"
            if nativeSource != nil, focusRole == kAXApplicationRole as String, CFEqual(focus, app) {
                // The native neutral popup can report its original application
                // as focused instead of an AX search field. Only this existing
                // checked native window/root/source proof qualifies that exact CF;
                // an arbitrary application or ordinary menu gains no exemption.
                stage = "native_application_focus"
                guard AccessibilityChannel.checkedOutputPopupMenus(in: mixer, runtime: logic.ax)?.isEmpty == true,
                      popupMatches() else { lost = true; return false }
            } else {
                guard focusRole == kAXTextFieldRole as String,
                      case .success(let rows) = AXHelpers.childrenResult(root, runtime: logic.ax),
                      let parent: AXUIElement = AXHelpers.getAttribute(focus, kAXParentAttribute as String, runtime: logic.ax)
                else { lost = true; return false }
                if CFEqual(parent, root) {
                    stage = "direct_search_field_membership"
                    guard rows.filter({ CFEqual($0, focus) }).count == 1 else { lost = true; return false }
                } else {
                    stage = "nested_search_field_membership"
                    guard rows.filter({ CFEqual($0, parent) }).count == 1,
                          let role = AXHelpers.getRole(parent, runtime: logic.ax),
                          role == kAXGroupRole as String || role == "AXMenuItem",
                          let parentRoot: AXUIElement = AXHelpers.getAttribute(parent, kAXParentAttribute as String, runtime: logic.ax),
                          CFEqual(parentRoot, root),
                          case .success(let children) = AXHelpers.childrenResult(parent, runtime: logic.ax),
                          children.filter({ CFEqual($0, focus) }).count == 1 else { lost = true; return false }
                }
            }
            stage = "search_field_popup_bookend"
            guard popupMatches(),
                  let final: AXUIElement = AXHelpers.getAttribute(app, kAXFocusedUIElementAttribute as String, runtime: logic.ax),
                  CFEqual(final, focus) else {
                Log.info("Input popup ownership refused: reciprocal focus/root", subsystem: "ax")
                lost = true; return false
            }
            stage = "complete_native_ownership"
            guard owned(ownedPopup: root, nativeOutputSource: nativeSource) else {
                Log.info("Input popup ownership refused: full association custody", subsystem: "ax")
                return false
            }
            stage = "final_native_focus"
            guard
                  Self.exclusiveIndex(headers, ax: logic.ax) == expectedIndex,
                  heldRailChildMatches(), passiveAssociationFocusMatches(expectedFocus),
                  currentWindowScopeMatches(), logic.logicProPID() == pid,
                  logic.focusedApplicationPID() == pid,
                  (try? SessionPopulationObservation.requireOwnedAcquisition()) != nil,
                  let afterChild: AXUIElement = AXHelpers.getAttribute(app, kAXFocusedUIElementAttribute as String, runtime: logic.ax),
                  CFEqual(afterChild, focus) else { lost = true; return false }
            accepted = true
            return true
        }

        /// Only ReadFocusScope uses this witness. Full exclusive-selection and
        /// population custody still authorize every association action, inverse
        /// and publication. Passive Help never acquires that authority.
        func permitsPassiveFocusRead() -> Bool {
            guard passiveFocusMatches(), owned(checkingAssociation: false) else { lost = true; return false }
            // Fresh final values from this original app, not owned()'s earlier
            // sample. Help still asks the complete proof before every real read.
            let finalApp = AXHelpers.getNonHelpAttributes(app,
                [kAXFocusedUIElementAttribute, kAXMainWindowAttribute, kAXFocusedWindowAttribute] as [String],
                runtime: logic.ax, permittingRead: { (try? SessionPopulationObservation.requireOwnedAcquisition()) != nil })
            guard case .success(.some(let rawFocus)) = finalApp[0], CFGetTypeID(rawFocus) == AXUIElementGetTypeID(),
                  case .success(.some(let rawMain)) = finalApp[1], CFGetTypeID(rawMain) == AXUIElementGetTypeID(),
                  case .success(.some(let rawWindow)) = finalApp[2], CFGetTypeID(rawWindow) == AXUIElementGetTypeID() else {
                lost = true; return false
            }
            let final = unsafeDowncast(rawFocus, to: AXUIElement.self)
            let main = unsafeDowncast(rawMain, to: AXUIElement.self)
            let focusedWindow = unsafeDowncast(rawWindow, to: AXUIElement.self)
            guard
                  CFEqual(final, expectedFocus),
                  CFEqual(main, window),
                  CFEqual(focusedWindow, window),
                  case .success(.some(let finalDocument)) = AXLogicProElements.projectPickerDocumentRead(window, runtime: logic),
                  document.utf8.elementsEqual(finalDocument.utf8), logic.logicProPID() == pid,
                  (try? SessionPopulationObservation.requireOwnedAcquisition()) != nil else { lost = true; return false }
            return true
        }

        private func passiveFocusMatches() -> Bool {
            guard !lost, (try? SessionPopulationObservation.requireOwnedAcquisition()) != nil,
                  let focus: AXUIElement = AXHelpers.getAttribute(app, kAXFocusedUIElementAttribute as String, runtime: logic.ax),
                  CFEqual(focus, expectedFocus) else { lost = true; return false }
            return passiveAssociationFocusMatches(focus)
        }

        private func passiveAssociationFocusMatches(_ focus: AXUIElement) -> Bool {
            if strips.contains(where: { CFEqual($0, focus) }) { return passiveStripMatches(focus) }
            if let originalHeaderFocus, CFEqual(focus, originalHeaderFocus.focus) {
                // This witness only corroborates the retained numeric name's
                // nonediting physical custody. Full rail/selection/relationship
                // ownership still governs every challenge and its inverse.
                guard originalRailFocus.map({ CFEqual($0, focus) }) == true,
                      expectedSelectedChild != nil, originalHeaderFocus.permits() else { lost = true; return false }
                return true
            }
            guard let originalRailFocus, CFEqual(focus, originalRailFocus), expectedSelectedChild != nil,
                  let role = AXHelpers.getRole(focus, runtime: logic.ax),
                  [kAXGroupRole as String, kAXListRole as String, kAXLayoutAreaRole as String].contains(role),
                  AXHelpers.isAttributeSettable(focus, kAXValueAttribute as String, runtime: logic.ax) == false,
                  let currentPath = Self.path(rail, to: window, ax: logic.ax), Self.same(railPath, currentPath),
                  currentPath.contains(where: { CFEqual($0, focus) }) else { lost = true; return false }
            let attributes = [kAXValueAttribute, kAXSelectedTextAttribute,
                              kAXNumberOfCharactersAttribute, kAXInsertionPointLineNumberAttribute] as [String]
            let readings = AXHelpers.getNonHelpAttributes(focus, attributes, runtime: logic.ax,
                permittingRead: { (try? SessionPopulationObservation.requireOwnedAcquisition()) != nil })
            // Unlike the already-qualified passive strip, a rail container gets
            // no zero-insertion/editor exception and no settable focus cleanup.
            guard readings.allSatisfy({ reading in
                if case .failure(let error) = reading { return error.isDefinitiveAbsence }
                return false
            }) else { lost = true; return false }
            return true
        }

        private func passiveStripMatches(_ focus: AXUIElement) -> Bool {
            guard strips.filter({ CFEqual($0, focus) }).count == 1,
                  AXHelpers.getRole(focus, runtime: logic.ax) == kAXLayoutItemRole as String,
                  AXHelpers.isAttributeSettable(focus, kAXValueAttribute as String, runtime: logic.ax) == false else { lost = true; return false }
            let attributes = [kAXValueAttribute, kAXSelectedTextAttribute,
                              kAXNumberOfCharactersAttribute, kAXInsertionPointLineNumberAttribute] as [String]
            let readings = AXHelpers.getNonHelpAttributes(focus, attributes, runtime: logic.ax,
                permittingRead: { (try? SessionPopulationObservation.requireOwnedAcquisition()) != nil })
            for (attribute, reading) in zip(attributes, readings) {
                switch reading {
                case .failure(let error) where error.isDefinitiveAbsence: continue
                case .success(.some(let value)):
                    guard attribute == kAXNumberOfCharactersAttribute as String || attribute == kAXInsertionPointLineNumberAttribute as String,
                          CFGetTypeID(value) == CFNumberGetTypeID(), let number = value as? NSNumber,
                          number.doubleValue == 0 else { lost = true; return false }
                default: lost = true; return false
                }
            }
            return true
        }

        private enum SelectedChildRead {
            case unavailable, unverified
            case observed(AXUIElement)
        }

        /// A relationship supplied by this exact Mixer owner, not a strip ordinal
        /// or name join. Individual strip AXSelected booleans are not equivalent.
        private func selectedChildRead() -> SelectedChildRead {
            let values = AXHelpers.getNonHelpAttributes(mixer, [kAXSelectedChildrenAttribute as String],
                runtime: logic.ax, permittingRead: {
                    (try? SessionPopulationObservation.requireOwnedAcquisition()) != nil
                })
            switch values[0] {
            case .failure(let error) where error.isDefinitiveAbsence: return .unavailable
            case .success(.none): return .unavailable
            case .success(.some(let raw)):
                guard CFGetTypeID(raw) == CFArrayGetTypeID() else { return .unverified }
                let array = unsafeDowncast(raw, to: CFArray.self)
                guard CFArrayGetCount(array) == 1 else { return .unverified }
                let element = unsafeBitCast(CFArrayGetValueAtIndex(array, 0), to: CFTypeRef.self)
                guard CFGetTypeID(element) == AXUIElementGetTypeID() else { return .unverified }
                let child = unsafeDowncast(element, to: AXUIElement.self)
                // Renew reciprocal membership after the relationship read: a
                // retired child can retain its old parent and CF identity.
                guard let current = AXLogicProElements.mixerChannelStripsIfCompletelyRead(in: mixer, runtime: logic.ax),
                      Self.same(strips, current.strips),
                      current.strips.filter({ CFEqual($0, child) }).count == 1,
                      let parent: AXUIElement = AXHelpers.getAttribute(child, kAXParentAttribute as String,
                        runtime: logic.ax), CFEqual(parent, mixer) else { return .unverified }
                return .observed(child)
            default: return .unverified
            }
        }

        private var associationStrip: AXUIElement { expectedSelectedChild ?? expectedFocus }

        private func railMetadataRetainsStripCustody() -> Bool {
            guard originalRailFocus != nil else { return true }
            // R965-RAIL-C001: the new rail metadata reads can retire an old
            // selected child while leaving its old parent/relationship readable.
            guard let current = AXLogicProElements.mixerChannelStripsIfCompletelyRead(in: mixer, runtime: logic.ax) else { return false }
            return Self.same(strips, current.strips)
        }

        private func selectedChildCustodyMatches() -> Bool {
            guard let expectedSelectedChild else { return true }
            guard case .observed(let child) = selectedChildRead(), CFEqual(child, expectedSelectedChild),
                  Self.exclusiveIndex(headers, ax: logic.ax) == expectedIndex,
                  let focus: AXUIElement = AXHelpers.getAttribute(app, kAXFocusedUIElementAttribute as String,
                    runtime: logic.ax), CFEqual(focus, expectedFocus), passiveAssociationFocusMatches(focus),
                  railMetadataRetainsStripCustody() else { lost = true; return false }
            // One fresh same-app window decision; retain the preceding rail
            // renewal and the following document/PID bookends independently.
            let windows = AXHelpers.getNonHelpAttributes(app,
                [kAXMainWindowAttribute, kAXFocusedWindowAttribute] as [String], runtime: logic.ax,
                permittingRead: { (try? SessionPopulationObservation.requireOwnedAcquisition()) != nil })
            guard case .success(.some(let main)) = windows[0], CFGetTypeID(main) == AXUIElementGetTypeID(),
                  case .success(.some(let focusedWindow)) = windows[1], CFGetTypeID(focusedWindow) == AXUIElementGetTypeID(),
                  CFEqual(main, window), CFEqual(focusedWindow, window), currentWindowScopeMatches(),
                  logic.logicProPID() == pid, logic.focusedApplicationPID() == pid,
                  (try? SessionPopulationObservation.requireOwnedAcquisition()) != nil else {
                lost = true; return false
            }
            return true
        }

        /// Layout is a restoration duty, never a replacement peer identity.
        struct MixerViewportGeometry: @unchecked Sendable {
            let window: AXUIElement
            let mixer: AXUIElement
            let headers: [AXUIElement]
            let document: String
            let frames: [CGRect]
            let horizontal: HorizontalViewportPosition?

            func hasSameViewportPosition(as other: Self) -> Bool {
                guard frames == other.frames else { return false }
                switch (horizontal, other.horizontal) {
                case (.none, .none): return true
                case (.some(let lhs), .some(let rhs)):
                    return lhs.sameControlAndLayout(as: rhs) && lhs.value == rhs.value
                default: return false
                }
            }
        }

        struct HorizontalViewportPosition: @unchecked Sendable {
            let control: AXUIElement
            let owner: AXUIElement
            let value: Double
            let windowFrame: CGRect
            let mixerFrame: CGRect
            let ownerFrame: CGRect
            let controlFrame: CGRect

            func sameControlAndLayout(as other: Self) -> Bool {
                CFEqual(control, other.control) && CFEqual(owner, other.owner)
                    && windowFrame == other.windowFrame && mixerFrame == other.mixerFrame
                    && ownerFrame == other.ownerFrame && controlFrame == other.controlFrame
            }
        }

        private func horizontalViewportPosition() -> HorizontalViewportPosition? {
            guard let hitTest = logic.ax.elementAtPosition, permitsRead() else { return nil }
            func frame(_ element: AXUIElement) -> CGRect? {
                guard let point = AXHelpers.getPosition(element, runtime: logic.ax),
                      let size = AXHelpers.getSize(element, runtime: logic.ax),
                      point.x.isFinite, point.y.isFinite, size.width.isFinite, size.height.isFinite,
                      size.width > 0, size.height > 0 else { return nil }
                return CGRect(origin: point, size: size)
            }
            guard let windowFrame = frame(window), let mixerFrame = frame(mixer),
                  let owner: AXUIElement = AXHelpers.getAttribute(mixer, kAXParentAttribute as String, runtime: logic.ax),
                  path.count > 1, CFEqual(owner, path[1]),
                  AXHelpers.getRole(owner, runtime: logic.ax) == kAXGroupRole as String,
                  let ownerFrame = frame(owner) else { return nil }
            let visible = windowFrame.intersection(mixerFrame)
            guard !visible.isNull, visible.width > 0, visible.height > 17 else { return nil }
            // This point discovers a native object; its coordinates grant no
            // action authority. Logic omits this bar from its owner's children.
            let point = CGPoint(x: visible.midX, y: visible.maxY - 7)
            guard case .success(let hit?) = hitTest(app, point), let hitFrame = frame(hit), hitFrame.contains(point),
                  let hitWindow: AXUIElement = AXHelpers.getAttribute(hit, kAXWindowAttribute as String, runtime: logic.ax),
                  CFEqual(hitWindow, window) else { return nil }
            let control: AXUIElement
            if AXHelpers.getRole(hit, runtime: logic.ax) == kAXScrollBarRole as String { control = hit }
            else {
                guard AXHelpers.getRole(hit, runtime: logic.ax) == kAXValueIndicatorRole as String,
                      let parent: AXUIElement = AXHelpers.getAttribute(hit, kAXParentAttribute as String, runtime: logic.ax),
                      case .success(let children) = AXHelpers.childrenResult(parent, runtime: logic.ax),
                      children.filter({ CFEqual($0, hit) }).count == 1 else { return nil }
                control = parent
            }
            guard AXHelpers.getRole(control, runtime: logic.ax) == kAXScrollBarRole as String,
                  AXHelpers.getAttribute(control, kAXOrientationAttribute as String, runtime: logic.ax) as String? == kAXHorizontalOrientationValue as String,
                  let parent: AXUIElement = AXHelpers.getAttribute(control, kAXParentAttribute as String, runtime: logic.ax),
                  CFEqual(parent, owner),
                  let controlWindow: AXUIElement = AXHelpers.getAttribute(control, kAXWindowAttribute as String, runtime: logic.ax),
                  CFEqual(controlWindow, window), let controlFrame = frame(control), controlFrame.contains(point)
            else { return nil }
            guard case .success(.some(let raw)) = AXHelpers.getAttributeResult(control, kAXValueAttribute as String,
                    runtime: logic.ax) as Result<AnyObject?, AXHelpers.AXStatusError>,
                  CFGetTypeID(raw) == CFNumberGetTypeID(), let value = raw as? NSNumber,
                  value.doubleValue.isFinite, (0...1).contains(value.doubleValue),
                  AXHelpers.isAttributeSettable(control, kAXValueAttribute as String, runtime: logic.ax) == true
            else { return nil }
            guard case .success(let decidingHit?) = hitTest(app, point), CFEqual(decidingHit, hit),
                  frame(window) == windowFrame, frame(mixer) == mixerFrame, frame(owner) == ownerFrame,
                  frame(control) == controlFrame,
                  AXHelpers.getRole(control, runtime: logic.ax) == kAXScrollBarRole as String,
                  AXHelpers.getAttribute(control, kAXOrientationAttribute as String, runtime: logic.ax) as String? == kAXHorizontalOrientationValue as String,
                  let decidingParent: AXUIElement = AXHelpers.getAttribute(control, kAXParentAttribute as String, runtime: logic.ax),
                  CFEqual(decidingParent, owner), permitsRead() else { return nil }
            return .init(control: control, owner: owner, value: value.doubleValue,
                windowFrame: windowFrame, mixerFrame: mixerFrame, ownerFrame: ownerFrame, controlFrame: controlFrame)
        }

        func observedMixerViewportGeometry() -> MixerViewportGeometry? {
            guard permitsRead() else { return nil }
            let horizontalBefore = horizontalViewportPosition()
            var frames: [CGRect] = []
            for strip in strips {
                guard (try? SessionPopulationObservation.requireOwnedAcquisition()) != nil,
                      let point = AXHelpers.getPosition(strip, runtime: logic.ax),
                      let size = AXHelpers.getSize(strip, runtime: logic.ax),
                      point.x.isFinite, point.y.isFinite, size.width.isFinite, size.height.isFinite,
                      size.width > 0, size.height > 0 else { return nil }
                frames.append(CGRect(origin: point, size: size))
            }
            let horizontalAfter = horizontalViewportPosition()
            switch (horizontalBefore, horizontalAfter) {
            case (.none, .none): break
            case (.some(let before), .some(let after)):
                guard before.sameControlAndLayout(as: after), before.value == after.value else { return nil }
            default: return nil
            }
            guard permitsRead() else { return nil }
            return .init(window: window, mixer: mixer, headers: headers, document: document,
                frames: frames, horizontal: horizontalAfter)
        }

        /// The installed Scroll To menu exposes existing physical rows without
        /// selecting a channel, synthesizing keys or changing a routing value.
        /// Success still requires the exact original layout and native census.
        func recoverMixerReadability(
            restoring original: MixerViewportGeometry,
            referenceIsCurrent: @Sendable () async -> Bool,
            stoppingWhen stop: @Sendable () -> Bool
        ) async -> Bool {
            var recoveryStage = "original_geometry", recovered = false
            defer {
                if !recovered { Log.info("Owned Mixer Scroll To recovery refused at \(recoveryStage)", subsystem: "ax") }
            }
            guard CFEqual(original.window, window), CFEqual(original.mixer, mixer),
                  original.document.utf8.elementsEqual(document.utf8),
                  Self.same(original.headers, headers), original.frames.count == strips.count,
                  !stop(), await referenceIsCurrent(), permitsRead() else { return false }
            recoveryStage = "owned_view_discovery"
            guard let parent: AXUIElement = AXHelpers.getAttribute(mixer, kAXParentAttribute as String, runtime: logic.ax),
                  let parentPath = Self.path(parent, to: window, ax: logic.ax),
                  case .success(let buttons) = AXHelpers.censusDescendantResult(of: parent,
                    role: kAXMenuButtonRole as String, maxDepth: 32, runtime: logic.ax,
                    requiresCompleteTraversal: true,
                    permittingRead: { (try? SessionPopulationObservation.requireOwnedAcquisition()) != nil })
            else { return false }
            var views: [AXUIElement] = []
            for button in buttons.matches {
                switch AXLocalePolicy.elementMatchesResult(button, AXLocalePolicy.viewMenuBar, runtime: logic.ax) {
                case .success(true): views.append(button)
                case .success(false): break
                case .failure: return false
                }
            }
            guard views.count == 1, let view = views.first,
                  let viewPath = Self.path(view, to: window, ax: logic.ax),
                  viewPath.contains(where: { CFEqual($0, parent) }), permitsRead() else { return false }
            func scopeHeld() -> Bool {
                guard !stop(), permitsRead(),
                      let currentParent: AXUIElement = AXHelpers.getAttribute(mixer, kAXParentAttribute as String, runtime: logic.ax),
                      CFEqual(currentParent, parent),
                      let currentParentPath = Self.path(parent, to: window, ax: logic.ax),
                      Self.same(currentParentPath, parentPath),
                      let currentViewPath = Self.path(view, to: window, ax: logic.ax),
                      Self.same(currentViewPath, viewPath) else { return false }
                // Path reads can themselves coincide with scope loss. Renew
                // native custody after those deciding reads, not before them.
                return permitsRead()
            }
            func childMenus(_ owner: AXUIElement) -> [AXUIElement]? {
                guard case .success(let children) = AXHelpers.childrenResult(owner, runtime: logic.ax) else {
                    Log.info("Owned Mixer menu children unreadable", subsystem: "ax"); return nil
                }
                var menus: [AXUIElement] = []
                for child in children {
                    guard let role = AXHelpers.getRole(child, runtime: logic.ax) else {
                        Log.info("Owned Mixer menu child role unreadable", subsystem: "ax"); return nil
                    }
                    if role == kAXMenuRole as String {
                        let parentRead: Result<AXUIElement?, AXHelpers.AXStatusError> = AXHelpers.getAttributeResult(
                            child, kAXParentAttribute as String, runtime: logic.ax)
                        // Logic's Mixer View root is exposed in View's children,
                        // but its native parent is the exact original controls
                        // group two edges above View. Only this measured root
                        // shape qualifies; submenus retain their direct parent.
                        let retainedViewContainer: Bool
                        if case .success(.some(let reciprocal)) = parentRead,
                           CFEqual(owner, view), viewPath.count > 3,
                           CFEqual(reciprocal, viewPath[2]),
                           AXHelpers.getRole(reciprocal, runtime: logic.ax) == kAXGroupRole as String {
                            retainedViewContainer = true
                        } else { retainedViewContainer = false }
                        guard case .success(.some(let reciprocal)) = parentRead,
                              CFEqual(reciprocal, owner) || retainedViewContainer else {
                            switch parentRead {
                            case .success(.some(let actual)):
                                Log.info("Owned Mixer menu parent differs: role=\(AXHelpers.getRole(actual, runtime: logic.ax) ?? "unread"), original_app=\(CFEqual(actual, app)), mixer_parent=\(CFEqual(actual, parent)), view_ancestor_depth=\(viewPath.firstIndex(where: { CFEqual($0, actual) }) ?? -1)", subsystem: "ax")
                            case .success(.none): Log.info("Owned Mixer menu parent absent", subsystem: "ax")
                            case .failure(let error): Log.info("Owned Mixer menu parent failed AX:\(error.raw)", subsystem: "ax")
                            }
                            return nil
                        }
                        menus.append(child)
                    }
                }
                return menus
            }
            let timing = AccessibilityChannel.OutputAssignmentTiming.live
            func uniqueItem(in menu: AXUIElement, matching labels: AXLocalePolicy.LabelSet) -> AXUIElement? {
                guard case .success(let children) = AXHelpers.childrenResult(menu, runtime: logic.ax) else { return nil }
                var matches: [AXUIElement] = []
                for child in children {
                    guard AXHelpers.getRole(child, runtime: logic.ax) == kAXMenuItemRole as String,
                          let owner: AXUIElement = AXHelpers.getAttribute(child, kAXParentAttribute as String, runtime: logic.ax),
                          CFEqual(owner, menu) else { return nil }
                    switch AXLocalePolicy.elementMatchesResult(child, labels, runtime: logic.ax) {
                    case .success(true): matches.append(child)
                    case .success(false): break
                    case .failure: return nil
                    }
                }
                return matches.count == 1 ? matches.first : nil
            }
            func cancelOwnedRoot(_ root: AXUIElement) async {
                guard scopeHeld(), let roots = childMenus(view), roots.count == 1,
                      roots.first.map({ CFEqual($0, root) }) == true,
                      logic.ax.actionNames(root).contains(kAXCancelAction as String), scopeHeld(),
                      await referenceIsCurrent(), !stop(),
                      (try? SessionPopulationObservation.requireOwnedAcquisition()) != nil else { return }
                _ = AXHelpers.performAction(root, kAXCancelAction as String, runtime: logic.ax)
                if childMenus(view)?.isEmpty == true, scopeHeld(),
                   let final = observedMixerViewportGeometry(), final.frames == original.frames,
                   let current = currentViewport(), Self.sameViewport(current, viewport),
                   await referenceIsCurrent() { effects.restoration = "restored" }
            }
            for (name, labels) in [("output", AXLocalePolicy.mixerScrollToOutputsMenuItem), ("audio", AXLocalePolicy.mixerTypeFilterAudio)] {
                recoveryStage = name + "_view_action"
                guard childMenus(view)?.isEmpty == true,
                      AXHelpers.getAttribute(view, kAXEnabledAttribute as String, runtime: logic.ax) as Bool? == true,
                      logic.ax.actionNames(view).contains(kAXPressAction as String), scopeHeld(),
                      await referenceIsCurrent(), !stop(),
                      (try? SessionPopulationObservation.requireOwnedAcquisition()) != nil else { return false }
                effects.navigationPerformed = true; effects.restoration = "not_restored"
                effects.attempted.append("mixer_scroll_to_" + name)
                let opened = AXHelpers.performAction(view, kAXPressAction as String, runtime: logic.ax)
                recoveryStage = name + "_owned_root"
                var roots: [AXUIElement]?
                let openDeadline = ContinuousClock.now.advanced(by: .milliseconds(timing.popupOpenTimeoutMs))
                repeat {
                    guard scopeHeld() else { recoveryStage = name + "_root_scope"; return false }
                    roots = childMenus(view)
                    if roots?.count == 1 { break }
                    guard roots?.isEmpty == true else { recoveryStage = name + "_root_ownership"; return false }
                    guard ContinuousClock.now < openDeadline else { recoveryStage = name + "_root_timeout"; return false }
                    do { try await Task.sleep(for: .milliseconds(timing.pollIntervalMs)) } catch { return false }
                } while true
                guard let roots, roots.count == 1, let root = roots.first else { return false }
                // A failed AX acknowledgement does not prove no effect. Only
                // this original View's uniquely owned reciprocal root may close.
                guard opened else { await cancelOwnedRoot(root); return false }
                recoveryStage = name + "_scoped_leaf"
                guard let scrollTo = uniqueItem(in: root, matching: AXLocalePolicy.mixerScrollToMenuItem),
                      let submenus = childMenus(scrollTo), submenus.count == 1, let submenu = submenus.first,
                      let leaf = uniqueItem(in: submenu, matching: labels),
                      AXHelpers.getAttribute(leaf, kAXEnabledAttribute as String, runtime: logic.ax) as Bool? == true,
                      logic.ax.actionNames(leaf).contains(kAXPressAction as String),
                      let currentRoots = childMenus(view), currentRoots.count == 1,
                      currentRoots.first.map({ CFEqual($0, root) }) == true,
                      scopeHeld(),
                      await referenceIsCurrent(), !stop(),
                      (try? SessionPopulationObservation.requireOwnedAcquisition()) != nil else {
                    await cancelOwnedRoot(root); return false
                }
                guard AXHelpers.performAction(leaf, kAXPressAction as String, runtime: logic.ax) else {
                    await cancelOwnedRoot(root); return false
                }
                recoveryStage = name + "_closed_root"
                let closeDeadline = ContinuousClock.now.advanced(by: .milliseconds(timing.popupCloseTimeoutMs))
                repeat {
                    guard scopeHeld() else { return false }
                    if childMenus(view)?.isEmpty == true { break }
                    guard ContinuousClock.now < closeDeadline else { await cancelOwnedRoot(root); return false }
                    do { try await Task.sleep(for: .milliseconds(timing.pollIntervalMs)) } catch { return false }
                } while true
                guard childMenus(view)?.isEmpty == true, scopeHeld() else { return false }
                effects.changed.append("mixer_scroll_to_" + name)
            }
            recoveryStage = "final_geometry_read"
            guard var final = observedMixerViewportGeometry() else { return false }
            if let before = original.horizontal, let after = final.horizontal,
               before.sameControlAndLayout(as: after), before.value != after.value,
               let first = original.frames.first, let currentFirst = final.frames.first {
                recoveryStage = "horizontal_viewport_inverse"
                let delta = currentFirst.minX - first.minX
                guard delta.isFinite, zip(original.frames, final.frames).allSatisfy({ a, b in
                    a.size == b.size && a.minY == b.minY && b.minX - a.minX == delta
                }), await referenceIsCurrent(),
                      let deciding = observedMixerViewportGeometry(), deciding.frames == final.frames,
                      let current = deciding.horizontal, current.sameControlAndLayout(as: after), current.value == after.value,
                      childMenus(view)?.isEmpty == true, scopeHeld(),
                      !stop(),
                      (try? SessionPopulationObservation.requireOwnedAcquisition()) != nil else { return false }
                effects.attempted.append("mixer_horizontal_viewport")
                let accepted = AXHelpers.setAttribute(before.control, kAXValueAttribute as String,
                    NSNumber(value: before.value), runtime: logic.ax)
                guard let restored = observedMixerViewportGeometry(), let position = restored.horizontal,
                      accepted, position.sameControlAndLayout(as: before), position.value == before.value,
                      restored.frames == original.frames, scopeHeld() else { return false }
                effects.changed.append("mixer_horizontal_viewport")
                final = restored
            }
            recoveryStage = "final_strip_frames"
            guard final.hasSameViewportPosition(as: original) else {
                let changed = zip(original.frames, final.frames).enumerated().compactMap { index, pair in
                    pair.0 == pair.1 ? nil : "\(index):\(pair.0)->\(pair.1)"
                }.joined(separator: ";")
                Log.info("Owned Mixer recovery layout differs: \(changed)", subsystem: "ax")
                return false
            }
            recoveryStage = "final_viewport_read"
            guard let current = currentViewport() else { return false }
            recoveryStage = "final_expected_viewport"
            guard Self.sameViewport(current, expectedViewport) else { return false }
            recoveryStage = "final_original_viewport"
            guard Self.sameViewport(current, viewport) else { return false }
            recoveryStage = "final_reference"
            guard await referenceIsCurrent() else { return false }
            recoveryStage = "final_native_custody"
            guard permitsRead() else { return false }
            effects.restoration = "restored"
            recovered = true
            return true
        }

        private func select(_ index: Int, referenceIsCurrent: @Sendable () async -> Bool,
                            stoppingWhen stop: @Sendable () -> Bool,
                            requiresNonStackHeader: Bool = false) async -> Bool {
            guard !lost, !stop(), (try? SessionPopulationObservation.requireOwnedAcquisition()) != nil,
                  AXHelpers.isAttributeSettable(rail, kAXSelectedChildrenAttribute as String,
                runtime: logic.ax) == true,
                  let beforeViewport = currentViewport(), Self.sameViewport(beforeViewport, expectedViewport),
                  permitsRead(), !stop(),
                  (try? SessionPopulationObservation.requireOwnedAcquisition()) != nil,
                  owned(), selectedChildCustodyMatches(),
                  !requiresNonStackHeader || (AXValueExtractors.extractTrackStackState(from: headers[index],
                    runtime: logic.ax).isStackHeader == false && owned() && selectedChildCustodyMatches()) else { return false }
            // The selected-child read is a new deciding read. Renew the request
            // reference after it, then check the pure lease without another AX
            // read before the selection write.
            if expectedSelectedChild != nil {
                guard await referenceIsCurrent(),
                      (try? SessionPopulationObservation.requireOwnedAcquisition()) != nil else { return false }
            }
            // R965-ASSOC-C001: the deciding focus/selection reads in permitsRead
            // can themselves coincide with a document/window switch. Revalidate
            // scoped ownership AFTER them, with no further AX read before write.
            effects.navigationPerformed = true; effects.restoration = "not_restored"
            if !effects.attempted.contains("track_selection") { effects.attempted.append("track_selection") }
            let precedingFocus = expectedFocus
            let precedingSelectedChild = expectedSelectedChild
            let accepted = AXHelpers.setAttribute(rail, kAXSelectedChildrenAttribute as String, [headers[index]] as CFArray, runtime: logic.ax)
            for attempt in 0..<4 {
                guard owned() else { return false }
                let selectionChanged = Self.exclusiveIndex(headers, ax: logic.ax) == index
                if selectionChanged, !effects.changed.contains("track_selection") {
                    effects.changed.append("track_selection")
                }
                guard let focus: AXUIElement = AXHelpers.getAttribute(app, kAXFocusedUIElementAttribute as String, runtime: logic.ax),
                      strips.filter({ CFEqual($0, focus) }).count == 1
                        || originalRailFocus.map({ CFEqual($0, focus) }) == true else {
                    lost = true; return false
                }
                if selectionChanged {
                    var selectedChild: AXUIElement?
                    if precedingSelectedChild != nil {
                        guard case .observed(let child) = selectedChildRead() else { lost = true; return false }
                        selectedChild = child
                    } else { selectedChild = nil }
                    // Selection and its Mixer relationship can settle on
                    // different host turns. Do not freeze the old strip as a pair.
                    // Only original held strips are admitted by the guard above.
                    let awaitingOwnFocus: Bool
                    if let selectedChild, let precedingSelectedChild, let originalSelectedChild {
                        awaitingOwnFocus = index == originalIndex
                            ? !CFEqual(selectedChild, originalSelectedChild) : CFEqual(selectedChild, precedingSelectedChild)
                    } else {
                        awaitingOwnFocus = index == originalIndex
                            ? !CFEqual(focus, originalFocus) : CFEqual(focus, precedingFocus)
                    }
                    if awaitingOwnFocus && attempt < 3 {
                        do { try await Task.sleep(for: .milliseconds(30)) } catch { return false }
                        continue
                    }
                    guard let afterViewport = currentViewport() else { return false }
                    // The viewport read may coincide with our selected child's
                    // delayed focus landing. Admit only that exact transition,
                    // not another held strip or an unrelated editor. Unchanged
                    // preceding focus remains valid when Logic retains it.
                    guard let settledFocus: AXUIElement = AXHelpers.getAttribute(app,
                        kAXFocusedUIElementAttribute as String, runtime: logic.ax) else {
                        lost = true; return false
                    }
                    if !CFEqual(settledFocus, focus) {
                        guard CFEqual(focus, precedingFocus),
                              let precedingSelectedChild,
                              case .observed(let currentSelectedChild) = selectedChildRead(),
                              !CFEqual(currentSelectedChild, precedingSelectedChild),
                              CFEqual(settledFocus, currentSelectedChild) else {
                            lost = true; return false
                        }
                        selectedChild = currentSelectedChild
                    } else if let priorChild = selectedChild, let precedingSelectedChild,
                              CFEqual(priorChild, precedingSelectedChild),
                              !CFEqual(settledFocus, precedingFocus) {
                        // Focus may settle before its selected-child relationship.
                        // Renew a child that lands during the viewport read only
                        // onto that already observed focus. Retaining the preceding
                        // child is still not a new association witness.
                        guard case .observed(let currentSelectedChild) = selectedChildRead(),
                              CFEqual(currentSelectedChild, priorChild)
                                || CFEqual(currentSelectedChild, settledFocus) else {
                            lost = true; return false
                        }
                        selectedChild = currentSelectedChild
                    }
                    // Logic can select our exact held header while retaining its
                    // original Mixer relationship. Retain that owned transition
                    // for inverse cleanup; observe() still requires a different
                    // challenge strip before publishing any association pair.
                    expectedIndex = index; expectedFocus = settledFocus
                    expectedSelectedChild = selectedChild
                    expectedViewport = afterViewport
                    return permitsRead() && !stop() && accepted
                }
                if attempt < 3 {
                    do { try await Task.sleep(for: .milliseconds(30)) } catch { return false }
                }
            }
            return false
        }

        /// UI focus may enter only the already observed original physical pair,
        /// never a strip chosen by label, ordinal or an initial selected flag.
        func permitsOriginalMixerFocusTarget(_ pair: Pair) -> Bool {
            guard let retainedTrackBindings, originalHeaderFocus != nil,
                  expectedIndex == originalIndex, pair.track.matches(retainedTrackBindings[originalIndex]),
                  CFEqual(pair.strip.window, window), CFEqual(pair.strip.mixer, mixer),
                  pair.strip.document.utf8.elementsEqual(document.utf8),
                  CFEqual(associationStrip, pair.strip.strip), permitsRead(),
                  passiveStripMatches(pair.strip.strip), owned(), selectedChildCustodyMatches(),
                  (try? SessionPopulationObservation.requireOwnedAcquisition()) != nil else { return false }
            return true
        }

        /// Reverse only scroll/own-zoom values sampled immediately after our held-rail selections.
        /// A newer viewport, replacement control/path or scope loss ends cleanup authority.
        private func restoreViewport(referenceIsCurrent: @Sendable () async -> Bool,
                                     stoppingWhen stop: @Sendable () -> Bool) async -> Bool {
            guard let current = currentViewport(), Self.sameViewport(current, expectedViewport) else { return false }
            for index in viewport.indices where viewport[index].1 != expectedViewport[index].1 {
                let (control, original, _) = viewport[index]
                guard !stop(), await referenceIsCurrent(), permitsRead(),
                      (0...1).contains(original),
                      AXHelpers.isAttributeSettable(control, kAXValueAttribute as String, runtime: logic.ax) == true,
                      let decidingViewport = currentViewport(), Self.sameViewport(decidingViewport, expectedViewport),
                      permitsRead(), owned(), await referenceIsCurrent(), !stop(),
                      (try? SessionPopulationObservation.requireOwnedAcquisition()) != nil else { return false }
                // R965-VIEW-C001: the deciding AX reads can retire the request's
                // reference without changing physical custody. Renew it last,
                // then require pure acquisition/cancellation authority before writing.
                if !effects.attempted.contains("viewport") { effects.attempted.append("viewport") }
                let accepted = AXHelpers.setAttribute(control, kAXValueAttribute as String,
                    NSNumber(value: original), runtime: logic.ax)
                guard let after = currentViewport() else { return false }
                if after[index].1 == original, !effects.changed.contains("viewport") { effects.changed.append("viewport") }
                guard accepted, after[index].1 == original,
                      zip(after.indices, after).allSatisfy({ entry in
                          entry.0 == index || entry.1.1 == expectedViewport[entry.0].1
                      }), permitsRead(), owned(), !stop() else { return false }
                expectedViewport = after
            }
            return Self.sameViewport(expectedViewport, viewport)
        }

        /// Cleanup of an original passive focus is not an association challenge.
        /// Logic may restore the held selection while retaining the prior strip's
        /// focus; never publish a pair manufactured by this explicit inverse.
        private func restoreOriginalFocus(referenceIsCurrent: @Sendable () async -> Bool,
                                          stoppingWhen stop: @Sendable () -> Bool) async -> Bool {
            guard expectedIndex == originalIndex, !CFEqual(expectedFocus, originalFocus),
                  !stop(), await referenceIsCurrent(), passiveStripMatches(originalFocus),
                  let originalPath = Self.path(originalFocus, to: window, ax: logic.ax),
                  Self.same(originalPath, [originalFocus] + path),
                  AXHelpers.isAttributeSettable(originalFocus, kAXFocusedAttribute as String, runtime: logic.ax) == true,
                  let beforeViewport = currentViewport(), Self.sameViewport(beforeViewport, expectedViewport),
                  permitsRead(), !stop(), owned(),
                  // The final census may retire a reference or move focus while
                  // leaving document, population and transport intact. Renew the
                  // deciding focus, then scope and reference, after that census.
                  let decidingFocus: AXUIElement = AXHelpers.getAttribute(app,
                    kAXFocusedUIElementAttribute as String, runtime: logic.ax),
                  CFEqual(decidingFocus, expectedFocus),
                  Self.exclusiveIndex(headers, ax: logic.ax) == originalIndex,
                  let main: AXUIElement = AXHelpers.getAttribute(app, kAXMainWindowAttribute as String, runtime: logic.ax),
                  let focusedWindow: AXUIElement = AXHelpers.getAttribute(app, kAXFocusedWindowAttribute as String, runtime: logic.ax),
                  CFEqual(main, window), CFEqual(focusedWindow, window), currentWindowScopeMatches(),
                  logic.logicProPID() == pid, logic.focusedApplicationPID() == pid,
                  await referenceIsCurrent(), !stop(),
                  (try? SessionPopulationObservation.requireOwnedAcquisition()) != nil else { return false }
            if !effects.attempted.contains("keyboard_focus_restoration") {
                effects.attempted.append("keyboard_focus_restoration")
            }
            guard AXHelpers.setAttribute(originalFocus, kAXFocusedAttribute as String,
                NSNumber(value: true), runtime: logic.ax) else { return false }
            let precedingFocus = expectedFocus
            for attempt in 0..<3 {
                // As in select(), renew our observed focus before consulting
                // the passive editing guard: it still holds the preceding focus
                // until then. owned() preserves cancellation, deadline, document,
                // transport and complete population custody during this inverse.
                guard owned(),
                      let focus: AXUIElement = AXHelpers.getAttribute(app, kAXFocusedUIElementAttribute as String,
                        runtime: logic.ax) else { return false }
                if CFEqual(focus, originalFocus) {
                    guard let afterViewport = currentViewport() else { return false }
                    expectedFocus = originalFocus; expectedViewport = afterViewport
                    guard permitsRead(), !stop(), await referenceIsCurrent() else { return false }
                    if !effects.changed.contains("keyboard_focus_restoration") {
                        effects.changed.append("keyboard_focus_restoration")
                    }
                    return true
                }
                guard CFEqual(focus, precedingFocus), attempt < 2 else { lost = true; return false }
                do { try await Task.sleep(for: .milliseconds(25)) } catch { return false }
            }
            return false
        }

        /// Used only by the post-verified owned-name continuation. The new
        /// owner has kept the old native baseline; these are the existing
        /// guarded inverses, not an assumed ACK or arbitrary focus adoption.
        func restoreCommittedFocus(source: AXMixerStripBinding.Binding, expectedName: String,
                                   transport focusTransport: ExactTrackNameAdapter.NameFocusTransport?,
                                   preservingFootprint: @Sendable () -> Bool,
                                   referenceIsCurrent: @Sendable () async -> Bool,
                                   stoppingWhen stop: @Sendable () -> Bool) async -> Bool {
            guard !stop(), await referenceIsCurrent(), permitsRead() else { return false }
            if !CFEqual(expectedFocus, originalFocus) {
                guard let focusTransport, CFEqual(source.strip, originalFocus), CFEqual(source.mixer, mixer),
                      CFEqual(source.window, window), source.document.utf8.elementsEqual(document.utf8),
                      expectedSelectedChild.map({ CFEqual($0, originalFocus) }) == true,
                      passiveStripMatches(originalFocus),
                      let originalPath = Self.path(originalFocus, to: window, ax: logic.ax),
                      Self.same(originalPath, [originalFocus] + path),
                      preservingFootprint(), !stop(), await referenceIsCurrent() else { return false }
                effects.attempted.append("keyboard_focus_restoration")
                let precedingFocus = expectedFocus
                guard AccessibilityChannel.clickOriginalMixerNamePlate(source: source,
                    expectedName: expectedName, expectedFocus: precedingFocus, runtime: logic,
                    transport: focusTransport, permittingClick: {
                        !stop() && self.permitsRead() && preservingFootprint()
                            && (try? SessionPopulationObservation.requireOwnedAcquisition()) != nil
                    }) else { return false }
                // Same bounded landing observation as the existing inverse;
                // one click only, never another setter/action on a late landing.
                for attempt in 0..<3 {
                    guard owned(), let focus: AXUIElement = AXHelpers.getAttribute(app,
                        kAXFocusedUIElementAttribute as String, runtime: logic.ax) else { return false }
                    if CFEqual(focus, originalFocus) {
                        guard let afterViewport = currentViewport() else { return false }
                        expectedFocus = originalFocus; expectedViewport = afterViewport
                        guard permitsRead(), preservingFootprint(), !stop(), await referenceIsCurrent() else { return false }
                        effects.changed.append("keyboard_focus_restoration")
                        break
                    }
                    guard CFEqual(focus, precedingFocus), attempt < 2 else { lost = true; return false }
                    do { try await Task.sleep(for: .milliseconds(25)) } catch { return false }
                }
            }
            guard await restoreViewport(referenceIsCurrent: referenceIsCurrent, stoppingWhen: stop),
                  CFEqual(expectedFocus, originalFocus), permitsRead(), !stop(), await referenceIsCurrent() else { return false }
            effects.restoration = "restored"
            return true
        }

        func observe(referenceIsCurrent: @Sendable () async -> Bool,
                     stoppingWhen stop: @Sendable () -> Bool,
                     allHeldHeaders: Bool = false,
                     narrowChallengeHeaders: [AXTrackBinding.Binding] = [],
                     populationReadDuration: Duration = .zero,
                     collectionNow: @Sendable () -> ContinuousClock.Instant = { .now }) async -> [Pair] {
            let firstChallenge = headers.indices.first { index in
                guard index != originalIndex else { return false }
                return allHeldHeaders || narrowChallengeHeaders.filter { binding in
                    CFEqual(binding.header, headers[index]) && CFEqual(binding.window, window)
                        && binding.document.utf8.elementsEqual(document.utf8)
                        && binding.exposure?.hasEnded != true
                }.count == 1
            }
            guard let firstChallenge else {
                effects.reason = "association_selection_unverified"; return []
            }
            guard await referenceIsCurrent(), permitsRead(), !stop() else { return [] }
            switch selectedChildRead() {
            case .observed(let child):
                originalSelectedChild = child; expectedSelectedChild = child
                guard permitsRead(), !stop() else { return [] }
            case .unavailable: break
            case .unverified:
                effects.reason = "association_selection_unverified"; return []
            }
            let originalAssociationStrip = originalSelectedChild ?? originalFocus
            let challenges = allHeldHeaders ? headers.indices.filter { $0 != originalIndex } : [firstChallenge]
            // Whole-held pairs are optional partial observations. Do not spend
            // the entire owned deadline on more challenges: the original inverse
            // and final fresh population still need that same deadline. This is
            // not an extension or a guarantee that a busy host will restore.
            let collectionEnd: ContinuousClock.Instant?
            if allHeldHeaders, let deadline = OperationTraceContext.current?.deadline {
                let start = collectionNow()
                let remaining = start.duration(to: deadline)
                // Use the initial fresh population's observed cost, not just a
                // fraction of the deadline. With insufficient recheck time,
                // preserve the initial snapshot without starting UI navigation.
                let reserve = max(.zero, populationReadDuration) * 2
                guard remaining > reserve else { return [] }
                // An actual measured reserve already bounds the available
                // work. Keep the conservative fraction only without a sample;
                // do not truncate otherwise qualified original-header pairs.
                collectionEnd = start.advanced(by: reserve > .zero ? remaining - reserve : remaining / 4)
            } else { collectionEnd = nil }
            var observed: [(Int, AXUIElement)] = []
            var restored = true
            var selectionsVerified = true
            // An initially selected header and passive focus are not a pair
            // witness. Whole-held collection needs its own changed-strip return
            // to that header, just as it does for every challenged header.
            var originalPairVerified = !allHeldHeaders && originalRailFocus == nil
            func selectedChildRestored() -> Bool {
                guard let originalSelectedChild, let expectedSelectedChild else { return true }
                return CFEqual(originalSelectedChild, expectedSelectedChild)
            }
            for challenge in challenges {
                if let collectionEnd, collectionNow() >= collectionEnd { break }
                // select() renews selection/focus and the complete scoped
                // ownership after its deciding viewport reads and immediately
                // before the action. Do not repeat that census here.
                guard await referenceIsCurrent(), !stop() else { restored = false; break }
                let precedingStrip = associationStrip
                let advanced = await select(challenge, referenceIsCurrent: referenceIsCurrent, stoppingWhen: stop,
                    requiresNonStackHeader: !allHeldHeaders)
                let challengeStrip = associationStrip
                if allHeldHeaders {
                    guard advanced else { selectionsVerified = false; break }
                    if !CFEqual(challengeStrip, precedingStrip) {
                        // The exclusive header and a changed Mixer relationship
                        // are renewed together under full held census
                        // custody. Intermediate proofs need no inverse action.
                        observed.append((challenge, challengeStrip))
                    } else if !CFEqual(precedingStrip, originalAssociationStrip) {
                        // An unchanged relationship is not alias evidence. Challenge that
                        // header again from the original strip; if it still does
                        // not change strip, leave just this association unknown.
                        guard await referenceIsCurrent(),
                              await select(originalIndex, referenceIsCurrent: referenceIsCurrent, stoppingWhen: stop) else {
                            selectionsVerified = false; break
                        }
                        if !CFEqual(associationStrip, originalAssociationStrip) {
                            // The original selection can retain a still-owned
                            // preceding strip. That is no fresh baseline or pair
                            // proof, but it does not contradict earlier pairs.
                            originalPairVerified = false
                            continue
                        }
                        originalPairVerified = true
                        guard await referenceIsCurrent(),
                              await select(challenge, referenceIsCurrent: referenceIsCurrent, stoppingWhen: stop) else {
                            selectionsVerified = false; break
                        }
                        if !CFEqual(associationStrip, originalAssociationStrip) { observed.append((challenge, associationStrip)) }
                    }
                    continue
                }
                if expectedIndex == originalIndex {
                    restored = permitsRead() && CFEqual(expectedFocus, originalFocus) && selectedChildRestored()
                } else if await referenceIsCurrent() {
                    restored = await select(originalIndex, referenceIsCurrent: referenceIsCurrent, stoppingWhen: stop)
                        && CFEqual(expectedFocus, originalFocus) && selectedChildRestored()
                } else { restored = false }
                if !restored, !lost, expectedIndex == originalIndex, selectedChildRestored() {
                    // As in whole-held collection, restore only our original
                    // passive focus; the inverse itself is never a pair witness.
                    if originalSelectedChild == nil { originalPairVerified = false }
                    restored = await restoreOriginalFocus(referenceIsCurrent: referenceIsCurrent, stoppingWhen: stop)
                        && selectedChildRestored()
                }
                // Each proof starts at the same original selection/focus. A
                // previous challenge's passive focus cannot identify this header.
                guard restored else { break }
                guard advanced, !CFEqual(challengeStrip, originalAssociationStrip) else {
                    selectionsVerified = false; break
                }
                // A passive rail's selected-child hint becomes a pair only
                // after this actual changed-strip challenge and exact return.
                if originalSelectedChild != nil, CFEqual(associationStrip, originalAssociationStrip) {
                    originalPairVerified = true
                }
                observed.append((challenge, challengeStrip))
            }
            if allHeldHeaders {
                if expectedIndex == originalIndex {
                    restored = permitsRead() && CFEqual(expectedFocus, originalFocus) && selectedChildRestored()
                } else if await referenceIsCurrent() {
                    let precedingStrip = associationStrip
                    let returned = await select(originalIndex, referenceIsCurrent: referenceIsCurrent, stoppingWhen: stop)
                    if returned, CFEqual(associationStrip, originalAssociationStrip),
                       !CFEqual(precedingStrip, originalAssociationStrip) { originalPairVerified = true }
                    restored = returned && CFEqual(expectedFocus, originalFocus) && selectedChildRestored()
                } else { restored = false }
                if !restored, !lost, expectedIndex == originalIndex {
                    if originalSelectedChild == nil { originalPairVerified = false }
                    restored = await restoreOriginalFocus(referenceIsCurrent: referenceIsCurrent, stoppingWhen: stop)
                        && selectedChildRestored()
                }
            }
            let inverseVerified: Bool
            if restored { inverseVerified = await restoreViewport(referenceIsCurrent: referenceIsCurrent, stoppingWhen: stop) }
            else { inverseVerified = false }
            let sampledViewport = currentViewport()
            let viewRestored = inverseVerified && (sampledViewport.map { values in
                Self.sameViewport(values, viewport)
            } ?? false)
            guard restored, viewRestored, await referenceIsCurrent(), permitsRead(), !stop() else {
                effects.reason = "association_restoration_unverified"; return []
            }
            effects.restoration = "restored"
            guard selectionsVerified, !observed.isEmpty else {
                effects.reason = "association_selection_unverified"; return []
            }
            // A narrow challenge corroborates the requested selection; it does
            // not authorize later routing acquisition on that unselected peer.
            return ((allHeldHeaders ? observed : []) + (originalPairVerified ? [(originalIndex, originalAssociationStrip)] : [])).map { index, strip in
                Pair(track: retainedTrackBindings?[index]
                        ?? .init(window: window, header: headers[index], document: document, runtime: logic),
                     strip: .init(window: window, mixer: mixer, strip: strip, document: document),
                     source: originalSelectedChild == nil ? "held_exclusive_selection_focus" : "held_exclusive_selection_selected_child")
            }
        }
    }
}
