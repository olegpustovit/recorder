import AppKit
import SwiftUI
import RecorderCore
import Observation

enum UIKitGallery {
    private static var window: NSWindow?
    private static var agentStudy: AgentPanelReplayStudy?

    @MainActor static func showAgentStudy() {
        Task {
            do {
                if agentStudy?.closed != false { agentStudy = try await AgentPanelReplayStudy.make() }
                agentStudy?.controller?.window?.makeKeyAndOrderFront(nil)
                NSApp.activate()
            } catch { NSLog("Claude panel study unavailable: %@", error.localizedDescription) }
        }
    }

    @MainActor static func show() {
        if window == nil { window = makeWindow() }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    @MainActor static func makeWindow(onPanelsReady: @escaping (EditorModel) -> Void = { _ in }) -> NSWindow {
        let advanced = CommandLine.arguments.contains("--gallery-advanced")
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1120, height: 760),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.title = advanced ? "Recorder / gallery-advanced" : "Signal UI / Component Gallery"
        window.appearance = NSAppearance(named: advanced && !CommandLine.arguments.contains("--gallery-dark") ? .aqua : .darkAqua)
        window.titlebarAppearsTransparent = true
        window.backgroundColor = Theme.bgWindow
        window.minSize = NSSize(width: 900, height: 620)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: UIKitGalleryView(advanced: advanced, onPanelsReady: onPanelsReady))
        window.center()
        return window
    }

    @MainActor static func renderPNG(to url: URL) async throws {
        enum Failure: Error { case capture }
        var panelsReady = false
        let window = makeWindow { _ in panelsReady = true }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
        defer { window.orderOut(nil) }
        guard let view = window.contentView else { throw Failure.capture }
        view.layoutSubtreeIfNeeded()
        let advanced = CommandLine.arguments.contains("--gallery-advanced")
        let overlay = advanced ? nil : try await WorkspacePreviewContainer.snapshot(in: view)
        defer { overlay?.removeFromSuperview() }
        func capture(_ destination: URL) throws {
            // Capture this window's composited pixels, including native and Metal views.
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            process.arguments = ["-x", "-o", "-l", String(window.windowNumber), destination.path]
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { throw Failure.capture }
        }
        if CommandLine.arguments.contains("--gallery-check") {
            try await Task.sleep(for: .milliseconds(80))
            try capture(url.deletingPathExtension().appendingPathExtension("entrance.png"))
            try await Task.sleep(for: .milliseconds(160))
            try capture(url.deletingPathExtension().appendingPathExtension("stagger.png"))
            try await Task.sleep(for: .milliseconds(660))
        } else {
            try await Task.sleep(for: .milliseconds(900))
        }
        if advanced {
            func containsEditor(_ view: NSView) -> Bool {
                view is PreviewView || view is TimelineView || view.subviews.contains(where: containsEditor)
            }
            guard panelsReady, !containsEditor(view) else { throw Failure.capture }
        }
        if advanced && !CommandLine.arguments.contains("--gallery-dark") {
            guard window.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .aqua else { throw Failure.capture }
        }
        try capture(url)
        if CommandLine.arguments.contains("--gallery-check") {
            guard advanced, CommandLine.arguments.contains("--gallery-demo") else { throw Failure.capture }
            for (step, expected) in [NSAppearance.Name.aqua, .darkAqua, .aqua, .aqua, .darkAqua, .aqua].enumerated() {
                try await Task.sleep(for: .seconds(2.4))
                guard window.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == expected else {
                    throw Failure.capture
                }
                try capture(url.deletingPathExtension().appendingPathExtension("step-\(step).png"))
                if step == 0 { window.setContentSize(NSSize(width: 900, height: 620)) }
                if step == 1 { window.setContentSize(NSSize(width: 1120, height: 760)) }
            }
            window.setContentSize(NSSize(width: 900, height: 620))
            try await Task.sleep(for: .milliseconds(600))
            try capture(url.deletingPathExtension().appendingPathExtension("minimum.png"))
            print("Gallery demo completed: scroll stages, both appearances, minimum size")
        }
    }
}

private struct UIKitGalleryView: View {
    var advanced = false
    var onPanelsReady: (EditorModel) -> Void = { _ in }
    @State private var light = !CommandLine.arguments.contains("--gallery-dark")
    @State private var capturePreview = false
    @State private var replay = 0
    @State private var demo = CommandLine.arguments.contains("--gallery-demo")
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var name = "Capture 042"
    @State private var enabled = true
    @State private var slider = 0.64
    @State private var mode = CommandLine.arguments.contains("--gallery-advanced") ? 0 : 1
    @State private var search = ""
    @State private var selectionRect = CGRect(x: 120, y: 80, width: 960, height: 540)

