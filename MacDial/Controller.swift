import Foundation

protocol Controller: AnyObject {
    func onDown(dial: Dial)

    func onUp(dial: Dial)

    /// `direction` is +1 (standard) or -1 (natural).
    func onRotate(dial: Dial, rotation: Dial.Rotation, direction: Int)
}
