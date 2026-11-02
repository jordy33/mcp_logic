@preconcurrency import ApplicationServices
import Foundation
import Testing
@testable import LogicProMCP

/// Detached Mixer window lookup — `docs/tickets/detached-mixer-window-lookup.md`.
///
/// Measured 2026-10-30 on Logic 12.4: with `Window > Open Mixer` open, the Mixer lives in its own
/// `AXWindow` ("… - Mixer: All"), the arrange window contains zero Mixer containers, and the same
/// Stereo Out strip names an occupied insert "Channel EQ" in the detached window while the docked
/// pane says "audio plug-in". These fixtures model that shape: an arrange window with a track
/// header rail and no Mixer, and a detached window that holds the Mixer.
private final class DetachedMixerFixture: @unchecked Sendable {
    let builder = FakeAXRuntimeBuilder()
    let app: AXUIElement
    let arrange: AXUIElement
    let detached: AXUIElement
    let detachedMixer: AXUIElement
    /// The detached Mixer's strips: `Track 1`, then the occupied `Stereo Out`.
    let detachedStrips: [AXUIElement]
    /// The docked Mixer inside the arrange window, when this fixture models `View > Show Mixer`.
    let dockedMixer: AXUIElement?

    init(docked: Bool, detachedOpen: Bool = true) {
        let b = builder
        app = b.element(32000)
        arrange = b.element(32001)
        detached = b.element(32002)
        b.setAttribute(app, kAXWindowsAttribute as String,
                       detachedOpen ? [arrange, detached] : [arrange])
        b.setAttribute(app, kAXMainWindowAttribute as String, arrange)

        let detachedOuter = b.element(32003)
        detachedMixer = b.element(32004)
        detachedStrips = [
            Self.strip(b, id: 32200, name: "Track 1", slotName: nil, occupied: false),
            Self.strip(b, id: 32300, name: "Stereo Out", slotName: "Channel EQ", occupied: true),
        ]
        b.setAttribute(detached, kAXRoleAttribute as String, kAXWindowRole as String)
        b.setAttribute(detached, kAXSubroleAttribute as String, "AXFloatingWindow")
        b.setAttribute(detached, kAXTitleAttribute as String, "Fixture - Mixer: All")
        b.setAttribute(detachedMixer, kAXRoleAttribute as String, kAXLayoutAreaRole as String)
        b.setAttribute(detachedMixer, kAXDescriptionAttribute as String, "Mixer")
        b.setChildren(detachedMixer, detachedStrips)
        b.setAttribute(detachedOuter, kAXRoleAttribute as String, kAXGroupRole as String)
        b.setAttribute(detachedOuter, kAXDescriptionAttribute as String, "Mixer")
        b.setChildren(detachedOuter, [detachedMixer])
        b.setChildren(detached, [detachedOuter])

        if docked {
            let outer = b.element(32005)
            let inner = b.element(32006)
            let strips = [
                Self.strip(b, id: 32400, name: "Track 1", slotName: nil, occupied: false),
                Self.strip(b, id: 32500, name: "Stereo Out", slotName: "audio plug-in", occupied: true),
            ]
            b.setAttribute(inner, kAXRoleAttribute as String, kAXLayoutAreaRole as String)
            b.setAttribute(inner, kAXDescriptionAttribute as String, "Mixer")
            b.setChildren(inner, strips)
            b.setAttribute(outer, kAXRoleAttribute as String, kAXGroupRole as String)
            b.setAttribute(outer, kAXDescriptionAttribute as String, "Mixer")
            b.setChildren(outer, [inner])
            b.setChildren(arrange, [outer])
            dockedMixer = inner
        } else {
            dockedMixer = nil
        }
        // Gives the arrange window its track-header rail, so it is not mistaken for a detached one.
        // The strip is a throwaway: this helper only needs one to hang a name field on.
        addPluginTrackAssociation(
            b, window: arrange,
            strip: Self.strip(b, id: 32600, name: "Track 1", slotName: nil, occupied: false),
            name: "Track 1"
        )
    }

    var runtime: AXLogicProElements.Runtime {
        builder.makeLogicRuntime(appElement: app)
    }