    var body: some View {
        ZStack {
            Theme.bgWindowColor.ignoresSafeArea()
            ScrollViewReader { proxy in
                VStack(spacing: 0) {
                    if advanced { themeRail }
                    ScrollView {
                        if advanced {
                            presentation.padding(.horizontal, 40).padding(.vertical, 28)
                        } else {
                            VStack(alignment: .leading, spacing: 12) {
                                masthead.modifier(GalleryReveal(enabled: advanced, order: 0, replay: replay)).id("intro")
                                if !advanced { workspace }
                                HStack {
                                    Text("Claude panel motion study").font(Font(Theme.headingFont(24)))
                                    Spacer()
                                    Button("Open study…") { UIKitGallery.showAgentStudy() }
                                        .buttonStyle(TechButtonStyle(kind: .secondary, compact: true))
                                }.padding(.vertical, 12)
                                TimelineInteractionPrototype(
                                    autoAudition: CommandLine.arguments.contains("--ui-gallery-audition"),
                                    scrollReveals: advanced, galleryReplay: replay
                                ).id("motion")
                                HStack(alignment: .top, spacing: 12) {
                                    typography.modifier(GalleryReveal(enabled: advanced, order: 0, replay: replay))
                                    colors.modifier(GalleryReveal(enabled: advanced, order: 1, replay: replay))
                                }.frame(height: 154).id("elements")
                                HStack(alignment: .top, spacing: 12) {
                                    controls.modifier(GalleryReveal(enabled: advanced, order: 0, replay: replay))
                                    inputs.modifier(GalleryReveal(enabled: advanced, order: 1, replay: replay))
                                }.frame(height: 250)
                                states.fixedSize(horizontal: false, vertical: true)
                                    .modifier(GalleryReveal(enabled: advanced, order: 0, replay: replay))
                                floatingPanels.fixedSize(horizontal: false, vertical: true)
                                    .modifier(GalleryReveal(enabled: advanced, order: 0, replay: replay))
                                signature
                            }
                            .padding(28)
                        }
                    }
                    .onScrollPhaseChange { _, phase in
                        if phase == .interacting { demo = false }
                    }
                }
                .task(id: demo) {
                    guard advanced && demo else { return }
                    light = true
                    capturePreview = false
                    mode = 0
                    proxy.scrollTo("intro", anchor: .top)
                    replay += 1
                    do {
                        for (section, white) in [("elements", true), ("elements", false), ("keys", true),
                                                 ("capture", true), ("widgets", false), ("intro", true)] {
                            try await Task.sleep(for: .seconds(2.4))
                            light = white
                            capturePreview.toggle()
                            mode = (mode + 1) % 3
                            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.7)) {
                                slider = section == "elements" ? 0.85 : 0.36
                                proxy.scrollTo(section, anchor: .top)
                            }
                        }
                        demo = false
                    } catch { /* Direct scrolling and Stop demo cancel the sequence. */ }
                }
            }
        }
        .font(Font(Theme.bodyFont))
        .foregroundStyle(Theme.textPrimaryColor)
        .tint(Theme.accentColor)
        .preferredColorScheme(advanced && light ? .light : .dark)
    }

    private var presentation: some View {
        VStack(alignment: .leading, spacing: 32) {
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .lastTextBaseline) {
                    Text("Recorder").font(Font(Theme.headingFont(64)))
                    Spacer()
                    Text("Motion & detail").font(Font(Theme.labelFont))
                        .foregroundStyle(Theme.textSecondaryColor)
                }
                .modifier(GalleryReveal(enabled: true, order: 0, replay: replay))
                TimelineInteractionPrototype(scrollReveals: true, galleryReplay: replay, presentation: true)
            }.id("intro")

            GalleryInspectorStudies(replay: replay, onReady: onPanelsReady).id("elements")

            HStack(alignment: .top, spacing: 24) {
                VStack(alignment: .leading, spacing: 20) {
                    studyHeading("06", "Capture")
                    TechSegmentedControl(selection: Binding(get: { mode }, set: { demo = false; mode = $0 }),
                                         options: [(0, "Display"), (1, "Window"), (2, "Area")])
                    Toggle("Microphone", isOn: Binding(get: { enabled }, set: { demo = false; enabled = $0 }))
                        .toggleStyle(TechToggleStyle())
                    Spacer(minLength: 0)
                    Button(capturePreview ? "Reset preview" : "Preview capture") {
                        demo = false
                        capturePreview.toggle()
                    }.buttonStyle(TechButtonStyle(kind: .primary))
                }.frame(width: 250, height: 238, alignment: .topLeading)
                    .modifier(GalleryReveal(enabled: true, order: 0, replay: replay))
                captureCanvas.modifier(GalleryReveal(enabled: true, order: 1, replay: replay))
            }.id("capture")

            HStack(alignment: .top, spacing: 24) {
                VStack(alignment: .leading, spacing: 20) {
                    studyHeading("07", "Actions")
                    HStack(spacing: 8) {
                        Button(capturePreview ? "Selected" : "Select") { capturePreview.toggle() }
                            .buttonStyle(TechButtonStyle(kind: .primary))
                        Button("Reset") { capturePreview = false; slider = 0.64 }
                            .buttonStyle(TechButtonStyle())
                        Menu { Button("White") { light = true }; Button("Black") { light = false } }
                            label: { TechMenuLabel(title: "Theme") }
                            .menuStyle(.borderlessButton).fixedSize()
                    }
                    HStack(spacing: 8) {
                        ForEach(["display", "macwindow", "rectangle.dashed"].indices, id: \.self) { index in
                            Button { mode = index } label: {
                                Image(systemName: ["display", "macwindow", "rectangle.dashed"][index])
                                    .frame(width: 24, height: 24)
                            }
                            .buttonStyle(TechButtonStyle(kind: mode == index ? .primary : .secondary))
                            .accessibilityLabel(["Display", "Window", "Area"][index])
                        }
                        Spacer()
                        Text("⌘").padding(8).background(Theme.bgControlColor)
                        Text("K").padding(8).background(Theme.bgControlColor)
                    }
                    HStack(spacing: 4) {
                        ForEach([Theme.textPrimaryColor, Theme.textSecondaryColor, Theme.strokeStrongColor, Theme.bgHoverColor].indices, id: \.self) { index in
                            [Theme.textPrimaryColor, Theme.textSecondaryColor, Theme.strokeStrongColor, Theme.bgHoverColor][index]
                                .frame(height: 24)
                        }
                    }.accessibilityLabel("Theme tones")
                }.frame(maxWidth: .infinity)
                    .modifier(GalleryReveal(enabled: true, order: 0, replay: replay))
                VStack(alignment: .leading, spacing: 20) {
                    studyHeading("08", "Inputs")
                    TextField("Recording name", text: $name).textFieldStyle(TechFieldStyle())
                    TechSearchField(placeholder: "Search projects", text: $search, width: 260)
                    HStack {
                        Text("Scale").foregroundStyle(Theme.textSecondaryColor)
                        Slider(value: $slider).accessibilityLabel("Scale study")
                        Text(slider, format: .percent.precision(.fractionLength(0)))
                            .frame(width: 40, alignment: .trailing)
                    }
                }.frame(maxWidth: .infinity)
                    .modifier(GalleryReveal(enabled: true, order: 1, replay: replay))
            }.id("widgets")

            HStack {
                Text("Recorder")
                Spacer()
                Text("Motion & detail")
            }.font(Font(Theme.labelFont)).foregroundStyle(Theme.textSecondaryColor)
                .padding(.top, 12)
        }
        .padding(.bottom, 160)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.28), value: capturePreview)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.28), value: mode)
    }

    private func studyHeading(_ index: String, _ title: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 16) {
            Text(index).font(Font(Theme.captionFont)).foregroundStyle(Theme.textSecondaryColor)
            Text(title).font(Font(Theme.headingFont(32)))
            Spacer()
        }
        .padding(.top, 16)
        .overlay(alignment: .top) { Theme.strokeColor.frame(height: 1) }
    }

    private var captureCanvas: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            ZStack {
                Theme.textPrimaryColor
                // The target geometry follows the source choice; no screen capture is started.
                VStack(spacing: 0) {
                    HStack(spacing: 5) {
                        ForEach(0..<3) { _ in Circle().fill(Theme.bgWindowColor.opacity(0.5)).frame(width: 4, height: 4) }
                        Spacer()
                    }.padding(12)
                    Rectangle().fill(Theme.bgWindowColor.opacity(0.18)).frame(height: 1)
                    Spacer()
                    HStack(alignment: .bottom, spacing: 12) {
                        Text("Aa").font(Font(Theme.headingFont(mode == 2 ? 44 : 72)))
                        Spacer(minLength: 0)
                        HStack(alignment: .bottom, spacing: 5) {
                            ForEach(0..<4) { index in
                                Rectangle().fill(Theme.bgWindowColor.opacity(0.3 + Double(index) * 0.2))
                                    .frame(width: 9, height: CGFloat(capturePreview ? 4 - index : index + 1) * 16)
                            }
                        }
                    }
                    .foregroundStyle(Theme.bgWindowColor)
                    .padding(.horizontal, 20)
                    Spacer()
                }
                .frame(width: width * (mode == 0 ? 0.82 : mode == 1 ? 0.64 : 0.46),
                       height: mode == 2 ? 128 : 174)
                .overlay(Rectangle().stroke(Theme.bgWindowColor.opacity(capturePreview ? 1 : 0.45), lineWidth: 1))
                .scaleEffect(capturePreview ? 0.94 : 1)
                VStack {
                    Spacer()
                    HStack {
                        Text(["Display", "Window", "Area"][mode])
                        Spacer()
                        Image(systemName: enabled ? "mic" : "mic.slash")
                    }.font(Font(Theme.captionFont)).foregroundStyle(Theme.bgWindowColor.opacity(0.7))
                }.padding(18)
            }
        }
        .frame(height: 238)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Capture preview")
        .accessibilityValue("\(["Display", "Window", "Area"][mode]), microphone \(enabled ? "on" : "off"), \(capturePreview ? "selected" : "ready")")
    }

    private var workspace: some View {
        Group {
            EditorWorkspaceGallery().frame(height: 785)
                .modifier(GalleryReveal(enabled: advanced, order: 1, replay: replay))
            TechPanel(index: "01", title: "Editor timeline · production") {
                ProductionTimelinePreview().frame(height: 250)
            }.modifier(GalleryReveal(enabled: advanced, order: 0, replay: replay))
        }
    }

    private var themeRail: some View {
        HStack(spacing: 8) {
            Text("Recorder / Studies").font(Font(Theme.labelFont))
            Spacer()
            ForEach([true, false], id: \.self) { isLight in
                Button { demo = false; light = isLight } label: {
                    Label(isLight ? "White" : "Black", systemImage: isLight ? "sun.max" : "moon")
                }
                .buttonStyle(TechButtonStyle(kind: light == isLight ? .primary : .secondary))
                .accessibilityAddTraits(light == isLight ? .isSelected : [])
            }
            Button { demo = false; replay += 1 } label: {
                Image(systemName: "arrow.clockwise").frame(width: 18)
            }
                .help("Replay reveals").accessibilityLabel("Replay reveals")
                .buttonStyle(TechButtonStyle())
            Button(demo ? "Stop demo" : "Play demo") { demo.toggle() }
                .buttonStyle(TechButtonStyle())
        }
        .padding(.horizontal, 40).padding(.vertical, 12)
        .background(Theme.bgPanelColor)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.strokeColor).frame(height: 1) }
    }

    private var masthead: some View {
        HStack(alignment: .bottom) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text("Recorder").font(Font(Theme.headingFont(44)))
                    Image(systemName: "arrow.up.right").font(.system(size: 20, weight: .heavy))
                        .accessibilityHidden(true)
                }
                Text("Interface components")
                    .font(Font(Theme.labelFont)).foregroundStyle(Theme.textSecondaryColor)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 6) {
                Text("01—07")
                    .font(Font(Theme.headingFont(26)))
                    .foregroundStyle(Theme.bgWindowColor)
                    .padding(.horizontal, 12).padding(.top, 8).padding(.bottom, 2)
                    .background(Theme.textPrimaryColor)
                Text("Type, controls & timeline")
                    .font(Font(Theme.captionFont)).foregroundStyle(Theme.textTertiaryColor)
            }
        }
        .padding(.bottom, 12)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.textPrimaryColor).frame(height: 3) }
    }

    private var typography: some View {
        TechPanel(index: "01", title: "Typography") {
            VStack(alignment: .leading, spacing: 10) {
                Text("Screen recording").font(Font(Theme.headingFont(26)))
                Text("Barlow Semi Condensed Light / Andale Mono")
                    .font(Font(Theme.labelFont)).foregroundStyle(Theme.accentColor)
                Text("00:14:32:18  ·  3840×2160  ·  60 fps")
                    .font(Font(Theme.timecodeFont(12))).foregroundStyle(Theme.textSecondaryColor)
            }
        }
    }

    private var colors: some View {
        TechPanel(index: "02", title: "Surfaces") {
            HStack(spacing: 8) {
                swatch("Ink", Theme.textPrimaryColor)
                swatch("Text", Theme.textSecondaryColor)
                swatch("Border", Theme.strokeStrongColor)
                swatch("Control", Theme.bgHoverColor)
            }
            Text(advanced && light ? "White background. Black foreground." : "Black background. White foreground.")
                .font(Font(Theme.captionFont)).foregroundStyle(Theme.textSecondaryColor)
        }
    }

    private var controls: some View {
        TechPanel(index: "03", title: "Actions") {
            HStack(spacing: 4) {
                Button("Record") {}.buttonStyle(TechButtonStyle(kind: .primary))
                Button("Export") {}.buttonStyle(TechButtonStyle())
                Button("Cancel") {}.buttonStyle(TechButtonStyle(kind: .quiet))
                Button("Unavailable") {}.buttonStyle(TechButtonStyle()).disabled(true)
            }
            HStack(spacing: 8) {
                Text("Native AppKit")
                    .font(Font(Theme.captionFont)).foregroundStyle(Theme.textTertiaryColor)
                TechAppKitButtonPreview(title: "Timeline action")
                    .fixedSize()
                Menu { Button("Example") {} } label: { TechMenuLabel(title: "Menu") }
                    .menuStyle(.borderlessButton).fixedSize()
            }
            HStack(spacing: 8) {
                ForEach(["display", "macwindow", "rectangle.dashed"], id: \.self) { icon in
                    Button {} label: { Image(systemName: icon).frame(width: 18, height: 18) }
                        .buttonStyle(TechButtonStyle(kind: .secondary, compact: true))
                }
                Button {} label: {
                    HStack(spacing: 0) {
                        Theme.textPrimaryColor
                        Theme.bgHoverColor
                    }
                    .frame(width: 54, height: 26)
                }
                .buttonStyle(TechSelectableTileStyle(selected: true))
            }
            HStack {
                Text("Start recording").foregroundStyle(Theme.textSecondaryColor)
                Spacer()
                Text("⌘ N").foregroundStyle(Theme.textPrimaryColor)
            }
            .font(Font(Theme.captionFont))
            .padding(.top, 8)
            .overlay(alignment: .top) { Theme.strokeColor.frame(height: 1) }
        }
    }

    private var inputs: some View {
        TechPanel(index: "04", title: "Inputs") {
            TextField("Recording name", text: $name).textFieldStyle(TechFieldStyle())
            TechSearchField(placeholder: "Search projects", text: $search, width: 260)
            Toggle("Include microphone", isOn: $enabled).toggleStyle(TechToggleStyle())
            HStack {
                Text("Gain").font(Font(Theme.captionFont)).foregroundStyle(Theme.textSecondaryColor)
                Slider(value: $slider).tint(Theme.accentColor).labelsHidden()
                Text(slider, format: .percent.precision(.fractionLength(0)))
                    .font(Font(Theme.timecodeFont(11))).frame(width: 38, alignment: .trailing)
            }
            TechSegmentedControl(selection: $mode,
                                 options: [(0, "Display"), (1, "Window"), (2, "Area")])
                .frame(width: 220)
        }
    }

    private var states: some View {
        TechPanel(index: "05", title: "Status + data") {
            HStack(spacing: 18) {
                TechStatus(title: "Ready", color: Theme.textPrimaryColor)
                TechStatus(title: "Recording", color: Theme.dangerColor)
                TechStatus(title: "Paused", color: Theme.warningColor)
            }
            HStack(spacing: 8) {
                metric("Duration", "14:32")
                metric("Frames", "52.3k")
                metric("Dropped", "000")
            }
            HStack {
                Text("Export progress")
                Spacer()
                Text("72%")
            }.font(Font(Theme.captionFont)).foregroundStyle(Theme.textSecondaryColor)
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Theme.bgHoverColor
                    Theme.textPrimaryColor.frame(width: geometry.size.width * 0.72)
                }
            }.frame(height: 6)
        }
    }

    private var floatingPanels: some View {
        TechPanel(index: "07", title: "Floating capture") {
            VStack(alignment: .leading, spacing: 10) {
                ToolbarView(onClose: {}, onSelectMode: { _ in }, onCamera: {}, onMicrophone: {},
                            onSystemAudio: {}, onSettings: {})
                HStack(spacing: 12) {
                    RecordingWidgetView(state: WidgetState(elapsed: 42), onFinish: {}, onPause: {},
                                        onResume: {}, onRestart: {}, onDelete: {})
                    CountdownView(state: CountdownState(remaining: 3))
                        .scaleEffect(0.42)
                        .frame(width: 68, height: 48)
                }
                HStack(spacing: 12) {
                    AreaFieldsView(rect: $selectionRect).fixedSize()
                    StartRecordingButton(action: {})
                }
            }
        }
    }

    private var timeline: some View {
        TechPanel(index: "06", title: "Timeline") {
            VStack(spacing: 6) {
                HStack {
                    Text("00:00")
                    Spacer()
                    Text("00:15")
                    Spacer()
                    Text("00:30")
                }
                .font(Font(Theme.captionFont)).foregroundStyle(Theme.textTertiaryColor)
                .padding(.leading, 51)
                lane(label: "Video", color: Theme.clipColor, widths: [0.32, 0.16, 0.42])
                lane(label: "Zoom", color: Theme.zoomColor, widths: [0.14, 0.26])
                lane(label: "Layout", color: Theme.layoutColor, widths: [0.38])
                lane(label: "Mask", color: Theme.maskColor, widths: [0.18, 0.12])
            }
        }
    }

    private var signature: some View {
        HStack {
            Text("Recorder")
            Spacer()
            Text("Component gallery")
        }
        .font(Font(Theme.captionFont)).foregroundStyle(Theme.textTertiaryColor)
    }

    private func swatch(_ label: String, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            color.frame(height: 24)
            Text(label).font(Font(Theme.captionFont)).foregroundStyle(Theme.textSecondaryColor)
        }.frame(maxWidth: .infinity)
    }

    private func metric(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).font(Font(Theme.captionFont)).foregroundStyle(Theme.textTertiaryColor)
            Text(value).font(Font(Theme.headingFont(26))).foregroundStyle(Theme.textPrimaryColor)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func lane(label: String, color: Color, widths: [CGFloat]) -> some View {
        HStack(spacing: 5) {
            Text(label).font(Font(Theme.captionFont)).foregroundStyle(Theme.textTertiaryColor)
                .frame(width: 46, alignment: .leading)
            GeometryReader { geometry in
                HStack(spacing: 4) {
                    ForEach(Array(widths.enumerated()), id: \.offset) { index, width in
                        Rectangle().fill(color).frame(width: geometry.size.width * width)
                            .overlay(alignment: .leading) {
                                Text(String(format: "%02d", index + 1))
                                    .font(Font(Theme.captionFont)).foregroundStyle(Theme.bgWindowColor)
                                    .padding(.leading, 5)
                            }
                    }
                }
            }.frame(height: 23)
        }
    }
}

