import Foundation
import CoreGraphics

/// Translates normalized pointer events from the browser into real macOS
/// mouse events posted onto the virtual display. Requires Accessibility
/// permission (System Settings ▸ Privacy & Security ▸ Accessibility).
final class InputInjector {

    var enabled = true
    var displayID: CGDirectDisplayID = 0
    private var dragging = false

    /// `event` is a decoded JSON object from the receiver page, e.g.
    /// { "type": "down", "x": 0.5, "y": 0.5 }  (x,y normalized 0...1)
    func handle(_ event: [String: Any]) {
        guard enabled, let type = event["type"] as? String else { return }

        let bounds = CGDisplayBounds(displayID)
        let nx = min(1.0, max(0.0, (event["x"] as? Double) ?? 0))
        let ny = min(1.0, max(0.0, (event["y"] as? Double) ?? 0))
        let point = CGPoint(x: bounds.origin.x + nx * bounds.size.width,
                            y: bounds.origin.y + ny * bounds.size.height)

        switch type {
        case "move":
            post(dragging ? .leftMouseDragged : .mouseMoved, at: point)
        case "down":
            dragging = true
            post(.leftMouseDown, at: point)
        case "up":
            dragging = false
            post(.leftMouseUp, at: point)
        case "click":
            post(.leftMouseDown, at: point)
            post(.leftMouseUp, at: point)
        case "scroll":
            let dy = Int32((event["dy"] as? Double) ?? 0)
            let dx = Int32((event["dx"] as? Double) ?? 0)
            if let scroll = CGEvent(scrollWheelEvent2Source: nil, units: .pixel,
                                    wheelCount: 2, wheel1: -dy, wheel2: -dx, wheel3: 0) {
                scroll.post(tap: .cghidEventTap)
            }
        default:
            break
        }
    }

    private func post(_ type: CGEventType, at point: CGPoint) {
        guard let event = CGEvent(mouseEventSource: nil, mouseType: type,
                                  mouseCursorPosition: point, mouseButton: .left) else { return }
        event.post(tap: .cghidEventTap)
    }
}
