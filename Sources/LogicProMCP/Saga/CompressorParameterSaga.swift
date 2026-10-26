import Foundation
import MCP

/// The selected two-control adapter, not a second execution engine. Its params
/// and occupied insert ref are part of the existing canonical Saga/journal hash.
enum CompressorParameterSaga {
    #if DEBUG
    @TaskLocal static var testStepSeconds: Double?
    #endif
    static let pluginID = "logic.stock.effect.compressor"
    static let stepSeconds = DeadlineClass.short.seconds

    static func containsPluginSteps(_ plan: SagaPlan) -> Bool {
        plan.steps.contains { $0.operationID == .pluginsSetParamVerified }
    }

    static func canonicalParams(_ params: [String: Value]) throws -> [String: Value] {
        guard Set(params.keys) == ["param", "unit", "value", "expected_before"],
              let param = params["param"]?.stringValue, let unit = params["unit"]?.stringValue,
              let requested = params["value"], let before = params["expected_before"],
              let metadata = VerifiedPluginCatalog.productionEntryLookup(pluginID)?.parameters.first(where: { $0.id == param }) else {
            throw SagaWireError.invalid("Compressor steps require only param, unit, value and expected_before")
        }
        switch param {
        case "threshold":
            guard unit == metadata.unit || metadata.acceptedUnits?.contains(unit) == true,
                  let value = number(requested), let baseline = number(before),
                  let range = metadata.valueRange,
                  value >= range.min, value <= range.max, baseline >= range.min, baseline <= range.max,
                  metadata.writeMethod == "ax_slider_axvalue", metadata.readbackMethod == "ax_slider_axvalue" else {
                throw SagaWireError.invalid("threshold requires finite raw 0..100 percent values and before-state")
            }
            return ["param": .string(param), "unit": .string("normalized"),
                    "value": .double(value), "expected_before": .double(baseline)]
        case "limiter_on":
            guard unit == metadata.unit, unit == "boolean", case .bool = requested, case .bool = before,
                  metadata.writeMethod == "ax_controls_view_checkbox_press",
                  metadata.readbackMethod == "ax_controls_view_checkbox_value" else {
                throw SagaWireError.invalid("limiter_on requires literal Boolean value and before-state")
            }
            return params
        default: throw SagaWireError.invalid("only Compressor threshold and limiter_on are selected")
        }
    }

    static func validate(_ plan: SagaPlan) throws {
        guard containsPluginSteps(plan) else { return }
        guard plan.steps.count == 2,
              Set(plan.steps.compactMap { $0.params["param"]?.stringValue }) == ["threshold", "limiter_on"],
              let reference = plan.steps.first?.targetRef, reference.rawValue.hasPrefix("ins_"),
              plan.steps.allSatisfy({ $0.operationID == .pluginsSetParamVerified && $0.targetRef == reference
                  && $0.expectedInverse.operationID == .pluginsSetParamVerified
                  && $0.expectedInverse.valueParameter == "value" }) else {
            throw SagaWireError.invalid("the selected workflow requires exactly threshold and limiter_on on one occupied insert")
        }
        for step in plan.steps { _ = try canonicalParams(step.params) }
    }

    static func number(_ value: Value) -> Double? {
        switch value {
        case .double(let value) where value.isFinite: value
        case .int(let value): Double(value)
        default: nil
        }
    }

    static func tolerance(_ step: SagaStep) -> SagaTolerance {
        guard step.params["param"]?.stringValue == "threshold",
              let epsilon = VerifiedPluginCatalog.productionEntryLookup(pluginID)?.parameters
                .first(where: { $0.id == "threshold" })?.tolerance, epsilon.isFinite, epsilon >= 0 else { return .exact }
        return .absoluteEpsilon(epsilon)
    }

    static func beforeMatches(_ state: ObservedState?, _ step: SagaStep) -> Bool {
        guard let observed = state?.value, let expected = step.params["expected_before"] else { return false }
        return SagaValueComparator.ownershipEvidence(observed: observed, desired: expected).equal
    }

    static func binding(_ step: SagaStep, registry: TargetRegistry) async -> (TargetBinding, TargetDescriptor)? {
        guard FeatureFlags.adr002TargetRef, let reference = step.targetRef,
              let binding = await registry.resolve(reference), binding.kind == .pluginInsert,
              binding.pluginInsertIndex != nil,
              TargetRefResolver.pluginInsertIdentity(from: binding) == pluginID,
              let project = await registry.currentProjectIdentity, project.projectFilePath != nil else { return nil }
        return (binding, project)
    }