/// Individual production panels, composed as studies over a disposable project.
private struct GalleryInspectorStudies: View {
    let replay: Int
    let onReady: (EditorModel) -> Void
    @State private var model: EditorModel?
    @State private var mediaReady = false
    @State private var preparationError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            if let model {
                HStack(alignment: .top, spacing: 24) {
                    VStack(spacing: 24) {
                        TechPanel(index: "01", title: "Canvas") { BackgroundTab(model: model).disabled(!mediaReady) }
                            .fixedSize(horizontal: false, vertical: true)
                            .modifier(GalleryReveal(enabled: true, order: 0, replay: replay))
                        TechPanel(index: "03", title: "Cursor") { CursorTab(model: model) }
                            .fixedSize(horizontal: false, vertical: true)
                            .modifier(GalleryReveal(enabled: true, order: 0, replay: replay))
                    }.frame(maxWidth: .infinity, alignment: .top)
                    VStack(spacing: 24) {
                        TechPanel(index: "02", title: "Camera") {
                            CameraTab(model: model, showsTimelineActions: false)
                        }.fixedSize(horizontal: false, vertical: true)
                            .modifier(GalleryReveal(enabled: true, order: 1, replay: replay))
                        TechPanel(index: "04", title: "Motion") { AnimationsTab(model: model) }
                            .fixedSize(horizontal: false, vertical: true)
                            .modifier(GalleryReveal(enabled: true, order: 1, replay: replay))
                    }.frame(maxWidth: .infinity, alignment: .top)
                }
                HStack(alignment: .top, spacing: 24) {
                    TechPanel(index: "05", title: "Keystrokes") {
                        KeysTab(model: model, showsTimelineActions: false)
                    }.fixedSize(horizontal: false, vertical: true)
                        .modifier(GalleryReveal(enabled: true, order: 0, replay: replay))
                    VStack(alignment: .leading, spacing: 16) {
                        Text("Key display").font(Font(Theme.headingFont(32)))
                        GeometryReader { geometry in
                            let keys = model.project.keys
                            let label = activeKeyChip(events: model.events.events, atSource: 2,
                                                      hold: keys.hold, categories: keys.categories)?.label ?? ""
                            ZStack {
                                Theme.textPrimaryColor
                                if keys.show {
                                    Text(label).font(Font(Theme.timecodeFont(18 * keys.size)))
                                        .foregroundStyle(Theme.textPrimaryColor)
                                        .padding(12).background(Theme.bgWindowColor)
                                        .position(x: 70 + max(0, geometry.size.width - 140) * keys.position.x,
                                                  y: 40 + max(0, geometry.size.height - 80) * keys.position.y)
                                }
                            }
                        }.frame(height: 220)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                        .modifier(GalleryReveal(enabled: true, order: 1, replay: replay))
                }.id("keys")
                if let layer = model.project.layers.first, let id = UUID(uuidString: layer.id) {
                    TechPanel(index: "07", title: "Media layer") {
                        LayerPanel(model: model, layerID: id).frame(width: InspectorView.width - 36)
                    }.frame(width: InspectorView.width).fixedSize(horizontal: false, vertical: true)
                }
                if let preparationError {
                    Text(preparationError).foregroundStyle(Theme.dangerColor)
                }
            }
        }
        .toggleStyle(TechToggleStyle())
        .disclosureGroupStyle(InspectorDisclosureStyle())
        .task {
            guard model == nil else { return }
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("recorder-panel-studies-" + UUID().uuidString)
            let fixture = EditorWorkspaceGallery.makeModel(at: url)
            model = fixture
            onReady(fixture)
            do {
                try await WorkspaceMedia.prepare(at: url)
                try Task.checkCancellation()
                _ = try await fixture.importMedia(url.appendingPathComponent("screen.mov"), atOutput: 0)
                mediaReady = true
            } catch is CancellationError { }
            catch { preparationError = "Sample unavailable: " + error.localizedDescription }
        }
        .onDisappear {
            guard let model else { return }
            model.saveNow()
            try? FileManager.default.removeItem(at: model.packageURL)
            self.model = nil
            mediaReady = false
        }
    }
}

