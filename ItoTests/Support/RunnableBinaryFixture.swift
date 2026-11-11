import ito_runner

/// The interface of a plugin module this Ito can run: the given ABI, every kind, no imports and no start section.
/// Tests that publish an installed plugin meant to run must pass this (or a real inspected interface), because a
/// plugin without a readable module is refused before it loads.
func makeRunnableBinary(abi: Int = ItoRunner.supportedABIVersions.upperBound) -> PluginBinaryInterface {
    PluginBinaryInterface(abiVersion: abi, imports: [], kinds: MediaKind.allCases)
}
