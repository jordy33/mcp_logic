@preconcurrency import ApplicationServices
import Foundation

/// Process-local continuity for an already complete request-owned track
/// observation and its actual issuance-time bindings. This does not establish
/// completeness, reconstruct custody from wire rows, or renew retired headers.
@MainActor
final class MIDITrackNativeHold {
    private struct Frame {
        let pid: pid_t
        let app: AXUIElement
        let window: AXUIElement
        let document: String
        let rail: AXUIElement
        let headers: [AXUIElement]

        func matches(_ other: Frame) -> Bool {
            pid == other.pid && CFEqual(app, other.app) && CFEqual(window, other.window)
                && document.utf8.elementsEqual(other.document.utf8) && CFEqual(rail, other.rail)
                && headers.count == other.headers.count
                && zip(headers, other.headers).allSatisfy { CFEqual($0, $1) }
        }
    }

    private let observation: MIDITrackFileExport.Observation
    private let runtime: AXLogicProElements.Runtime
    private let permittingRead: @MainActor () -> Bool
    private let frame: Frame
    private let bindings: [AXTrackBinding.Binding]
    private var ended = false

    init?(observation: MIDITrackFileExport.Observation, bindings: [AXTrackBinding.Binding],
          runtime: AXLogicProElements.Runtime = .production,
          permittingRead: @escaping @MainActor () -> Bool = {
              (try? SessionPopulationObservation.requireOwnedAcquisition()) != nil
          }) {
        guard observation.coverage == .complete, observation.projectReference != nil,
              !observation.tracks.isEmpty,
              let frame = Self.read(observation: observation, runtime: runtime, permittingRead: permittingRead),
              let repeated = Self.read(observation: observation, runtime: runtime, permittingRead: permittingRead),
              frame.matches(repeated), Self.bindingsMatch(bindings, frame: frame), permittingRead() else { return nil }
        self.observation = observation; self.runtime = runtime
        self.permittingRead = permittingRead; self.frame = frame; self.bindings = bindings
    }

    func isCurrent() -> Bool {
        guard !ended else { return false }
        guard let current = Self.read(observation: observation, runtime: runtime, permittingRead: permittingRead),
              frame.matches(current), Self.bindingsMatch(bindings, frame: current), permittingRead() else {
            ended = true
            return false
        }
        return true
    }

    private static func bindingsMatch(_ bindings: [AXTrackBinding.Binding], frame: Frame) -> Bool {
        bindings.count == frame.headers.count && zip(bindings, frame.headers).allSatisfy { binding, header in
            CFEqual(binding.window, frame.window) && CFEqual(binding.header, header)
                && binding.document.utf8.elementsEqual(frame.document.utf8)
                && binding.projectPath != nil && (binding.exposure?.isCurrent ?? true)
        }
    }

    private static func read(observation: MIDITrackFileExport.Observation, runtime: AXLogicProElements.Runtime,
                             permittingRead: @MainActor () -> Bool) -> Frame? {
        guard permittingRead(), let pid = runtime.logicProPID(),
              let app = AXLogicProElements.appRoot(runtime: runtime),
              let window = mainWindow(app: app, ax: runtime.ax),
              case .success(.some(let document)) = AXLogicProElements.projectPickerDocumentRead(window, runtime: runtime),
              let documentURL = URL(string: document), documentURL.isFileURL,
              documentURL.host == nil || documentURL.host == "" || documentURL.host == "localhost",
              SessionPopulationObservation.sameBundle(documentURL, cachedPath: observation.projectPath),
              case .success(.elements(let windows)) = AXHelpers.getAXUIElementArrayRead(app, kAXWindowsAttribute as String, runtime: runtime.ax),
              windows.filter({ CFEqual($0, window) }).count == 1,
              permittingRead(),
              let rail = AXLogicProElements.uniqueTrackHeaderRail(in: window, runtime: runtime),
              case .read(let headers) = AXLogicProElements.enumerateTrackHeaderRows(in: rail, runtime: runtime.ax),
              headers.count == observation.tracks.count else { return nil }
        for (index, header) in headers.enumerated() {
            guard permittingRead(), !headers.prefix(index).contains(where: { CFEqual($0, header) }),
                  case .success(.some(let name)) = AXValueExtractors.extractTrackNameResult(from: header, runtime: runtime.ax),
                  name.utf8.elementsEqual(observation.tracks[index].name.utf8) else { return nil }
        }
        guard permittingRead(), runtime.logicProPID() == pid,
              AXLogicProElements.appRoot(runtime: runtime).map({ CFEqual($0, app) }) == true,
              mainWindow(app: app, ax: runtime.ax).map({ CFEqual($0, window) }) == true,
              case .success(.some(let afterDocument)) = AXLogicProElements.projectPickerDocumentRead(window, runtime: runtime),
              document.utf8.elementsEqual(afterDocument.utf8), permittingRead() else { return nil }
        return Frame(pid: pid, app: app, window: window, document: document, rail: rail, headers: headers)
    }

    private static func mainWindow(app: AXUIElement, ax: AXHelpers.Runtime) -> AXUIElement? {
        let raw: Result<AnyObject?, AXHelpers.AXStatusError> = AXHelpers.getAttributeResult(
            app, kAXMainWindowAttribute as String, runtime: ax)
        guard case .success(.some(let value)) = raw, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return unsafeDowncast(value, to: AXUIElement.self)
    }
}
