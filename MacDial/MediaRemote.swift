import AppKit
import Foundation

/// Seek support for the system now-playing app.
///
/// MRMediaRemoteSetElapsedTime (private MediaRemote framework) still works
/// unentitled on current macOS, but position *reads* are gated — so scrub
/// sessions get their starting position from the running player via
/// AppleScript (Music/Spotify), then seek relatively from there.
enum MediaRemote {
    private static let setElapsedFn: (@convention(c) (Double) -> Void)? = {
        guard let handle = dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_NOW),
              let sym = dlsym(handle, "MRMediaRemoteSetElapsedTime") else { return nil }
        return unsafeBitCast(sym, to: (@convention(c) (Double) -> Void).self)
    }()

    static var canSeek: Bool {
        setElapsedFn != nil
    }

    static func setElapsedTime(_ seconds: Double) {
        setElapsedFn?(seconds)
    }
}

struct PlayerPosition {
    var position: Double
    var duration: Double?
}

/// Reads the current track position from a running, scriptable player.
/// Main thread only (NSAppleScript). Returns nil if no known player is
/// running — callers should fall back to track skipping.
func queryPlayerPosition() -> PlayerPosition? {
    let players = ["com.apple.Music": "Music", "com.spotify.client": "Spotify"]
    let running = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))

    for (bundleID, name) in players where running.contains(bundleID) {
        let script = """
        tell application "\(name)"
            if player state is playing or player state is paused then
                return (player position as string) & "|" & (duration of current track as string)
            end if
        end tell
        """
        var error: NSDictionary?
        guard let result = NSAppleScript(source: script)?.executeAndReturnError(&error).stringValue,
              !result.isEmpty else { continue }
        let parts = result.replacingOccurrences(of: ",", with: ".").split(separator: "|")
        guard let position = parts.first.flatMap({ Double($0) }) else { continue }
        var duration = parts.count > 1 ? Double(parts[1]) : nil
        // ponytail: Spotify reports duration in milliseconds, Music in seconds.
        if let d = duration, d > 36000 { duration = d / 1000 }
        return PlayerPosition(position: position, duration: duration)
    }
    return nil
}