/// The actual editor widgets, backed by a disposable project rather than a second timeline implementation.
private struct ProductionTimelinePreview: NSViewRepresentable {
    final class Coordinator {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("recorder-gallery-" + UUID().uuidString)
        var model: EditorModel?
    }
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> TimelineContainerView {
        var project = Project(title: "Timeline study", source: Source(duration: 48, hasCamera: true))
        project.clips = [Clip(sourceStart: 0, sourceEnd: 16), Clip(sourceStart: 16, sourceEnd: 32, speed: 2),
                         Clip(sourceStart: 36, sourceEnd: 48)]
        project.zooms = [Zoom(start: 3, end: 9, scale: 2, mode: .auto), Zoom(start: 20, end: 29, scale: 1.6, mode: .manual)]
        project.keystrokeClips = [Layout(start: 4, end: 12, kind: .settings, keys: Keys(show: true))]
        project.cameraClips = [CameraClip(start: 0, end: 14), CameraClip(start: 20, end: 45)]
        project.liftClip(1)
        project.masks = [Mask(start: 38, end: 45, kind: .blur, rect: NormRect(x: 0.2, y: 0.2, w: 0.3, h: 0.3), opacity: 1)]
        try? FileManager.default.createDirectory(at: context.coordinator.url, withIntermediateDirectories: true)
        let model = EditorModel(packageURL: context.coordinator.url, project: project, events: EventLog())
        model.playhead = 11
        model.selection = [UUID(uuidString: project.zooms[0].id)!]
        context.coordinator.model = model
        let timeline = TimelineView(frame: .zero)
        timeline.model = model
        let toolbar = TimelineToolbar(frame: .zero)
        toolbar.timelineView = timeline
        return TimelineContainerView(toolbar: toolbar, timeline: timeline)
    }
    func updateNSView(_ view: TimelineContainerView, context: Context) {}
    static func dismantleNSView(_ view: TimelineContainerView, coordinator: Coordinator) {
        coordinator.model?.saveNow()
        view.timeline.model = nil
        coordinator.model = nil
        try? FileManager.default.removeItem(at: coordinator.url)
    }
}

