import mal
import MangaBakaSDK

/// Admission sits inside the repository's existing serialized, non-caller-cancellable refresh. A policy refusal
/// does not turn into an invalid credential, and nothing changes the repository's account/refresh generations.
nonisolated struct PolicyMALTokenRefresher: MALTokenRefreshing {
    let inner: any MALTokenRefreshing
    let authorities: AppNetworkAuthorityProvider

    func refresh(_ token: MALToken) async throws -> MALToken {
        try authorities.admit(.trackerWrite)
        return try await inner.refresh(token)
    }
}

nonisolated struct PolicyMangaBakaTokenRefresher: MangaBakaTokenRefreshing {
    let inner: any MangaBakaTokenRefreshing
    let authorities: AppNetworkAuthorityProvider

    func refresh(_ token: MangaBakaToken) async throws -> MangaBakaToken {
        try authorities.admit(.trackerWrite)
        return try await inner.refresh(token)
    }
}
