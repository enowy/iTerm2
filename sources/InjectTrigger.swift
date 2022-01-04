//
//  InjectTrigger.swift
//  iTerm2SharedARC
//
//  Created by George Nachman on 6/26/21.
//

import Foundation

@objc(iTermInjectTrigger)
class InjectTrigger: Trigger {
    override static var title: String {
        return "Inject Data…"
    }

    override func takesParameter() -> Bool {
        return true
    }

    override func triggerOptionalParameterPlaceholder(withInterpolation interpolation: Bool) -> String? {
        return "Use \\e for esc, \\a for ^G."
    }

    override func performAction(withCapturedStrings strings: [String],
                                capturedRanges: UnsafePointer<NSRange>,
                                in session: iTermTriggerSession,
                                onString s: iTermStringLine,
                                atAbsoluteLineNumber lineNumber: Int64,
                                useInterpolation: Bool,
                                stop: UnsafeMutablePointer<ObjCBool>) -> Bool {
        // I can live with stopping the world here; this should be used very sparingly. I also don't expect much use of scope here.
        paramWithBackreferencesReplaced(withValues: strings,
                                        scope: session.triggerSessionVariableScopeProvider(self),
                                        useInterpolation: useInterpolation).then { message in
            if let data = (message as String).data(using: .utf8) {
                session.triggerSession(self, inject: data);
            }
        }
        return false
    }
}