/// Visibility is measured before the animated content, so reveal motion cannot retrigger itself.
private struct GalleryReveal: ViewModifier {
    let enabled: Bool
    let order: Int
    let replay: Int
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var visible = false
    @State private var revealed = false
    @State private var rule = false

    func body(content: Content) -> some View {
        content
            .opacity(!enabled || revealed ? 1 : 0.08)
            .offset(y: enabled && !revealed && !reduceMotion ? 12 : 0)
            .overlay(alignment: .topLeading) {
                if enabled && !reduceMotion {
                    Rectangle().fill(Theme.textPrimaryColor)
                        .frame(height: 1)
                        .scaleEffect(x: rule ? 1 : 0, anchor: .leading)
                        .opacity(revealed ? 0 : 1)
                        .allowsHitTesting(false).accessibilityHidden(true)
                }
            }
            .onScrollVisibilityChange(threshold: 0.1) { visible = $0 }
            .task(id: "\(visible)-\(replay)-\(reduceMotion)") {
                guard enabled else { return }
                guard visible else { revealed = false; rule = false; return }
                if reduceMotion { revealed = true; rule = true; return }
                revealed = false
                rule = false
                do {
                    try await Task.sleep(for: .milliseconds(40 + order * 80))
                    withAnimation(.easeOut(duration: 0.24)) { rule = true }
                    try await Task.sleep(for: .milliseconds(75))
                    withAnimation(.easeOut(duration: Theme.Motion.reveal)) { revealed = true }
                } catch { /* Visibility changes and replay cancel pending stages. */ }
            }
    }
}

