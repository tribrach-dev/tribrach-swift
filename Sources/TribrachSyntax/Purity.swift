import SwiftSyntax

/// Purity codes and the model-side reason for each.
public let purityReasons: [String: String] = [
    "TRS0301": "the model has no clock: pass the time in as an argument",
    "TRS0302": "the model has no randomness: pass the random value or seed in as an argument",
    "TRS0303": "the model does no I/O: do it in the caller and pass the result in",
    "TRS0304": "the model has no shared mutable state: pass the value in or make it a constant",
    "TRS0305": "the model is sequential: keep async work, tasks and queues in the caller",
    "TRS0306": "the model's lists have one order and dictionary and set iteration has none: iterate over sorted keys",
    "TRS0307": "everything a linked function calls must be pure too: mark it //tribrach:pure or move the call out",
]

/// Checks one pure function's body. Swift purity is checked by syntax, so
/// it matches names: the lists below are the common Foundation entry points,
/// and `--allow` silences a code or a name.
final class PurityChecker: SyntaxVisitor {
    let subject: String
    let typePath: String
    let declarations: Declarations
    let allow: Set<String>
    var findings: [(AbsolutePosition, String, String)] = []
    private var seen = Set<String>()

    init(subject: String, typePath: String, declarations: Declarations, allow: Set<String>, viewMode: SyntaxTreeViewMode) {
        self.subject = subject
        self.typePath = typePath
        self.declarations = declarations
        self.allow = allow
        super.init(viewMode: viewMode)
    }

    static let callNames: [String: String] = [
        "Date": "TRS0301", "CFAbsoluteTimeGetCurrent": "TRS0301", "mach_absolute_time": "TRS0301",
        "arc4random": "TRS0302", "arc4random_uniform": "TRS0302", "UUID": "TRS0302",
        "SystemRandomNumberGenerator": "TRS0302",
        "print": "TRS0303", "debugPrint": "TRS0303", "dump": "TRS0303", "NSLog": "TRS0303",
        "os_log": "TRS0303", "readLine": "TRS0303", "Logger": "TRS0303", "FileHandle": "TRS0303",
        "URLSession": "TRS0303", "FileManager": "TRS0303", "UserDefaults": "TRS0303",
        "Task": "TRS0305", "DispatchQueue": "TRS0305", "DispatchGroup": "TRS0305",
        "DispatchSemaphore": "TRS0305", "NSLock": "TRS0305", "Thread": "TRS0305",
    ]

    static let memberNames: [String: String] = [
        "Date.now": "TRS0301", "DispatchTime.now": "TRS0301", "ContinuousClock.now": "TRS0301",
        "SuspendingClock.now": "TRS0301", "ProcessInfo.processInfo": "TRS0303",
        "FileManager.default": "TRS0303", "URLSession.shared": "TRS0303", "UserDefaults.standard": "TRS0303",
        "NotificationCenter.default": "TRS0303", "Bundle.main": "TRS0303",
        "DispatchQueue.main": "TRS0305", "DispatchQueue.global": "TRS0305", "Task.detached": "TRS0305",
        "MainActor.run": "TRS0305",
    ]

    func flag(_ pos: AbsolutePosition, _ code: String, _ what: String) {
        if allow.contains(code) || allow.contains(what) || seen.contains(code + what) { return }
        seen.insert(code + what)
        findings.append((pos, code, "\(subject) uses \(what); \(purityReasons[code] ?? "")"))
    }

    override func visit(_ node: FunctionCallExprSyntax) -> SyntaxVisitorContinueKind {
        let pos = node.positionAfterSkippingLeadingTrivia
        if let ref = node.calledExpression.as(DeclReferenceExprSyntax.self) {
            let name = ref.baseName.text
            if let code = Self.callNames[name] {
                flag(pos, code, name)
            } else {
                let member = typePath.isEmpty ? name : "\(typePath).\(name)"
                for key in [member, name] where declarations.functions.contains(key) {
                    if !declarations.pureFunctions.contains(key) { flag(pos, "TRS0307", key) }
                    break
                }
            }
        } else if let m = node.calledExpression.as(MemberAccessExprSyntax.self) {
            let name = m.declName.baseName.text
            if name == "random" || name == "randomElement" || name == "shuffled" || name == "shuffle" {
                flag(pos, "TRS0302", ".\(name)()")
            } else if let base = m.base?.trimmedDescription {
                let key = "\(base).\(name)"
                if declarations.functions.contains(key) && !declarations.pureFunctions.contains(key) {
                    flag(pos, "TRS0307", key)
                }
            }
        }
        return .visitChildren
    }

    override func visit(_ node: MemberAccessExprSyntax) -> SyntaxVisitorContinueKind {
        guard let base = node.base?.trimmedDescription else { return .visitChildren }
        let key = "\(base).\(node.declName.baseName.text)"
        let pos = node.positionAfterSkippingLeadingTrivia
        if let code = Self.memberNames[key] {
            flag(pos, code, key)
        } else if declarations.staticVars.contains(key) {
            flag(pos, "TRS0304", "the static variable \(key)")
        }
        return .visitChildren
    }

    override func visit(_ node: DeclReferenceExprSyntax) -> SyntaxVisitorContinueKind {
        let name = node.baseName.text
        if declarations.globalVars.contains(name) {
            flag(node.positionAfterSkippingLeadingTrivia, "TRS0304", "the global variable \(name)")
        }
        if !typePath.isEmpty && declarations.staticVars.contains("\(typePath).\(name)") {
            flag(node.positionAfterSkippingLeadingTrivia, "TRS0304", "the static variable \(typePath).\(name)")
        }
        return .visitChildren
    }

    override func visit(_ node: AwaitExprSyntax) -> SyntaxVisitorContinueKind {
        flag(node.positionAfterSkippingLeadingTrivia, "TRS0305", "await")
        return .visitChildren
    }

    override func visit(_ node: ForStmtSyntax) -> SyntaxVisitorContinueKind {
        if let m = node.sequence.as(MemberAccessExprSyntax.self),
           ["keys", "values"].contains(m.declName.baseName.text) {
            flag(node.sequence.positionAfterSkippingLeadingTrivia, "TRS0306", "iteration over .\(m.declName.baseName.text)")
        }
        return .visitChildren
    }
}
