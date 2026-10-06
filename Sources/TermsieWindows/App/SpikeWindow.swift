import Foundation
import WinSDK
import CTermsieWin
import SwiftTerm
import TermsieCore

/// Phase 0 of the Windows plan: one window, one shell in a pseudo console, drawn with Direct2D.
/// Proves the toolchain, ConPTY and rendering on a real Windows machine before the app is built
/// on top of them.
///
///   Termsie.exe --snapshot out.png [--type "dir\r"] [--wait 4] [--log log.txt] [--quit]
final class SpikeWindow: Window {
    private var renderer: Renderer?
    private var session: TerminalSession!
    private var fonts: TerminalFonts!
    private var palette: TerminalPalette!
    private var assembler = SurrogateAssembler()
    private var redrawPending = false
    private let padding: CGFloat = 8

    static func run() {
        Window.registerClass("TermsieSpike")
        let window = SpikeWindow()
        guard window.create(className: "TermsieSpike", title: "Termsie",
                            style: Win.WS_OVERLAPPEDWINDOW | Win.WS_CLIPCHILDREN,
                            exStyle: Win.WS_EX_NOREDIRECTIONBITMAP,
                            width: 1000, height: 700) else {
            Log.write("spike: could not create the window")
            MessageLoop.quit(1)
            return
        }
        window.setUp()
        ShowWindow(window.hwnd, Win.SW_SHOW)
        UpdateWindow(window.hwnd)
        window.scheduleScriptedRun()
    }

    private func setUp() {
        let config = ConfigStore.shared.config
        _ = tw_window_set_appearance(hwnd, 1, 1)
        renderer = Renderer(window: self)
        renderer?.syncSize()
        let spec = config.resolvedFontSpec(family: nil, size: nil)
        fonts = TerminalFonts(family: spec.family, size: spec.size, dpi: dpi)
        palette = TerminalPalette(config: config, background: config.backgroundRGBA(for: nil))
        let grid = gridSize()
        session = TerminalSession(cols: grid.cols, rows: grid.rows, config: config)
        session.onOutput = { [weak self] in self?.setNeedsDisplay() }
        session.onNeedsDisplay = { [weak self] in self?.setNeedsDisplay() }
        session.onTitle = { [weak self] t in self?.title = "Termsie — \(t)" }
        session.onExit = { [weak self] code in
            self?.session.feed(text: "\r\n[process exited with code \(code)]\r\n")
        }

        var env = ProcessInfo.processInfo.environment
        for key in env.keys where key.hasPrefix("TERMSIE_") { env.removeValue(forKey: key) }
        env["TERM"] = "xterm-256color"
        env["COLORTERM"] = "truecolor"
        env["TERM_PROGRAM"] = "Termsie"
        env["TERM_PROGRAM_VERSION"] = AppInfo.version
        env["TERMSIE_PANE_ID"] = "t-spike"
        let shell = config.resolvedShell
        let plan = ShellIntegration.prepare(shell: shell, shellArgs: config.shellArgs, paneKey: "t-spike",
                                            commands: [], isolateHistory: true, config: config, inheritedEnv: env)
        env.merge(plan.environment) { _, new in new }
        do {
            try session.start(executable: shell, arguments: plan.shellArgs, environment: env,
                              directory: HomePath.home)
            Log.write("spike: started \(shell) as \(session.pid)")
        } catch {
            Log.write("spike: \(error)")
            session.feed(text: "\u{1b}[31m\(error)\u{1b}[0m\r\n")
        }
    }

    private func gridSize() -> (cols: Int, rows: Int) {
        let size = clientPixelSize
        let w = CGFloat(size.width) / CGFloat(scale) - 2 * padding
        let h = CGFloat(size.height) / CGFloat(scale) - 2 * padding
        let m = fonts?.metrics ?? .fallback
        return (max(2, Int(w / m.cellWidth)), max(1, Int(h / m.cellHeight)))
    }

    private func setNeedsDisplay() {
        guard !redrawPending else { return }
        redrawPending = true
        MainQueue.shared.after(0.008) { [weak self] in
            guard let self else { return }
            self.redrawPending = false
            self.paint()
        }
    }

    private func drawFrame() {
        guard let renderer else { return }
        let size = clientPixelSize
        let bounds = CGRect(x: 0, y: 0, width: CGFloat(size.width) / CGFloat(scale),
                            height: CGFloat(size.height) / CGFloat(scale))
        renderer.clear(TWColor(palette.background, alpha: 1))
        let text = bounds.insetBy(dx: padding, dy: padding)
        TerminalPainter.draw(session, in: text, renderer: renderer, fonts: fonts, palette: palette,
                             options: .init(focused: GetFocus() == hwnd, cursorPhaseOn: true))
    }

