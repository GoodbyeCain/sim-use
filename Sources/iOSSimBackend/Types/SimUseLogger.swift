// SPDX-License-Identifier: Apache-2.0
import Foundation
import FBControlCore

public final class SimUseLogger: FBCompositeLogger {
    public override init(loggers: [FBControlCoreLogger]) {
        super.init(loggers: loggers)
    }
    
    public convenience init(debugLogging: Bool = false, writeToStdErr: Bool = true) {
        let systemLogger = FBControlCoreLoggerFactory.systemLoggerWriting(
            toStderr: writeToStdErr,
            withDebugLogging: debugLogging
        )
        self.init(loggers: [systemLogger])
    }
    
    /// The default logger writes to no visible sink; SIM_USE_DEBUG=1
    /// turns on stderr (which the daemon redirects to its logfile), so
    /// info-lines like the HID transport-selection signals become
    /// visible in the field (issue #67). The daemon keeps the
    /// environment it was spawned with — combine with a daemon restart
    /// or SIM_USE_NO_DAEMON=1.
    public override convenience init() {
        let debug = ProcessInfo.processInfo.environment["SIM_USE_DEBUG"] == "1"
        self.init(debugLogging: debug, writeToStdErr: debug)
    }
    
    public func makeDefault() {
        FBControlCoreGlobalConfiguration.defaultLogger = self
    }
    
    public func warning() -> FBControlCoreLogger {
        return self.debug()
    }
}