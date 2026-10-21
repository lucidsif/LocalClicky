//
//  ModelPreferences.swift
//  LocalClicky
//
//  Persists which installed Ollama models power LocalClicky's two roles — the
//  text/reasoning model and the screen-vision model. Out of the box these are
//  the bundled defaults (llama3.2:3b and qwen2.5vl:3b), tuned for a 16 GB
//  Apple-silicon Mac. Users on different hardware can point either role at any
//  model in their own Ollama: someone with more memory might pick qwen3-vl:8b for
//  sharper screen grounding; someone on a smaller machine might choose a 1B text
//  model. The vision role is still validated to actually accept images (see
//  CompanionManager.refreshInstalledModels), so a text-only model can't be
//  chosen for a job it can't do.
//

import Foundation
import LocalBrainKit

enum ModelPreferences {
    private static let chatKey = "localClicky.chatModelName"
    private static let visionKey = "localClicky.visionModelName"
    private static let groundingKey = "localClicky.groundingModelName"
    private static let drawingKey = "drawingEnabled"
    private static let draftModelKey = "localClicky.draftModelName"
    private static let gmailAccountKey = "localClicky.gmailAccountIndex"
    private static let userNameKey = "localClicky.userDisplayName"
    private static let customSitesKey = "localClicky.customSites"

    static var chatModel: String {
        get { UserDefaults.standard.string(forKey: chatKey) ?? LocalModels.defaultChatModel }
        set { UserDefaults.standard.set(newValue, forKey: chatKey) }
    }

    static var visionModel: String {
        get { UserDefaults.standard.string(forKey: visionKey) ?? LocalModels.defaultVisionModel }
        set { UserDefaults.standard.set(newValue, forKey: visionKey) }
    }

    /// The grounding model used for pointing turns (the blue cursor's coordinates).
    /// Defaults to qwen2.5vl; the default vision model (Moondream) can't ground.
    static var groundingModel: String {
        get { UserDefaults.standard.string(forKey: groundingKey) ?? LocalModels.defaultGroundingModel }
        set { UserDefaults.standard.set(newValue, forKey: groundingKey) }
    }

    /// Whether Clicky may draw shapes on the screen (circle, outline, highlight).
    /// A beta: off until the shape evaluation passes, so a fresh install never
    /// changes how a turn routes.
    static var drawingEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: drawingKey) }
        set { UserDefaults.standard.set(newValue, forKey: drawingKey) }
    }

    /// The model that writes email draft bodies, through the same gateway as chat. A config value.
    static var draftModel: String {
        get { UserDefaults.standard.string(forKey: draftModelKey) ?? DraftWriter.defaultModel }
        set { UserDefaults.standard.set(newValue, forKey: draftModelKey) }
    }

    /// Which signed-in Google account a Gmail draft opens in (the /u/N/ of the compose link).
    static var gmailAccountIndex: Int {
        get {
            UserDefaults.standard.object(forKey: gmailAccountKey) == nil
                ? ComposeTarget.defaultGmailAccountIndex : max(0, UserDefaults.standard.integer(forKey: gmailAccountKey))
        }
        set { UserDefaults.standard.set(max(0, newValue), forKey: gmailAccountKey) }
    }

    /// The name the draft writer signs as ("write as <name>"). Empty by default: the email is then written as
    /// "the user", in the first person. Set it with `defaults write <bundle id> localClicky.userDisplayName <name>`.
    static var userDisplayName: String {
        get { UserDefaults.standard.string(forKey: userNameKey) ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: userNameKey) }
    }

    /// The user's own spoken site names, name -> address (http or https), empty by default. "open <name>" then opens
    /// the address in the browser. Set with `defaults write com.localclicky.LocalClicky localClicky.customSites -dict
    /// "my dashboard" "http://127.0.0.1:9999/"`; a speech-to-text spelling of a name is just another key.
    static var customSites: [String: String] {
        get { UserDefaults.standard.dictionary(forKey: customSitesKey) as? [String: String] ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: customSitesKey) }
    }

    static func model(for role: ModelRole) -> String {
        switch role {
        case .chat: return chatModel
        case .vision: return visionModel
        case .grounding: return groundingModel
        }
    }

    static func setModel(_ name: String, for role: ModelRole) {
        switch role {
        case .chat: chatModel = name
        case .vision: visionModel = name
        case .grounding: groundingModel = name
        }
    }

    /// Restore all roles to LocalClicky's defaults.
    static func resetToDefaults() {
        UserDefaults.standard.removeObject(forKey: chatKey)
        UserDefaults.standard.removeObject(forKey: visionKey)
        UserDefaults.standard.removeObject(forKey: groundingKey)
    }
}