/// Replay uses the production panel, draft replay and review renderer over generated media only.
@MainActor @Observable final class AgentPanelReplayStudy {
    weak var controller: EditorWindowController?
    let model: EditorModel
    let session = MCPSession()
    let package: URL
    let base: Project
    var generation = 0
    var playing = false
    var reducedMotion = false
    private(set) var closed = false

    private init(_ controller: EditorWindowController, package: URL) {
        self.controller = controller; model = controller.model; base = model.project; self.package = package
        session.agentName = "Claude · sample replay"; session.projectURL = model.packageURL.standardizedFileURL
        MCPServer.shared.register(session)
        model.inspectorShowsAgent = true
    }
    static func make() async throws -> AgentPanelReplayStudy {
        let package = FileManager.default.temporaryDirectory.appendingPathComponent("recorder-agent-study-\(UUID().uuidString).recorder")
        let sample = EditorWorkspaceGallery.makeModel(at: package)
        var project = sample.project
        project.title = "Claude panel motion study"; project.zooms = []
        try project.save(to: package.appendingPathComponent("project.json"))
        do {
            try await WorkspaceMedia.prepare(at: package)
            try Task.checkCancellation()
            guard let controller = await EditorWindowController.open(package: package).value else { throw CocoaError(.fileReadCorruptFile) }
            let study = AgentPanelReplayStudy(controller, package: package)
            controller.inspectorView = NSHostingView(rootView: AgentStudyInspector(study: study))
            let window = controller.window!, editor = window.contentView!
            let stack = NSStackView(); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 0
            let controls = NSHostingView(rootView: AgentStudyControls(study: study))
            stack.addArrangedSubview(editor); stack.addArrangedSubview(controls)
            window.contentView = stack
            NSLayoutConstraint.activate([editor.widthAnchor.constraint(equalTo: stack.widthAnchor),
                controls.widthAnchor.constraint(equalTo: stack.widthAnchor), controls.heightAnchor.constraint(equalToConstant: 44)])
            window.minSize.height += 44; window.setContentSize(NSSize(width: 1200, height: 804))
            return study
        } catch { try? FileManager.default.removeItem(at: package); throw error }
    }
    func reset() {
        try? MCPServer.shared.finishReview(session, commit: false)
        AgentActivity.shared.clear(sessionID: session.id)
        session.lastDraftVerdict = nil; session.reviewError = nil
        model.isPlaying = false
        if model.project != base { model.edit("Reset sample replay") { $0 = base } }
        model.inspectorShowsAgent = true
    }
    func run() async throws {
        reset()
        let speedStarts: [Double] = [2, 6, 10, 14, 18]
        let speeds: [EditOp] = speedStarts.map { EditOp.speed(from: $0, to: $0 + 2, speed: 2) }
        let times: [Double] = [0.3, 4.3, 8.3, 12.3, 18.3, 24.3]
        let labels = ["Project walkthrough", "Prepare", "Record", "Review", "Export", "Recap"]
        let texts: [EditOp] = times.enumerated().map { index, time in
            EditOp.text(from: time, to: time + 1, style: .lowerThird, text: labels[index], position: nil, size: nil)
        }
        let markers: [EditOp] = times.dropFirst().enumerated().map { index, time in EditOp.marker(at: time, label: "Section \(index + 1)") }
        let steps: [[EditOp]] = [speeds, texts, [.zoom(from: 10.3, to: 13.3, scale: 1.8, center: NormPoint(x: 0.6, y: 0.4))], markers]
        let reading = AgentActivity.shared.begin(.init(time: Date(), agent: session.agentName, tool: "timeline.get", intent: "Reading timeline",
            projectID: base.id, sessionID: session.id))
        do { try await Task.sleep(for: .milliseconds(500)) }
        catch { AgentActivity.shared.finish(reading, result: "Cancelled"); throw error }
        AgentActivity.shared.finish(reading, result: "Completed")
        for ops in steps {
            try Task.checkCancellation()
            let args: [String: Any] = ["ops": try JSONSerialization.jsonObject(with: JSONEncoder().encode(ops))]
            let call = AgentActivity.shared.begin(.init(time: Date(), agent: session.agentName, tool: "edit.apply",
                intent: MCPTools.activityIntent("edit", "apply", args), projectID: base.id, sessionID: session.id))
            do {
                try await Task.sleep(for: .milliseconds(450))
                try Task.checkCancellation()
                var draft = try session.draft ?? AgentDraft(base: MCPTools.revision(base), baseProject: base)
                let before = draft.duration
                let result = try draft.append(ops, context: EditContext())
                session.draft = draft
                // The study previews between calls; production live propagation is tracked separately in T-815.
                try MCPServer.shared.review(session)
                session.draft?.submitted = false
                let changes = try JSONSerialization.jsonObject(with: JSONEncoder().encode(result.changes))
                AgentActivity.shared.finish(call, result: MCPTools.activityResult("edit", "apply", ["changes": changes,
                    "duration": ["before": before, "after": result.project.exportDuration]]))
                try await Task.sleep(for: .milliseconds(850))
            } catch { AgentActivity.shared.finish(call, result: error is CancellationError ? "Cancelled" : "INVALID_OP", isError: !(error is CancellationError)); throw error }
        }
        try Task.checkCancellation()
        session.draft?.note = "Tightened playback, added section labels, a zoom and markers."
        session.draft?.submitted = true
    }
    func close() {
        guard !closed else { return }
        closed = true; playing = false; generation += 1
        try? MCPServer.shared.finishReview(session, commit: false)
        session.draft = nil; session.connected = false; MCPServer.shared.removeFinishedSessions()
        AgentActivity.shared.clear(sessionID: session.id)
        UserDefaults.standard.removeObject(forKey: "agentAccess.\(base.id)")
        try? FileManager.default.removeItem(at: package)
    }
}

