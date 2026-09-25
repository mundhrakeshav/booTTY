import Foundation

extension UndoManager {
    /// A Boolean value that indicates whether the undo manager is currently performing
    /// either an undo or redo operation.
    var isUndoingOrRedoing: Bool {
        isUndoing || isRedoing
    }

    /// Temporarily disables undo registration while executing the provided handler.
    ///
    /// This method provides a convenient way to perform operations without recording them
    /// in the undo stack. It ensures that undo registration is properly re-enabled even
    /// if the handler throws an error.
    func disableUndoRegistration(handler: () -> Void) {
        disableUndoRegistration()
        handler()
        enableUndoRegistration()
    }

    /// Runs `handler`, which must register an undo, as an undo step of its own. With
    /// `groupsByEvent`, everything registered in one event undoes together, even inside
    /// explicit groups, so each folder of a multi-folder open would otherwise undo with the
    /// rest (SPEC §9.1). Inside an open group, or while undoing or redoing, it just runs
    /// `handler`. A handler that registers nothing leaves an empty step.
    func registerAsOwnStep(handler: () -> Void) {
        guard groupingLevel == 0, !isUndoingOrRedoing, groupsByEvent else { return handler() }
        groupsByEvent = false
        beginUndoGrouping()
        handler()
        endUndoGrouping()
        groupsByEvent = true
    }
}
