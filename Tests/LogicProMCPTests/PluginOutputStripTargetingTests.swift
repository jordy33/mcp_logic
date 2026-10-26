@preconcurrency import ApplicationServices
import Foundation
import Testing
@testable import LogicProMCP

// T2 — the master Stereo Output strip is addressed by `strip:"output"`, not by an Arrange index.
//
// The evidence these fixtures model is the live Mixer dump in
// docs/tickets/issue-234/axdump234b.out (2026-07-04): a strip whose name field reads
// `Stereo Out` carrying an `audio plug-in` insert row, beside a `Master` strip that carries
// none. Every test here is about refusing to guess when that shape is not exactly present.

private final class OutputStripFixture: @unchecked Sendable {
    let builder = FakeAXRuntimeBuilder()
    let app: AXUIElement
    let window: AXUIElement
    let mixer: AXUIElement
    let strips: [AXUIElement]

    /// `slots` is the number of EMPTY audio-plugin insert rows per strip, in strip order.
    init(stripNames: [String], slots: [Int]? = nil) {
        let b = builder
        let slotCounts = slots ?? Array(repeating: 0, count: stripNames.count)
        app = b.element(31000)
        window = b.element(31001)
        mixer = b.element(31002)
        b.setAttribute(window, kAXRoleAttribute as String, kAXWindowRole as String)
        b.setAttribute(mixer, kAXRoleAttribute as String, kAXLayoutAreaRole as String)
        b.setAttribute(mixer, kAXDescriptionAttribute as String, "Mixer")
        b.setAttribute(app, kAXWindowsAttribute as String, [window])
        b.setAttribute(app, kAXMainWindowAttribute as String, window)
        strips = stripNames.enumerated().map { index, name in
            let strip = b.element(31100 + index * 100)
            let field = b.element(31101 + index * 100)
            b.setAttribute(strip, kAXRoleAttribute as String, kAXLayoutItemRole as String)
            b.setAttribute(strip, kAXDescriptionAttribute as String, "1008 40 \(index)")
            b.setAttribute(field, kAXRoleAttribute as String, kAXTextFieldRole as String)
            b.setAttribute(field, kAXDescriptionAttribute as String, "이름")
            b.setAttribute(field, kAXValueAttribute as String, name)
            var children: [AXUIElement] = [field]
            for slot in 0..<slotCounts[index] {
                let element = b.element(31110 + index * 100 + slot)
                b.setAttribute(element, kAXRoleAttribute as String, kAXButtonRole as String)
                b.setAttribute(element, kAXDescriptionAttribute as String, "audio plug-in")
                b.setAttribute(element, kAXHelpAttribute as String,
                               "Audio Effect slot. Insert an audio effect.")
                // Two or more slots are put in screen order, so each one needs a real frame and
                // its own row: a strip whose slots have no frame is `unclassified`, not empty.
                b.setFrame(element, x: 100, y: CGFloat(100 + slot * 20), width: 120, height: 18)
                children.append(element)
            }
            b.setChildren(strip, children)
            return strip
        }
        b.setChildren(mixer, strips)
        b.setChildren(window, [mixer])
    }

    var runtime: AXLogicProElements.Runtime { builder.makeLogicRuntime(appElement: app) }

    func inventory(params: [String: String]) async -> ChannelResult {
        await AccessibilityChannel.defaultGetPluginInventory(
            params: params, runtime: runtime,
            revealMixer: { _ in (self.mixer, .alreadyVisible) }
        )
    }
}

private func body(_ result: ChannelResult) throws -> [String: Any] {
    let data = Data(result.message.utf8)
    return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
}

@Test("the output strip resolves by its measured name and its insert section, not by an index")
func outputStripResolvesWithoutAnArrangeIndex() throws {
    let f = OutputStripFixture(stripNames: ["Track 1", "Stereo Out", "Master"], slots: [0, 1, 0])
    var refusal: String?
    let binding = try #require(AXPluginTrackBinding.resolveOutputStrip(
        mixer: f.mixer, runtime: f.runtime, onRefusal: { refusal = $0 }))
    #expect(refusal == nil)
    #expect(binding.trackIndex == nil, "the master strip has no Arrange index to borrow")
    #expect(binding.mixerStripIndex == 1)
    #expect(binding.trackName == "Stereo Out")
    #expect(AXPluginTrackBinding.isStable(binding, runtime: f.runtime))
}

