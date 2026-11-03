import Testing
@testable import AgtermLinux

@Suite("AppImage child environment")
struct AppImageChildEnvironmentTests {
    @Test("removes AppImage library path from child environment")
    func removesBundledLibraryPath() {
        let environment = AppImageChildEnvironment.sanitized([
            "APPDIR": "/tmp/.mount_agterm/usr",
            "LD_LIBRARY_PATH": "/tmp/.mount_agterm/usr/lib",
            "PATH": "/tmp/.mount_agterm/usr/bin:/usr/bin"
        ])

        #expect(environment["LD_LIBRARY_PATH"] == nil)
        #expect(environment["APPDIR"] == "/tmp/.mount_agterm/usr")
        #expect(environment["PATH"] == "/tmp/.mount_agterm/usr/bin:/usr/bin")
    }

    @Test("preserves caller library paths when removing AppImage paths")
    func preservesCallerLibraryPath() {
        let environment = AppImageChildEnvironment.sanitized([
            "APPDIR": "/tmp/.mount_agterm",
            "LD_LIBRARY_PATH": "/tmp/.mount_agterm/usr/lib:/opt/vendor/lib:/usr/local/lib"
        ])

        #expect(environment["LD_LIBRARY_PATH"] == "/opt/vendor/lib:/usr/local/lib")
    }

    @Test("preserves environment outside AppImage")
    func preservesNativeEnvironment() {
        let environment = AppImageChildEnvironment.sanitized([
            "LD_LIBRARY_PATH": "/opt/lib",
            "PATH": "/usr/bin"
        ])

        #expect(environment["LD_LIBRARY_PATH"] == "/opt/lib")
        #expect(environment["PATH"] == "/usr/bin")
    }
}