    func inventory(
        params: [String: String],
        revealMixer: AccessibilityChannel.MixerRevealAction = { _ in
            Issue.record("the detached Mixer is open; no reveal may actuate")
            return (nil, AccessibilityChannel.MixerRevealResult(
                attempted: false, alreadyVisible: false, strategies: [], menuItemFound: false,
                menuClicked: false, keySent: false, mixerVisible: false))
        },
        revealDetachedMixer: AccessibilityChannel.MixerRevealAction = { _ in
            Issue.record("the detached Mixer is open; no detached reveal may actuate")
            return (nil, AccessibilityChannel.MixerRevealResult(
                attempted: false, alreadyVisible: false, strategies: [], menuItemFound: false,
                menuClicked: false, keySent: false, mixerVisible: false))
        }
    ) async -> ChannelResult {
        await AccessibilityChannel.defaultGetPluginInventory(
            params: params, runtime: runtime,
            revealMixer: revealMixer,
            revealDetachedMixer: revealDetachedMixer
        )
    }

    /// One AXLayoutItem strip with a name field and exactly one insert row: empty when
    /// `occupied` is false, otherwise an occupied group whose description is `slotName`.
    private static func strip(
        _ b: FakeAXRuntimeBuilder, id: Int, name: String, slotName: String?, occupied: Bool
    ) -> AXUIElement {
        let strip = b.element(id)
        let field = b.element(id + 1)
        b.setAttribute(strip, kAXRoleAttribute as String, kAXLayoutItemRole as String)
        b.setAttribute(strip, kAXDescriptionAttribute as String, "1008 40 \(name)")
        b.setAttribute(field, kAXRoleAttribute as String, kAXTextFieldRole as String)
        b.setAttribute(field, kAXDescriptionAttribute as String, "Name")
        b.setAttribute(field, kAXValueAttribute as String, name)

        let slot: AXUIElement
        if occupied, let slotName {
            let group = b.element(id + 2)
            let bypass = b.element(id + 3)
            let open = b.element(id + 4)
            b.setAttribute(group, kAXRoleAttribute as String, kAXGroupRole as String)
            b.setAttribute(group, kAXDescriptionAttribute as String, slotName)
            b.setAttribute(bypass, kAXRoleAttribute as String, kAXCheckBoxRole as String)
            b.setAttribute(bypass, kAXDescriptionAttribute as String, "Bypass")
            b.setAttribute(bypass, kAXValueAttribute as String, 0)
            b.setAttribute(open, kAXRoleAttribute as String, kAXButtonRole as String)
            b.setAttribute(open, kAXDescriptionAttribute as String, "Open")
            b.setChildren(group, [bypass, open])
            b.setFrame(group, x: 100, y: 210, width: 120, height: 18)
            slot = group
        } else {
            let button = b.element(id + 2)
            b.setAttribute(button, kAXRoleAttribute as String, kAXButtonRole as String)
            b.setAttribute(button, kAXDescriptionAttribute as String, slotName ?? "audio plug-in")
            b.setAttribute(button, kAXHelpAttribute as String,
                           "Audio Effect slot. Insert an audio effect.")
            b.setFrame(button, x: 100, y: 210, width: 120, height: 18)
            slot = button
        }
        b.setChildren(strip, [field, slot])
        return strip
    }
}

/// Records what the reveal's actuators were asked to do, from a `@Sendable` closure.
private final class KeyRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [(code: CGKeyCode, flags: CGEventFlags, pid: pid_t)] = []
    func post(_ code: CGKeyCode, _ flags: CGEventFlags, _ pid: pid_t) -> Bool {
        lock.lock(); recorded.append((code, flags, pid)); lock.unlock()
        return true
    }
    var entries: [(code: CGKeyCode, flags: CGEventFlags, pid: pid_t)] {
        lock.lock(); defer { lock.unlock() }; return recorded
    }
}

private func revealActuators(_ recorder: KeyRecorder) -> AccessibilityChannel.MenuClickActuators {
    .init(activateLogic: { true },
          postKeyEvent: { recorder.post($0, $1, $2) },
          pressEscape: {},
          raiseMixerWindow: { true })
}

