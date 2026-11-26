import SwiftParser
import SwiftSyntax
import TribrachCore

/// A diagnostic in the format Xcode and SwiftPM show inline.
public struct Diagnostic: CustomStringConvertible, Sendable, Equatable {
    public enum Severity: String, Sendable { case error, warning }
    public var file: String
    public var line: Int
    public var column: Int
    public var severity: Severity
    public var code: String
    public var message: String

    public init(file: String, line: Int, column: Int, severity: Severity, code: String, message: String) {
        self.file = file
        self.line = line
        self.column = column
        self.severity = severity
        self.code = code
        self.message = message
    }

    public var description: String { "\(file):\(line):\(column): \(severity.rawValue): \(code) \(message)" }
}

/// A function with `//tribrach:` directives.
public struct LinkedFunction: Sendable {
    public var symbol: String
    public var name: String
    public var lean: String?
    public var stamp: String?
    public var pure: Bool
    public var file: String
    public var line: Int
    public var column: Int
    /// UTF-8 offsets of the link and stamp comments, for `stamp`.
    public var linkRange: Range<Int>?
    public var stampRange: Range<Int>?
}

/// Declarations every scanned file can see: package-level mutable state and
/// which functions are marked pure.
public struct Declarations: Sendable {
    public var globalVars: Set<String> = []
    /// `Type.name` for static and class variables.
    public var staticVars: Set<String> = []
    /// Function keys (`name` or `Type.name`) declared in the scanned files.
    public var functions: Set<String> = []
    /// Function keys marked //tribrach:pure or //tribrach:link.
    public var pureFunctions: Set<String> = []

    public init() {}
}

/// The result of reading one file.
public struct FileScan: Sendable {
    public var path: String
    public var functions: [LinkedFunction] = []
    public var diagnostics: [Diagnostic] = []
}

public enum Scanner {
    /// Modules a file with linked functions may import.
    public static let allowedImports: Set<String> = ["Swift", "Foundation"]

    /// Collect declarations from every file first, so purity checks can see
    /// globals and pure helpers in other files.
    public static func declarations(_ files: [(path: String, source: String)]) -> Declarations {
        var d = Declarations()
        for f in files {
            let tree = Parser.parse(source: f.source)
            let v = DeclarationCollector(viewMode: .sourceAccurate)
            v.walk(tree)
            d.globalVars.formUnion(v.globals)
            d.staticVars.formUnion(v.statics)
            d.functions.formUnion(v.functions)
            d.pureFunctions.formUnion(v.pure)
        }
        return d
    }

    /// Read one file: its linked functions, directive problems and purity.
    public static func scan(path: String, source: String, declarations: Declarations, allow: Set<String> = []) -> FileScan {
        let tree = Parser.parse(source: source)
        let converter = SourceLocationConverter(fileName: path, tree: tree)
        var result = FileScan(path: path)
        func diag(_ pos: AbsolutePosition, _ severity: Diagnostic.Severity, _ code: String, _ message: String) {
            let loc = converter.location(for: pos)
            result.diagnostics.append(Diagnostic(
                file: path, line: loc.line, column: loc.column, severity: severity, code: code, message: message))
        }

        let finder = FunctionFinder(viewMode: .sourceAccurate)
        finder.walk(tree)
        var attributed = Set<Int>()
        for fn in finder.functions {
            let directives = Scanner.directives(in: fn.leadingTrivia, startingAt: fn.position.utf8Offset)
            let valid = directives.filter { if case .problem = $0.directive { return false } else { return true } }
            guard !valid.isEmpty else { continue }
            let typePath = Scanner.typePath(of: fn)
            let key = typePath.isEmpty ? fn.name.text : "\(typePath).\(fn.name.text)"
            let labels = fn.signature.parameterClause.parameters.map { "\($0.firstName.text):" }.joined()
            let symbol = "\(key)(\(labels))"
            let namePos = fn.name.positionAfterSkippingLeadingTrivia
            let loc = converter.location(for: namePos)
            var linked = LinkedFunction(
                symbol: symbol, name: fn.name.text, lean: nil, stamp: nil, pure: false,
                file: path, line: loc.line, column: loc.column)
            for d in valid {
                attributed.insert(d.range.lowerBound)
                switch d.directive {
                case let .link(lean):
                    if let first = linked.lean {
                        diag(namePos, .error, "TRS0103", "\(fn.name.text) already links \(first); a function implements one Lean definition")
                        continue
                    }
                    linked.lean = lean
                    linked.pure = true
                    linked.linkRange = d.range
                case let .stamp(s):
                    linked.stamp = s
                    linked.stampRange = d.range
                case .pure:
                    linked.pure = true
                case .problem:
                    break
                }
            }
            if linked.stamp != nil && linked.lean == nil {
                diag(namePos, .error, "TRS0104", "\(fn.name.text) has a //tribrach:stamp but no //tribrach:link; a stamp records which Lean definition it was checked against")
            }
            result.functions.append(linked)
            if linked.pure {
                let subject = linked.lean.map { "\(fn.name.text) (linked to \($0))" } ?? fn.name.text
                let purity = PurityChecker(
                    subject: subject, typePath: typePath, declarations: declarations, allow: allow,
                    viewMode: .sourceAccurate)
                if fn.signature.effectSpecifiers?.asyncSpecifier != nil {
                    purity.flag(namePos, "TRS0305", "async")
                }
                if let body = fn.body { purity.walk(body) }
                for f in purity.findings { diag(f.0, .error, f.1, f.2) }
            }
        }

        // Directive problems anywhere, and valid directives outside a
        // function's leading comments.
        for token in tree.tokens(viewMode: .sourceAccurate) {
            let pieces = Scanner.directives(in: token.leadingTrivia, startingAt: token.position.utf8Offset)
                + Scanner.directives(in: token.trailingTrivia, startingAt: token.endPositionBeforeTrailingTrivia.utf8Offset)
            for d in pieces {
                if case let .problem(p) = d.directive {
                    diag(AbsolutePosition(utf8Offset: d.range.lowerBound), .error, "TRS0101",
                         "can't read \"\(d.text)\": \(p.rawValue); the forms are //tribrach:link <LeanName>, //tribrach:pure and //tribrach:stamp <16 hex digits>")
                } else if !attributed.contains(d.range.lowerBound) {
                    diag(AbsolutePosition(utf8Offset: d.range.lowerBound), .error, "TRS0102",
                         "\"\(d.text)\" isn't attached to a function: put it in the comments directly above the func")
                }
            }
        }

        // Files holding pure code import only what the model can use.
        if result.functions.contains(where: \.pure) {
            for item in tree.statements {
                guard let imp = item.item.as(ImportDeclSyntax.self) else { continue }
                let module = imp.path.map(\.name.text).joined(separator: ".")
                let root = imp.path.first?.name.text ?? module
                if !allowedImports.contains(root) && !allow.contains(root) && !allow.contains("TRS0308") {
                    diag(imp.positionAfterSkippingLeadingTrivia, .error, "TRS0308",
                         "this file holds pure functions but imports \(module); the model has no UI or system services: move the pure functions to a file that imports only Foundation, or allow it with --allow \(root)")
                }
            }
        }
        result.diagnostics.sort { ($0.line, $0.column) < ($1.line, $1.column) }
        return result
    }

