//
//  InputInterlock.swift
//  LocalBrainKit
//
//  When a run stops because the user took over. The agent never moves the real
//  cursor, so any real mouse travel is the user's. Keys the agent posts itself
//  carry a tag in their event user data and are ignored.
//

import Foundation

public enum InputInterlock {
    /// Stamped on every key event the agent posts ("LCLK").
    public static let agentEventTag: Int64 = 0x4C434C4B
    /// Mouse travel (in points) that counts as the user moving the mouse.
    public static let mouseMoveStopPoints: Double = 12

    public static func shouldStop(mouseTravel: Double) -> Bool {
        mouseTravel >= mouseMoveStopPoints
    }

    public static func shouldStop(keyDownWithUserData userData: Int64) -> Bool {
        userData != agentEventTag
    }
}