/// Counts calls made from a `@Sendable` reveal action.
private actor CallCounter {
    private(set) var count = 0
    var value: Int { count }
    func increment() { count += 1 }
}

private func inventoryBody(_ result: ChannelResult) throws -> [String: Any] {
    let data = Data(result.message.utf8)
    return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
}

@Suite("Detached Mixer window — the Mixer is searchable outside the arrange window")
struct DetachedMixerWindowLookupTests {
    /// Acceptance 1/7: with only a detached Mixer open, the lookup must find it. Restoring the
    /// `mainWindow()`-only search turns this red.
    @Test("the Mixer is found in a detached window, not only inside the arrange window")
    func detachedMixerIsFoundOutsideArrangeWindow() throws {
        let f = DetachedMixerFixture(docked: false)
        let found = try #require(AXLogicProElements.mixerAreaLookup(runtime: f.runtime).mixer)
        #expect(CFEqual(found, f.detachedMixer),
                "the detached Mixer, not the arrange window's (absent) pane")
        #expect(AXLogicProElements.getMixerArea(runtime: f.runtime) != nil)
    }

    @Test("the lookup names the window and its placement")
    func lookupNamesItsWindow() throws {
        let f = DetachedMixerFixture(docked: false)
        let resolution = AXLogicProElements.mixerWindowLookup(runtime: f.runtime)
        #expect(CFEqual(try #require(resolution.mixer), f.detachedMixer))
        let window = try #require(resolution.window, "the lookup names the window it found")
        #expect(CFEqual(window, f.detached))
        #expect(resolution.title == "Fixture - Mixer: All")
        #expect(resolution.placement == .detached)
    }

    /// Acceptance 4: with both representations open, the preference decides and the choice is
    /// named; `docked` still binds the arrange pane.
    @Test("preference chooses between the detached window and the docked pane")
    func preferenceChoosesTheWindow() throws {
        let f = DetachedMixerFixture(docked: true)
        let auto = AXLogicProElements.mixerWindowLookup(runtime: f.runtime)
        #expect(auto.placement == .detached)
        #expect(CFEqual(try #require(auto.mixer), f.detachedMixer))

        let dockedOnly = AXLogicProElements.mixerWindowLookup(runtime: f.runtime, preference: .docked)
        #expect(dockedOnly.placement == .docked)
        #expect(CFEqual(try #require(dockedOnly.mixer), try #require(f.dockedMixer)))

        let detachedOnly = AXLogicProElements.mixerWindowLookup(runtime: f.runtime, preference: .detached)
        #expect(CFEqual(try #require(detachedOnly.mixer), f.detachedMixer))
    }

    /// Acceptance 1/6: the inventory's first step binds the detached Mixer, so no reveal runs.
    @Test("the inventory preflight finds the detached Mixer without actuating")
    func preflightBindsDetachedMixer() throws {
        let f = DetachedMixerFixture(docked: false)
        let observed = try #require(AccessibilityChannel.mixerWindowWithoutReveal(runtime: f.runtime))
        #expect(observed.result.alreadyVisible)
        #expect(observed.resolution.placement == .detached)
        #expect(CFEqual(try #require(observed.resolution.mixer), f.detachedMixer))
    }

    /// Acceptance 1: with only a detached Mixer open, `strip:"output"` names the occupied insert
    /// from the representation that actually carries it.
    @Test("get_inventory reads Channel EQ from the detached window and names that window")
    func inventoryReadsOccupiedInsertFromDetachedWindow() async throws {
        let f = DetachedMixerFixture(docked: false)
        let object = try inventoryBody(await f.inventory(params: ["strip": "output"]))
        #expect(object["state"] as? String == "A")
        #expect(object["track_name"] as? String == "Stereo Out")
        #expect(object["mixer_window"] as? String == "detached")
        #expect(object["mixer_window_title"] as? String == "Fixture - Mixer: All")
        let plugins = try #require(object["plugins"] as? [[String: Any]])
        #expect(plugins.first?["name"] as? String == "Channel EQ")
    }

    /// Acceptance 2/3: with both windows open, `auto` binds the detached representation; an
    /// explicit `docked` keeps the measured generic-name limitation rather than pretending it is
    /// fixed, and `detached` with no detached window fails closed instead of borrowing the pane.
    @Test("with both windows open, auto names the insert and docked stays generic")
    func bothWindowsAutoPrefersDetached() async throws {
        let both = DetachedMixerFixture(docked: true)
        let auto = try inventoryBody(await both.inventory(params: ["strip": "output"]))
        #expect(auto["state"] as? String == "A")
        #expect(auto["mixer_window"] as? String == "detached")
        let plugins = try #require(auto["plugins"] as? [[String: Any]])
        #expect(plugins.first?["name"] as? String == "Channel EQ")

        let docked = try inventoryBody(await both.inventory(params: [
            "strip": "output", "mixer_window": "docked",
        ]))
        #expect(docked["state"] as? String == "B")
        #expect(docked["plugins_unknown_reason"] as? String == "occupied_insert_name_unreadable")
        #expect(docked["mixer_window"] as? String == "docked")

        let closed = DetachedMixerFixture(docked: true, detachedOpen: false)
        let refused = try inventoryBody(await closed.inventory(params: [
            "strip": "output", "mixer_window": "detached",
        ]))
        #expect(refused["state"] as? String == "B")
        #expect(refused["plugins_unknown_reason"] as? String == "detached_mixer_not_visible")
        #expect(refused["mixer_window"] as? String == "detached")
    }

    /// The detached window is preferred, but not at the cost of the target: when it does not carry
    /// the requested track, the docked pane must answer instead of the read failing.
    @Test("a detached Mixer without the target track does not shadow the docked pane")
    func detachedMixerWithoutTheTargetFallsBackToDocked() async throws {
        let f = DetachedMixerFixture(docked: true)
        // The detached window keeps only Stereo Out; the arrange's docked pane has Track 1.
        f.builder.setChildren(f.detachedMixer, [f.detachedStrips[1]])
        let object = try inventoryBody(await f.inventory(params: ["track": "0"]))
        #expect(object["state"] as? String == "A")
        #expect(object["track_name"] as? String == "Track 1")
        #expect(object["mixer_window"] as? String == "docked")
    }

    /// `View > Show Mixer` cannot serve a `detached` request, and before this change nothing in the
    /// server opened the window either: the only way in was for an operator to press
    /// `Window > Open Mixer` by hand. An explicit detached request with `reveal_mixer:true` now
    /// takes the Window-menu path, and when the window does not appear it still fails closed
    /// instead of borrowing the docked pane.
    @Test("a detached request with reveal takes Window > Open Mixer, not View > Show Mixer")
    func detachedRevealTakesTheWindowMenuPath() async throws {
        let f = DetachedMixerFixture(docked: true, detachedOpen: false)
        let calls = CallCounter()
        let object = try inventoryBody(await f.inventory(
            params: ["strip": "output", "mixer_window": "detached", "reveal_mixer": "true"],
            revealMixer: { _ in
                Issue.record("a detached request must not reveal the docked pane")
                return (nil, .notRevealed())
            },
            revealDetachedMixer: { _ in
                await calls.increment()
                return (nil, AccessibilityChannel.MixerRevealResult(
                    attempted: true, alreadyVisible: false,
                    strategies: ["cgevent_cmd2_open_mixer"], menuItemFound: false,
                    menuClicked: false, keySent: true, mixerVisible: false))
            }
        ))
        let callCount = await calls.value
        #expect(callCount == 1)
        #expect(object["state"] as? String == "B")
        #expect(object["plugins_unknown_reason"] as? String == "detached_mixer_not_visible")
        let strategies = try #require(object["mixer_reveal_strategies"] as? [String])
        #expect(strategies == ["cgevent_cmd2_open_mixer"])
    }

    /// The accelerator is the one the opened Window menu reports for `Open Mixer`:
    /// `AXMenuItemCmdChar: 2`, `AXMenuItemCmdModifiers: 0`, measured 2026-11-02 — ⌘2, not a bare
    /// `2`. A bare key here would type into whatever has focus.
    @Test("the detached reveal sends ⌘2 and reports the window it could not open")
    func detachedRevealSendsCommandTwo() async {
        let f = DetachedMixerFixture(docked: false, detachedOpen: false)
        let recorder = KeyRecorder()
        let (mixer, result) = await AccessibilityChannel.ensureDetachedMixerWindowForInventory(
            runtime: f.runtime, actuators: revealActuators(recorder)
        )
        #expect(mixer == nil)
        let sent = recorder.entries
        #expect(sent.count == 1)
        #expect(sent.first?.code == 19, "kVK_ANSI_2")
        #expect(sent.first?.flags.contains(.maskCommand) == true)
        #expect(sent.first?.pid == 4242, "the fixture's Logic pid, not the server's own")
        #expect(result.attempted)
        #expect(result.keySent)
        #expect(!result.mixerVisible)
        #expect(result.strategies == ["cgevent_cmd2_open_mixer"])
    }

    /// Nothing is sent when the window is already there, and nothing is sent when Logic's windows
    /// cannot be observed: an unknown window never authorizes an actuation.
    @Test("the detached reveal sends no key when the window is open or unobservable")
    func detachedRevealSendsNoKeyWithoutADefiniteAbsence() async {
        let open = DetachedMixerFixture(docked: false)
        let openRecorder = KeyRecorder()
        let (openMixer, openResult) = await AccessibilityChannel.ensureDetachedMixerWindowForInventory(
            runtime: open.runtime, actuators: revealActuators(openRecorder)
        )
        #expect(openMixer != nil)
        #expect(openResult.alreadyVisible)
        #expect(openRecorder.entries.isEmpty)

        // No observable arrange window: the reveal refuses before any actuation.
        let blocked = DetachedMixerFixture(docked: false, detachedOpen: false)
        blocked.builder.setAttribute(blocked.app, kAXWindowsAttribute as String, [])
        let blockedRecorder = KeyRecorder()
        let (blockedMixer, blockedResult) = await AccessibilityChannel.ensureDetachedMixerWindowForInventory(
            runtime: blocked.runtime, actuators: revealActuators(blockedRecorder)
        )
        #expect(blockedMixer == nil)
        #expect(blockedResult.windowUnavailable)
        #expect(blockedRecorder.entries.isEmpty)
    }

    /// The mirror image: a docked request (or any non-detached one) must never open the second
    /// window. Opening a window the caller did not ask for changes the operator's workspace.
    @Test("a docked request never opens the detached window")
    func dockedRevealNeverOpensTheDetachedWindow() async throws {
        let f = DetachedMixerFixture(docked: false, detachedOpen: false)
        let object = try inventoryBody(await f.inventory(
            params: ["strip": "output", "mixer_window": "docked", "reveal_mixer": "true"],
            revealMixer: { _ in
                (nil, AccessibilityChannel.MixerRevealResult(
                    attempted: true, alreadyVisible: false,
                    strategies: ["ax_menu_view_show_mixer"], menuItemFound: true,
                    menuClicked: true, keySent: false, mixerVisible: false))
            },
            revealDetachedMixer: { _ in
                Issue.record("a docked request must not press Window > Open Mixer")
                return (nil, .notRevealed())
            }
        ))
        #expect(object["state"] as? String == "B")
        let strategies = try #require(object["mixer_reveal_strategies"] as? [String])
        #expect(strategies == ["ax_menu_view_show_mixer"])
    }

    /// Acceptance 7: the mutation this suite is built to catch — restoring the arrange-window-only
    /// search — makes `detachedMixerIsFoundOutsideArrangeWindow` and every inventory test red.
    @Test("with no Mixer anywhere, the lookup still fails closed")
    func noMixerAnywhereIsNotFound() {
        let f = DetachedMixerFixture(docked: false, detachedOpen: true)
        // Remove the detached window's contents: what remains is an arrange window with no Mixer.
        f.builder.setChildren(f.detached, [])
        let resolution = AXLogicProElements.mixerWindowLookup(runtime: f.runtime)
        #expect(resolution.mixer == nil)
        #expect(resolution.placement == nil)
        #expect(!AXLogicProElements.mixerAreaLookup(runtime: f.runtime).childrenUnread)
    }
}