    private func paint() {
        guard let renderer, session != nil else { return }
        renderer.syncSize()
        if !renderer.draw({ drawFrame() }) {
            Log.write("spike: device lost; rebuilding the renderer")
            self.renderer = Renderer(window: self)
        }
    }

    // MARK: Scripted run

    private func value(of flag: String) -> String? {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
        return args[i + 1]
    }

    private func scheduleScriptedRun() {
        if let log = value(of: "--log") { DebugOutput.open(path: log) }
        guard let snapshot = value(of: "--snapshot") else { return }
        let wait = Double(value(of: "--wait") ?? "4") ?? 4
        if let typed = value(of: "--type") {
            MainQueue.shared.after(wait / 2) { [weak self] in
                let text = typed.replacingOccurrences(of: "\\r", with: "\r")
                self?.session.send(text: text)
            }
        }
        MainQueue.shared.after(wait) { [weak self] in
            guard let self, let renderer = self.renderer else { return }
            let size = self.clientPixelSize
            let ok = renderer.snapshot(to: snapshot, width: size.width, height: size.height) { self.drawFrame() }
            DebugOutput.print("snapshot=\(ok ? "ok" : "failed") path=\(snapshot)")
            DebugOutput.print("cols=\(self.session.terminal.cols) rows=\(self.session.terminal.rows) pid=\(self.session.pid)")
            DebugOutput.print("shell=\(ConfigStore.shared.config.resolvedShell)")
            DebugOutput.print("--- screen")
            DebugOutput.print(self.session.screenText)
            DebugOutput.print("--- end")
            if CommandLine.arguments.contains("--quit") {
                self.session.terminate()
                MainQueue.shared.after(0.5) { MessageLoop.quit(0) }
            }
        }
    }

    // MARK: Messages

    override func handle(_ msg: UINT, _ wParam: WPARAM, _ lParam: LPARAM) -> LRESULT? {
        switch msg {
        case Win.WM_PAINT:
            var ps = PAINTSTRUCT()
            BeginPaint(hwnd, &ps)
            EndPaint(hwnd, &ps)
            paint()
            return 0
        case Win.WM_ERASEBKGND:
            return 1
        case Win.WM_SIZE:
            guard session != nil else { return 0 }
            renderer?.syncSize()
            let grid = gridSize()
            session.resize(cols: grid.cols, rows: grid.rows)
            paint()
            return 0
        case Win.WM_DPICHANGED:
            let spec = ConfigStore.shared.config.resolvedFontSpec(family: nil, size: nil)
            fonts = TerminalFonts(family: spec.family, size: spec.size, dpi: Float(LOWORD(wParam)))
            if let rect = UnsafePointer<RECT>(bitPattern: Int(lParam))?.pointee {
                SetWindowPos(hwnd, nil, rect.left, rect.top, rect.right - rect.left, rect.bottom - rect.top,
                             Win.SWP_NOZORDER | Win.SWP_NOACTIVATE)
            }
            return 0
        case Win.WM_KEYDOWN, Win.WM_SYSKEYDOWN:
            let mods = KeyEncoder.Modifiers.current
            if mods == [.control, .shift], Int32(wParam) == 0x56 {   // Ctrl+Shift+V
                if let text = Clipboard.get(owner: hwnd) { session.paste(text) }
                return 0
            }
            if let bytes = KeyEncoder.keyDown(vk: Int32(wParam), modifiers: mods,
                                              applicationCursor: session.terminal.applicationCursor) {
                session.send(user: bytes)
                return 0
            }
            return msg == Win.WM_SYSKEYDOWN ? nil : 0
        case Win.WM_CHAR, Win.WM_SYSCHAR:
            let unit = UInt16(truncatingIfNeeded: wParam)
            if unit == 0x08 || unit == 0x7f { return 0 }
            guard let text = assembler.add(unit) else { return 0 }
            var bytes = Array(text.utf8)
            if msg == Win.WM_SYSCHAR { bytes.insert(0x1b, at: 0) }
            session.send(user: bytes)
            return 0
        case Win.WM_MOUSEWHEEL:
            session.scroll(by: -Int(wheelDelta(wParam) / Win.WHEEL_DELTA) * 3)
            return 0
        case Win.WM_SETFOCUS, Win.WM_KILLFOCUS:
            setNeedsDisplay()
            return 0
        case Win.WM_DESTROY:
            session?.terminate()
            MessageLoop.quit(0)
            return 0
        default:
            return nil
        }
    }
}