private struct AgentStudyInspector: View {
    let study: AgentPanelReplayStudy
    var body: some View { InspectorView(model: study.model).environment(\.agentReduceMotionPreview, study.reducedMotion) }
}

private struct AgentStudyControls: View {
    @Bindable var study: AgentPanelReplayStudy
    var body: some View {
        HStack(spacing: 12) {
            Text("Generated sample").font(Font(Theme.captionFont)).foregroundStyle(Theme.textSecondaryColor)
            Button("Replay Claude editing") { study.playing = true; study.generation += 1 }
                .buttonStyle(TechButtonStyle(kind: .secondary, compact: true))
            Button("Stop") { study.playing = false; study.generation += 1 }
                .buttonStyle(TechButtonStyle(kind: .quiet, compact: true)).disabled(!study.playing)
            Toggle("Reduce Motion", isOn: $study.reducedMotion).toggleStyle(.checkbox).font(Font(Theme.labelFont))
            Spacer()
        }.padding(.horizontal, 16).frame(maxWidth: .infinity, maxHeight: .infinity).background(Theme.bgPanelColor)
            .overlay(alignment: .top) { Rectangle().fill(Theme.strokeColor).frame(height: 1) }
            .signalWindow()
            .task(id: study.generation) {
                let generation = study.generation
                guard !study.closed else { return }
                guard study.playing else { study.reset(); return }
                do {
                    try await study.run()
                    if generation == study.generation { study.playing = false }
                } catch {
                    guard generation == study.generation else { return }
                    study.playing = false; study.reset()
                    if !(error is CancellationError) { study.session.reviewError = "Sample replay failed: \(error.localizedDescription)" }
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: NSWindow.willCloseNotification, object: study.controller?.window)) { _ in study.close() }
    }
}