@Test("the Master strip is not the output strip: it has no insert section")
func masterStripWithoutInsertsIsRefused() throws {
    let f = OutputStripFixture(stripNames: ["Track 1", "Master"], slots: [0, 0])
    var refusal: String?
    #expect(AXPluginTrackBinding.resolveOutputStrip(
        mixer: f.mixer, runtime: f.runtime, onRefusal: { refusal = $0 }) == nil)
    #expect(refusal == "output_strip_absent")
}

@Test("an insert-less strip named Stereo Out is refused rather than reported as an empty chain")
func outputStripWithoutInsertSectionIsRefused() throws {
    let f = OutputStripFixture(stripNames: ["Track 1", "Stereo Out"], slots: [0, 0])
    var refusal: String?
    #expect(AXPluginTrackBinding.resolveOutputStrip(
        mixer: f.mixer, runtime: f.runtime, onRefusal: { refusal = $0 }) == nil)
    #expect(refusal == "output_strip_insert_section_unavailable")
}

@Test("two strips with the measured name are ambiguous, never 'the last one in the list'")
func duplicateOutputStripNameIsRefused() throws {
    let f = OutputStripFixture(stripNames: ["Stereo Out", "Stereo Out"], slots: [1, 1])
    var refusal: String?
    #expect(AXPluginTrackBinding.resolveOutputStrip(
        mixer: f.mixer, runtime: f.runtime, onRefusal: { refusal = $0 }) == nil)
    #expect(refusal == "output_strip_name_not_unique")
}

@Test("get_inventory strip:\"output\" names the strip it read and never borrows track 0")
func inventoryOnOutputStripNamesItsTarget() async throws {
    let f = OutputStripFixture(stripNames: ["Track 1", "Stereo Out", "Master"], slots: [0, 2, 0])
    let result = await f.inventory(params: ["strip": "output"])
    #expect(result.isSuccess)
    let object = try body(result)
    #expect(object["state"] as? String == "A")
    #expect(object["strip"] as? String == "output")
    #expect(object["track"] is NSNull, "a null track cannot be misread as track 0")
    #expect(object["track_name"] as? String == "Stereo Out")
    let plugins = try #require(object["plugins"] as? [[String: Any]])
    #expect(plugins.count == 2)
}

@Test("get_inventory refuses two selectors and any strip other than \"output\"")
func inventorySelectorExclusivity() async throws {
    let f = OutputStripFixture(stripNames: ["Track 1", "Stereo Out"], slots: [0, 1])

    let both = try body(await f.inventory(params: ["strip": "output", "track": "0"]))
    #expect(both["state"] as? String == "C")
    #expect(both["error"] as? String == "invalid_params")

    let master = try body(await f.inventory(params: ["strip": "master"]))
    #expect(master["state"] as? String == "C")
    #expect(master["error"] as? String == "invalid_params")

    let neither = try body(await f.inventory(params: [:]))
    #expect(neither["state"] as? String == "C")
    #expect(neither["error"] as? String == "invalid_params")
}

@Test("insert_verified refuses strip:\"output\" together with a track before any AX access")
func insertVerifiedRefusesBothSelectors() async throws {
    let f = OutputStripFixture(stripNames: ["Track 1", "Stereo Out"], slots: [0, 1])
    let result = await AccessibilityChannel.defaultInsertVerified(
        params: ["strip": "output", "track": "0", "insert": "0", "plugin": "Gain",
                 "mode": "duplicate_applyback", "project_expected_path": "/tmp/x.logicx"],
        runtime: f.runtime,
        frontDocumentPath: { "/tmp/x.logicx" },
        insertDriver: { _, _, _, _, _ in (.transientSetupFailure(stage: "unexpected"), [:]) },
        rollback: { _, _, _, _ in
            AccessibilityChannel.RollbackResult(attempted: false, succeeded: false, retries: 0, lastClickResult: "unexpected")
        }
    )
    let object = try body(result)
    #expect(object["state"] as? String == "C")
    #expect(object["error"] as? String == "invalid_params")
    #expect(object["write_attempted"] as? Bool == false)
}