    struct Found {
        var directive: Directive
        var text: String
        var range: Range<Int>
    }

    static func directives(in trivia: Trivia, startingAt start: Int) -> [Found] {
        var out: [Found] = []
        var offset = start
        for piece in trivia {
            let length = piece.sourceLength.utf8Length
            if case let .lineComment(text) = piece, let d = Directive.parse(text) {
                out.append(Found(directive: d, text: text, range: offset..<(offset + length)))
            }
            offset += length
        }
        return out
    }

    static func typePath(of node: some SyntaxProtocol) -> String {
        var names: [String] = []
        var current = node.parent
        while let p = current {
            if let s = p.as(StructDeclSyntax.self) { names.append(s.name.text) }
            else if let c = p.as(ClassDeclSyntax.self) { names.append(c.name.text) }
            else if let e = p.as(EnumDeclSyntax.self) { names.append(e.name.text) }
            else if let a = p.as(ActorDeclSyntax.self) { names.append(a.name.text) }
            else if let x = p.as(ExtensionDeclSyntax.self) { names.append(x.extendedType.trimmedDescription) }
            current = p.parent
        }
        return names.reversed().joined(separator: ".")
    }
}

final class FunctionFinder: SyntaxVisitor {
    var functions: [FunctionDeclSyntax] = []
    override func visit(_ node: FunctionDeclSyntax) -> SyntaxVisitorContinueKind {
        functions.append(node)
        return .visitChildren
    }
}

final class DeclarationCollector: SyntaxVisitor {
    var globals: Set<String> = []
    var statics: Set<String> = []
    var functions: Set<String> = []
    var pure: Set<String> = []

    override func visit(_ node: VariableDeclSyntax) -> SyntaxVisitorContinueKind {
        guard node.bindingSpecifier.tokenKind == .keyword(.var) else { return .skipChildren }
        let names = node.bindings.compactMap { $0.pattern.as(IdentifierPatternSyntax.self)?.identifier.text }
        let isStatic = node.modifiers.contains { $0.name.tokenKind == .keyword(.static) || $0.name.tokenKind == .keyword(.class) }
        let typePath = Scanner.typePath(of: node)
        if isStatic && !typePath.isEmpty {
            statics.formUnion(names.map { "\(typePath).\($0)" })
        } else if typePath.isEmpty && !isInsideFunctionOrClosure(node) {
            globals.formUnion(names)
        }
        return .skipChildren
    }

    override func visit(_ node: FunctionDeclSyntax) -> SyntaxVisitorContinueKind {
        let typePath = Scanner.typePath(of: node)
        let key = typePath.isEmpty ? node.name.text : "\(typePath).\(node.name.text)"
        functions.insert(key)
        let ds = Scanner.directives(in: node.leadingTrivia, startingAt: 0)
        if ds.contains(where: { if case .pure = $0.directive { return true }; if case .link = $0.directive { return true }; return false }) {
            pure.insert(key)
        }
        return .visitChildren
    }

    private func isInsideFunctionOrClosure(_ node: some SyntaxProtocol) -> Bool {
        var current = node.parent
        while let p = current {
            if p.is(FunctionDeclSyntax.self) || p.is(ClosureExprSyntax.self) || p.is(InitializerDeclSyntax.self)
                || p.is(AccessorBlockSyntax.self) {
                return true
            }
            current = p.parent
        }
        return false
    }
}
