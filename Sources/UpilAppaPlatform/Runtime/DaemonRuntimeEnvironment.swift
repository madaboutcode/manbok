import Foundation
import UpilAppaCore

// MARK: - CONTRACT (DaemonRuntimeEnvironment)
//
// GUARANTEES
// - `bootstrap` installs diagnostics for the presentation (daemon → os.Logger only).
// - `makeActivityPresenter` returns terminal meter or null from presentation only.
//
// DOES NOT
// - Run the socket server or start capture.

public enum DaemonRuntimeEnvironment {
    public static func bootstrap(presentation: DaemonPresentation) {
        switch presentation {
        case .detached, .foregroundMeter:
            Diagnostics.install(OSLogOnlyDiagnostics())
        }
    }

    public static func makeActivityPresenter(
        presentation: DaemonPresentation,
        snapshot: @escaping () -> AudioActivitySnapshot,
        mode: @escaping () -> TerminalCaptureMeter.Mode,
        isCapturing: @escaping () -> Bool,
        ringFilledBytes: @escaping () -> Int
    ) -> ActivityPresenting {
        switch presentation {
        case .detached:
            return NullActivityPresenter()
        case .foregroundMeter:
            return TerminalCaptureMeter(
                snapshot: snapshot,
                mode: mode,
                isCapturing: isCapturing,
                ringFilledBytes: ringFilledBytes
            )
        }
    }
}