    static func read(_ step: SagaStep, router: ChannelRouter, cache: StateCache,
                     registry: TargetRegistry, now: Date) async -> ObservedState? {
        guard let (binding, project) = await binding(step, registry: registry),
              let param = step.params["param"]?.stringValue,
              let unit = step.params["unit"]?.stringValue else { return nil }
        let response = await bounded(command: "get_param_verified") {
            await PluginsDispatcher.handle(command: "get_param_verified", params: [
                "target_ref": .string(binding.reference.rawValue), "param": .string(param), "unit": .string(unit),
            ], router: router, cache: cache, targetRegistry: registry)
        }
        guard case .text(let text, _, _) = response.content.first,
              let body = decodedJSONObject(text), body["state"] as? String == "A",
              body["raw_unit"] as? String == unit, body["param"] as? String == param,
              let identity = body["target_identity"] as? [String: Any],
              identity["track_index"] as? Int == binding.descriptor.trackIndex,
              identity["insert"] as? Int == binding.pluginInsertIndex,
              identity["plugin_id"] as? String == pluginID,
              body["editor_cleanup_unobserved"] as? Bool != true,
              body["plugin_view_left_changed"] as? Bool != true,
              await registry.resolve(binding.reference) != nil,
              await registry.currentProjectIdentity == project else { return nil }
        let value: Value
        if param == "limiter_on" {
            guard let raw = body["observed_raw"], JSONInspector.isBoolean(raw), let flag = raw as? Bool else { return nil }
            value = .bool(flag)
        } else {
            guard let raw = body["observed_raw"], let number = JSONInspector.number(of: raw), number.isFinite,
                  number >= 0, number <= 100 else { return nil }
            value = .double(number)
        }
        return ObservedState(read: SagaReadEvidence(readSource: .axPluginParameter, provenance: .liveIndependent,
            trackIndex: binding.descriptor.trackIndex, field: param, observed: value,
            sampledAt: ISO8601DateFormatter().string(from: now)))
    }

    static func bounded(command: String, work: @escaping @Sendable () async -> CallTool.Result) async -> CallTool.Result {
        let parent = OperationTraceContext.current
        let lease = PluginsDispatcher.sagaLease
        let expectedBefore = PluginSagaExpectedBefore.current
        let parentBoundary = OperationTraceParentBoundary.onWriteBoundary
        if let lease, !lease.beginWorker() {
            return toolStateCResult(.cancelled, extras: ["write_attempted": false])
        }
        let finished = SagaAbandonFlag()
        #if DEBUG
        let seconds = testStepSeconds.map { min(stepSeconds, max(0.001, $0)) } ?? stepSeconds
        #else
        let seconds = stepSeconds
        #endif
        let deadline = min(parent?.deadline ?? ContinuousClock.now.advanced(by: .seconds(seconds)),
                           ContinuousClock.now.advanced(by: .seconds(seconds)))
        let result = await LogicProServer.runWithDeadline(tool: "logic_plugins", command: command,
            deadlineOverride: seconds, outerAbsoluteDeadline: deadline, externallyManagedMutation: true) {
            defer { lease?.endWorker(); finished.set(true) }
            let timer = OperationTraceContext.current
            let child = OperationTraceContext(parentTraceID: parent?.traceID,
                mutationGateAcquired: parent?.mutationGateAcquired ?? false,
                ownsGate: { parent?.ownsGate() ?? (command == "get_param_verified" || command == "get_channel_eq_state_verified") }, deadline: deadline,
                cancellationRequested: { Task.isCancelled || parent?.cancellationRequested() == true
                    || timer?.cancellationRequested() == true })
            guard child.ownsGate(), !child.cancellationRequested(), ContinuousClock.now < deadline else {
                return toolStateCResult(.cancelled, extras: ["write_attempted": false])
            }
            return await PluginsDispatcher.$sagaLease.withValue(lease) {
                await PluginSagaExpectedBefore.$current.withValue(expectedBefore) {
                    await OperationTraceParentBoundary.$onWriteBoundary.withValue(parentBoundary) {
                        await OperationTraceContext.$current.withValue(child) { await work() }
                    }
                }
            }
        }
        if !finished.value { lease?.release() }
        return result
    }
}

/// Only the validated Saga adapter constructs this internal before-state context.
/// There is no public scalar-setter argument that can authorize or bypass it.
struct PluginSagaExpectedBefore: Sendable {
    @TaskLocal static var current: PluginSagaExpectedBefore?
    let track: Int
    let insert: Int
    let projectPath: String
    let param: String
    let observed: Value
    let pluginID: String

    init(track: Int, insert: Int, projectPath: String, param: String, observed: Value,
         pluginID: String = CompressorParameterSaga.pluginID) {
        self.track = track; self.insert = insert; self.projectPath = projectPath
        self.param = param; self.observed = observed; self.pluginID = pluginID
    }

    /// `track` is optional because the master Stereo Output strip has no Arrange index. A nil
    /// track never matches this context — every Saga binding is track-addressed — so an
    /// output-strip write made while a Saga before-state is active fails closed.
    func matches(track: Int?, insert: Int, pluginID: String, param: String,
                 projectPath: String, observed: Value) -> Bool {
        Optional(self.track) == track && self.insert == insert && pluginID == self.pluginID
            && self.param == param && self.projectPath.utf8.elementsEqual(projectPath.utf8)
            && SagaValueComparator.ownershipEvidence(observed: observed, desired: self.observed).equal
    }
}