extension UIKitGallery {
    @MainActor static func checkAgentStudy(to directory: URL) async throws {
        struct Failure: Error, CustomStringConvertible { let description: String }
        NSApplication.shared.setActivationPolicy(.accessory); NSApplication.shared.finishLaunching()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let study = try await AgentPanelReplayStudy.make()
        guard let controller = study.controller, let window = controller.window,
              let controls = (window.contentView as? NSStackView)?.arrangedSubviews.last else { throw Failure(description: "Study controls unavailable") }
        defer { window.close(); study.close() }
        let saved = try Data(contentsOf: study.package.appendingPathComponent("project.json"))
        func capture(_ name: String) throws {
            let view = controller.inspectorView
            view.layoutSubtreeIfNeeded()
            guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { throw Failure(description: "Panel bitmap unavailable") }
            view.cacheDisplay(in: view.bounds, to: rep)
            guard let png = rep.representation(using: .png, properties: [:]) else { throw Failure(description: "Panel PNG unavailable") }
            try png.write(to: directory.appendingPathComponent(name + ".png"))
        }
        func click(_ x: CGFloat, y: CGFloat = 22, in view: NSView? = nil) {
            let location = (view ?? controls).convert(NSPoint(x: x, y: y), to: nil)
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                window.sendEvent(NSEvent.mouseEvent(with: type, location: location, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!)
            }
        }
        func wait(_ message: String, seconds: Double = 4, until ready: () -> Bool) async throws {
            let deadline = Date().addingTimeInterval(seconds)
            while !ready(), Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
            guard ready() else { throw Failure(description: message) }
        }
        try await Task.sleep(for: .milliseconds(400))
        try capture("idle")
        click(200)
        try await wait("Native Replay did not start") { study.playing }
        try await wait("Current apply did not appear") {
            AgentActivity.shared.current.values.contains { $0.sessionID == study.session.id && $0.intent == "Applying 5 speed ops" }
        }
        try capture("working")
        for count in 1...4 {
            try await wait("Missing replay call \(count)") { (study.session.draft?.calls.count ?? 0) >= count }
            try await Task.sleep(for: .milliseconds(100))
            try capture("call-\(count)-mid")
            try await Task.sleep(for: .milliseconds(340))
            try capture("call-\(count)")
        }
        try await wait("Replay did not become ready", seconds: 8) { !study.playing && study.session.draft?.submitted == true }
        guard study.session.draft?.selectedCount == 17,
              study.session.draft?.groups.map(\.kind) == [.speed, .zoom, .text, .markers],
              study.model.liveProject == study.base,
              try Data(contentsOf: study.package.appendingPathComponent("project.json")) == saved,
              AgentActivity.shared.current.values.allSatisfy({ $0.sessionID != study.session.id }) else {
            throw Failure(description: "Replay counts, fixed group order, idle status or base isolation")
        }
        try await Task.sleep(for: .milliseconds(400))
        try capture("ready")
        study.model.playhead = 10.8
        let rendered = try await controller.previewView.captureRenderedFrame(atOutput: study.model.playhead)
        let overlay = NSImageView(frame: controller.previewView.bounds)
        overlay.image = NSImage(cgImage: rendered, size: overlay.bounds.size); overlay.imageScaling = .scaleAxesIndependently
        controller.previewView.addSubview(overlay, positioned: .above, relativeTo: nil)
        let originalSize = window.contentView!.bounds.size
        for (name, size) in [("editor-ready", originalSize), ("editor-minimum", NSSize(width: 1100, height: 744))] {
            window.setContentSize(size); window.contentView?.layoutSubtreeIfNeeded(); overlay.frame = controller.previewView.bounds
            try await Task.sleep(for: .milliseconds(200))
            guard let view = window.contentView?.superview, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { throw Failure(description: "Study editor bitmap unavailable") }
            view.cacheDisplay(in: view.bounds, to: rep)
            guard let png = rep.representation(using: .png, properties: [:]) else { throw Failure(description: "Study editor PNG unavailable") }
            try png.write(to: directory.appendingPathComponent(name + ".png"))
        }
        window.setContentSize(originalSize); overlay.removeFromSuperview()
        try MCPServer.shared.finishReview(study.session, commit: true)
        guard study.model.undoStepNames.count == 1 else { throw Failure(description: "Replay acceptance must remain one undo step") }
        try await Task.sleep(for: .milliseconds(300))
        try capture("accepted")
        click(200)
        try await wait("Replay could not restart") { study.playing }
        try await wait("Restart did not reach apply") { !AgentActivity.shared.current.isEmpty }
        click(320)
        try await wait("Native Stop did not clear the replay") { !study.playing && study.session.draft == nil && !study.model.isReviewingDraft }
        try await Task.sleep(for: .milliseconds(1500))
        guard study.session.draft == nil, AgentActivity.shared.current.values.allSatisfy({ $0.sessionID != study.session.id }), study.model.project == study.base else {
            throw Failure(description: "Cancelled replay left stale work or an in-flight call")
        }
        try capture("stopped")
        click(200)
        try await wait("Repeated replay did not start") { study.playing }
        try await Task.sleep(for: .milliseconds(200))
        click(200)
        try await wait("Repeated replay did not reset") { study.session.draft == nil }
        try await wait("Repeated replay did not finish", seconds: 9) { !study.playing && study.session.draft?.submitted == true }
        guard study.session.draft?.selectedCount == 17 else { throw Failure(description: "Repeated replay duplicated operations") }
        // The native toggle sets a preview-only environment override; the user's system preference is unchanged.
        click(410)
        try await wait("Native Reduce Motion toggle did not change the study") { study.reducedMotion }
        click(200)
        try await wait("Reduced replay did not start") { study.playing }
        try await wait("Reduced replay did not reset") { study.session.draft == nil }
        try await wait("Reduced first call missing") { (study.session.draft?.calls.count ?? 0) >= 1 }
        try await Task.sleep(for: .milliseconds(100))
        try capture("reduced-mid")
        try await wait("Reduced replay did not finish", seconds: 9) { !study.playing && study.session.draft?.submitted == true }
        try await Task.sleep(for: .milliseconds(400))
        try capture("reduced-ready")
        study.session.reviewError = "INVALID_OP: sample error state"
        AgentActivity.shared.log(.init(time: Date(), agent: study.session.agentName, tool: "edit.apply", intent: "Applying edits",
            result: "INVALID_OP", isError: true, projectID: study.base.id, sessionID: study.session.id))
        try await Task.sleep(for: .milliseconds(180))
        try capture("error")
        func buttons(_ view: NSView) -> [NSButton] { (view as? NSButton).map { [$0] } ?? view.subviews.flatMap(buttons) }
        guard let markers = buttons(controller.inspectorView).first(where: { $0.accessibilityLabel() == "Include markers" }) else { throw Failure(description: "Marker group unavailable") }
        let frame = markers.convert(markers.bounds, to: controller.inspectorView)
        click(25, y: frame.midY + 48, in: controller.inspectorView)
        try await Task.sleep(for: .milliseconds(700))
        try capture("activity-error")
        click(200)
        try await wait("Expanded activity replay did not reset") { study.session.draft == nil }
        try await Task.sleep(for: .milliseconds(150))
        try capture("replay-reset")
        click(320)
        try await wait("Stop after expanded activity did not finish") { !study.playing && study.session.draft == nil }
        let ownProject = study.base.id, otherSession = UUID().uuidString
        let other = AgentActivity.shared.begin(.init(time: Date(), agent: "Other sample", tool: "timeline.get", intent: "Reading timeline", projectID: ownProject, sessionID: otherSession))
        let first = AgentActivity.shared.begin(.init(time: Date(), agent: "Sample", tool: "render.clip", intent: "Rendering preview", projectID: ownProject, sessionID: study.session.id))
        AgentActivity.shared.finish(first, result: "Cancelled")
        guard AgentActivity.shared.current[other] != nil else { throw Failure(description: "Finishing one call cleared a concurrent call") }
        AgentActivity.shared.finish(other, result: "Completed")
        AgentActivity.shared.clear(sessionID: otherSession)
        window.close()
        guard study.closed, !FileManager.default.fileExists(atPath: study.package.path),
              !MCPServer.shared.sessions.contains(where: { $0 === study.session }) else { throw Failure(description: "Closing the study retained its session or files") }
        print("Agent panel motion: native Replay/Stop/Reduce Motion, four cumulative groups/17 changes, working/idle/error/ready/accepted samples, rapid restart/cancellation, frozen-base isolation, one undo and concurrent activity cleanup verified: \(directory.path)")
    }
}
