import Foundation
import FoundationModels
import DetectiveKit

/// Which Apple Intelligence model the user prefers. On-device is the default.
enum AIEngine: String, CaseIterable, Identifiable {
    case onDevice
    case privateCloud

    var id: String { rawValue }

    var label: String {
        switch self {
        case .onDevice: "On-device"
        case .privateCloud: "Private Cloud"
        }
    }
}

/// State of Apple's Private Cloud Compute model for this app and user.
enum CloudState: Equatable {
    /// App was built with an SDK older than iOS 27.
    case notInThisBuild
    /// Needs iOS 27 or later.
    case needsNewerIOS
    /// Not offered right now: device not eligible, Apple Intelligence off, or app not enrolled.
    case unavailable
    /// The user's daily cloud allowance is used up.
    case limitReached
    case nearLimit
    case ready
}

/// Picks the model for each request and falls back gracefully:
/// Private Cloud (if chosen and available) → on-device → caller's rule-based fallback.
@MainActor
enum ModelRouter {
    static let engineKey = "aiEngine"

    static var preferred: AIEngine {
        AIEngine(rawValue: UserDefaults.standard.string(forKey: engineKey) ?? "") ?? .onDevice
    }

    /// Tests turn Apple Intelligence off to exercise the fallback paths on any machine.
    static var disabledForTesting = false

    static var onDeviceAvailable: Bool {
        if disabledForTesting { return false }
        if case .available = SystemLanguageModel.default.availability { return true }
        return false
    }

    static var cloudState: CloudState {
        #if PCC_SDK
        if #available(iOS 27.0, *) {
            let model = PrivateCloudComputeLanguageModel()
            guard model.isAvailable else { return .unavailable }
            if model.quotaUsage.isLimitReached { return .limitReached }
            if case .belowLimit(let info) = model.quotaUsage.status, info.isApproachingLimit { return .nearLimit }
            return .ready
        } else {
            return .needsNewerIOS
        }
        #else
        return .notInThisBuild
        #endif
    }

    static var cloudUsable: Bool { !disabledForTesting && (cloudState == .ready || cloudState == .nearLimit) }

    /// True when any Apple Intelligence model can answer.
    static var anyAvailable: Bool { onDeviceAvailable || (preferred == .privateCloud && cloudUsable) }

    /// Offers the system sheet for raising the daily cloud limit (iCloud+), when there is one.
    static func showLimitIncrease() {
        #if PCC_SDK
        if #available(iOS 27.0, *) {
            if let suggestion = PrivateCloudComputeLanguageModel().quotaUsage.limitIncreaseSuggestion {
                suggestion.show()
            }
        }
        #endif
    }

    /// A new session on the preferred model, or nil if no Apple Intelligence model is available.
    static func session(instructions: String, tools: [any Tool] = [], preferCloud: Bool? = nil) -> (LanguageModelSession, ReportAuthor)? {
        if preferCloud ?? (preferred == .privateCloud), let cloud = cloudSession(instructions: instructions, tools: tools) {
            return (cloud, .privateCloud)
        }
        guard onDeviceAvailable else { return nil }
        return (LanguageModelSession(tools: tools, instructions: instructions), .appleIntelligence)
    }

    static func cloudSession(instructions: String, tools: [any Tool]) -> LanguageModelSession? {
        #if PCC_SDK
        if #available(iOS 27.0, *), cloudUsable {
            return LanguageModelSession(model: PrivateCloudComputeLanguageModel(), tools: tools, instructions: instructions)
        }
        #endif
        return nil
    }

    /// Runs `body` on the preferred model; if the cloud request fails (offline, limit hit),
    /// retries on-device. Returns nil when no model could answer.
    static func run<T>(instructions: String, tools: [any Tool] = [],
                       _ body: (LanguageModelSession, ReportAuthor) async throws -> T) async -> (T, ReportAuthor)? {
        if preferred == .privateCloud, let cloud = cloudSession(instructions: instructions, tools: tools) {
            if let result = try? await body(cloud, .privateCloud) { return (result, .privateCloud) }
        }
        guard onDeviceAvailable else { return nil }
        let local = LanguageModelSession(tools: tools, instructions: instructions)
        guard let result = try? await body(local, .appleIntelligence) else { return nil }
        return (result, .appleIntelligence)
    }
}
