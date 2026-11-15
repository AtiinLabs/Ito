import Foundation

@MainActor
extension MediaDetailDownloadBatchModel {

    /// Continues from the count prompt. Only the open prompt of this series, with a count in range, is acted on.
    @discardableResult
    func confirmDownloadMore(count: Int, promptID: UUID) -> Task<Void, Never> {
        guard pendingMoreOperationID == nil,
              case .moreCount(let prompt)? = sheet, prompt.id == promptID,
              host?.batchIdentity == prompt.identity,
              let count = DownloadPositionCount(count) else { return Task {} }
        let operationID = UUID()
        pendingMoreOperationID = operationID
        pendingMorePromptID = promptID
        return startDownload(.more(count), promptOperationID: operationID)
    }

    /// Whether `operationID` still owns the same visible prompt and saved series.
    func isValidMoreOperation(_ operationID: UUID?) -> Bool {
        guard let operationID else { return true }
        let valid: Bool
        if pendingMoreOperationID == operationID,
           let promptID = pendingMorePromptID,
           case .moreCount(let prompt)? = sheet,
           prompt.id == promptID,
           host?.batchIdentity == prompt.identity,
           host?.batchIsSaved == true {
            valid = true
        } else {
            valid = false
        }
        if !valid, pendingMoreOperationID == operationID { invalidateMoreOperation() }
        return valid
    }

    /// Ends prompt ownership immediately before its approved next state is presented or a batch is admitted.
    func consumeMoreOperation(_ operationID: UUID?) -> Bool {
        guard isValidMoreOperation(operationID) else { return false }
        guard operationID != nil else { return true }
        invalidateMoreOperation()
        return true
    }

    func invalidateMoreOperation() {
        pendingMoreOperationID = nil
        pendingMorePromptID = nil
    }
}
