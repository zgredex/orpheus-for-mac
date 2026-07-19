public enum NativeRuntimePlatform {
    public static let architecture: String = {
        #if arch(arm64)
        "arm64"
        #elseif arch(x86_64)
        "x86_64"
        #else
        "unknown"
        #endif
    }()
}
