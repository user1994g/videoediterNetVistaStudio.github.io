import Cocoa
import UniformTypeIdentifiers

// Native launcher: the artwork is decorative, every control is a real AppKit
// control. Editors retain their own windows and document state.
private class StudioHomeSurface: NSView {
    override init(frame frameRect: NSRect) { super.init(frame:frameRect); autoresizesSubviews = false }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var isFlipped: Bool { true }
    var onLayout: (() -> Void)?
    override func layout() { super.layout(); onLayout?() }
}

private final class StudioHomeButton: NSButton {
    enum Style { case plain, navigation, primary, outlined, pill, link }
    var style: Style = .plain
    var active = false { didSet { needsDisplay = true } }
    private var hovered = false
    private var tracking: NSTrackingArea?
    override func hitTest(_ point: NSPoint) -> NSView? { super.hitTest(point) == nil ? nil : self }
    override func updateTrackingAreas() {
        if let tracking { removeTrackingArea(tracking) }
        tracking = NSTrackingArea(rect:.zero,options:[.mouseEnteredAndExited,.activeInKeyWindow,.inVisibleRect],owner:self)
        addTrackingArea(tracking!); super.updateTrackingAreas()
    }
    override func mouseEntered(with event: NSEvent) { hovered = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hovered = false; needsDisplay = true }
    override func draw(_ dirtyRect: NSRect) {
        let pressed = isHighlighted, radius: CGFloat = style == .pill ? 14 : 5
        let shape = NSBezierPath(roundedRect:bounds.insetBy(dx:1,dy:1),xRadius:radius,yRadius:radius)
        let fill: NSColor
        if style == .primary { fill = NSColor(hex:pressed ? "CBCDD1" : hovered ? "FFFFFF" : "ECEDEE") }
        else if active { fill = NSColor(hex:style == .pill ? "3B3E44" : "282A2E") }
        else { fill = pressed ? NSColor(hex:"36383D") : hovered ? NSColor(hex:"2D2F34") : .clear }
        fill.setFill(); shape.fill()
        if style == .outlined {
            NSColor(hex:hovered ? "A0A4AD" : "646872").setStroke(); shape.lineWidth = 1; shape.stroke()
        }
        if active && style == .navigation {
            NSColor(hex:"F34C53").setFill()
            NSBezierPath(roundedRect:NSRect(x:1,y:7,width:3,height:bounds.height-14),xRadius:1.5,yRadius:1.5).fill()
        }
        let colour = NSColor(hex:style == .primary ? "17181A" : active || hovered ? "FFFFFF" : "D7D9DE")
        let attributes: [NSAttributedString.Key:Any] = [.font:font ?? NSFont.systemFont(ofSize:12),.foregroundColor:colour]
        let text = NSAttributedString(string:title,attributes:attributes), textSize = text.size()
        let iconSize: CGFloat = image == nil ? 0 : 17, gap: CGFloat = image == nil ? 0 : 12
        var x: CGFloat = alignment == .left ? 17 : (bounds.width-textSize.width-iconSize-gap)/2
        if let image {
            let symbol = image.copy() as! NSImage
            symbol.lockFocus(); colour.set(); NSRect(origin:.zero,size:symbol.size).fill(using:.sourceAtop); symbol.unlockFocus()
            symbol.draw(in:NSRect(x:x,y:(bounds.height-iconSize)/2,width:iconSize,height:iconSize),from:.zero,operation:.sourceOver,fraction:isEnabled ? 1 : 0.4,respectFlipped:true,hints:nil)
            x += iconSize+gap
        }
        text.draw(at:NSPoint(x:x,y:(bounds.height-textSize.height)/2))
        if style == .link {
            colour.withAlphaComponent(0.5).setFill()
            NSRect(x:x,y:(bounds.height+textSize.height)/2+1,width:textSize.width,height:0.5).fill()
        }
        if window?.firstResponder === self {
            NSColor.keyboardFocusIndicatorColor.setStroke(); shape.lineWidth = 2; shape.stroke()
        }
    }
}

private func homeLabel(_ text: String, size: CGFloat = 12, weight: NSFont.Weight = .regular, colour: String = "F0F0F2") -> NSTextField {
    let field = NSTextField(labelWithString:text)
    field.font = .systemFont(ofSize:size,weight:weight); field.textColor = NSColor(hex:colour)
    field.lineBreakMode = .byTruncatingTail
    return field
}

private final class StudioHomeArtwork: StudioHomeSurface {
    var artwork: NSImage?
    override func draw(_ dirtyRect: NSRect) {
        NSColor(hex:"25262A").setFill(); bounds.fill()
        guard let artwork, artwork.size.width > 0, artwork.size.height > 0 else { return }
        NSGraphicsContext.saveGraphicsState(); bounds.clip()
        let scale = max(bounds.width/artwork.size.width,bounds.height/artwork.size.height)
        let size = NSSize(width:artwork.size.width*scale,height:artwork.size.height*scale)
        artwork.draw(in:NSRect(x:(bounds.width-size.width)/2,y:(bounds.height-size.height)/2,width:size.width,height:size.height),from:.zero,operation:.sourceOver,fraction:1,respectFlipped:true,hints:nil)
        NSGradient(starting:NSColor.black.withAlphaComponent(0.35),ending:.clear)?.draw(in:NSRect(x:0,y:0,width:bounds.width,height:65),angle:90)
        NSGraphicsContext.restoreGraphicsState()
    }
}

private final class StudioHomeCard: StudioHomeSurface {
    let artwork = StudioHomeArtwork()
    let category = homeLabel("",size:9,weight:.semibold)
    let heading = homeLabel("",size:20,weight:.semibold)
    let detail = homeLabel("",size:12,colour:"A5A8AE")
    let icon = NSImageView()
    let launch = StudioHomeButton()
    var artworkHeight: CGFloat = 230
    override init(frame frameRect: NSRect) {
        super.init(frame:frameRect)
        wantsLayer = true; layer?.backgroundColor = NSColor(hex:"25262A").cgColor
        layer?.cornerRadius = 8; layer?.masksToBounds = true
        layer?.borderColor = NSColor(hex:"383A40").cgColor; layer?.borderWidth = 1
        [artwork,category,icon,heading,detail,launch].forEach { addSubview($0) }
        icon.contentTintColor = NSColor(hex:"D4D7DD"); icon.imageScaling = .scaleProportionallyUpOrDown
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func layout() {
        super.layout()
        let width = bounds.width, compact = width < 410
        artwork.frame = NSRect(x:0,y:0,width:width,height:artworkHeight)
        category.frame = NSRect(x:20,y:16,width:150,height:16)
        icon.frame = NSRect(x:20,y:artworkHeight+23,width:27,height:27)
        heading.font = .systemFont(ofSize:compact ? 18 : 20,weight:.semibold)
        heading.frame = NSRect(x:60,y:artworkHeight+18,width:width-78-(compact ? 0 : 116),height:26)
        detail.frame = NSRect(x:60,y:artworkHeight+48,width:width-78-(compact ? 0 : 112),height:19)
        if compact {
            launch.frame = NSRect(x:60,y:artworkHeight+78,width:112,height:32)
        } else {
            launch.frame = NSRect(x:width-130,y:artworkHeight+29,width:112,height:34)
        }
    }
}

private final class StudioHomeEmptyState: StudioHomeSurface {
    override func draw(_ dirtyRect: NSRect) {
        NSColor(hex:"464950").setStroke()
        let path = NSBezierPath(roundedRect:bounds.insetBy(dx:1,dy:1),xRadius:6,yRadius:6)
        path.setLineDash([2,3],count:2,phase:0); path.lineWidth = 0.75; path.stroke()
    }
}

final class WelcomeViewController: NSViewController {
    var onOpenVideoEditor: (() -> Void)?
    var onOpenPhotoEditor: (() -> Void)?
    var onOpenGameMaker: (() -> Void)?
    var onOpenProject: ((URL) -> Void)?
    var onCheckForUpdates: (() -> Void)?
    var onOpenAccount: (() -> Void)?
    private let accountButton = StudioHomeButton()
    private let updateButton = StudioHomeButton()
    private let header = StudioHomeSurface()
    private let beta = homeLabel("Public beta",size:11,colour:"A5A8AE")
    private let sidebar = StudioHomeSurface()
    private let footer = StudioHomeSurface()
    private let scroll = NSScrollView()
    private let content = StudioHomeSurface()
    private let homeButton = StudioHomeButton()
    private let recentButton = StudioHomeButton()
    private let titleLabel = homeLabel("Welcome to your studio.",size:28,weight:.semibold)
    private let subtitle = homeLabel("Open an editor or pick up where you left off.",size:13,colour:"A5A8AE")
    private let openButton = StudioHomeButton()
    private let videoCard = StudioHomeCard()
    private let photoCard = StudioHomeCard()
    private let recentHeader = StudioHomeSurface()
    private let recentRows = StudioHomeSurface()
    private let recentTitle = homeLabel("Recent projects",size:20,weight:.semibold)
    private let search = NSSearchField()
    private var filters: [StudioHomeButton] = []
    private var selectedKind = 0
    private var urls: [URL] = []
    private var listedURLs: [URL] = []
    private var recentOrigin: CGFloat = 0
    private var windowObserver: NSObjectProtocol?
    deinit { if let windowObserver { NotificationCenter.default.removeObserver(windowObserver) } }

    override func loadView() {
        let root = StudioHomeSurface()
        root.wantsLayer = true; root.layer?.backgroundColor = NSColor(hex:"1B1C1F").cgColor
        root.appearance = NSAppearance(named:.darkAqua); view = root
        header.wantsLayer = true; header.layer?.backgroundColor = NSColor(hex:"222326").cgColor
        sidebar.wantsLayer = true; sidebar.layer?.backgroundColor = NSColor(hex:"141517").cgColor
        scroll.drawsBackground = false; scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true; scroll.scrollerStyle = .overlay
        content.frame = NSRect(x:0,y:0,width:968,height:760); scroll.documentView = content
        [header,sidebar,scroll].forEach { root.addSubview($0) }
        root.onLayout = { [weak self] in self?.layoutHome() }
        buildHeader(); buildSidebar(); buildContent(); refreshRecentProjects()
    }
    override func viewDidAppear() {
        super.viewDidAppear(); refreshRecentProjects()
        if windowObserver == nil {
            windowObserver = NotificationCenter.default.addObserver(forName:NSWindow.didBecomeKeyNotification,object:nil,queue:.main) { [weak self] notification in
                guard let self, let window = notification.object as? NSWindow, window === self.view.window else { return }
                self.refreshRecentProjects()
            }
        }
    }
    private func configure(_ button: StudioHomeButton, title: String, symbol: String? = nil, action: Selector, style: StudioHomeButton.Style = .plain) {
        button.title = title; button.target = self; button.action = action; button.style = style
        button.isBordered = false; button.setButtonType(.momentaryPushIn)
        button.font = .systemFont(ofSize:12,weight:style == .primary ? .semibold : .medium)
        if let symbol { button.image = NSImage(systemSymbolName:symbol,accessibilityDescription:nil) }
        button.setAccessibilityLabel(title)
    }
    private func button(_ title: String, symbol: String? = nil, action: Selector, style: StudioHomeButton.Style = .plain) -> StudioHomeButton {
        let result = StudioHomeButton(); configure(result,title:title,symbol:symbol,action:action,style:style); return result
    }
    private func add(_ child: NSView, to parent: NSView, x: CGFloat, y: CGFloat, w: CGFloat, h: CGFloat) {
        child.frame = NSRect(x:x,y:y,width:w,height:h); parent.addSubview(child)
    }
    private func resource(_ name: String, _ ext: String) -> NSImage? {
        if let url = Bundle.main.url(forResource:name,withExtension:ext) { return NSImage(contentsOf:url) }
        #if STUDIO_HOME_CHECKS
        return NSImage(contentsOfFile:FileManager.default.currentDirectoryPath+"/assets/\(name).\(ext)")
        #else
        return nil
        #endif
    }
    private func buildHeader() {
        let logo = NSImageView(); logo.image = resource("NetVistaStudio","icns"); logo.imageScaling = .scaleProportionallyUpOrDown
        add(logo,to:header,x:22,y:13,w:26,h:26)
        add(homeLabel("NetVista Studio",size:14,weight:.semibold),to:header,x:59,y:16,w:180,h:23)
        header.addSubview(beta)
        configure(updateButton,title:"Update",symbol:"arrow.triangle.2.circlepath",action:#selector(checkForUpdates),style:.outlined)
        updateButton.toolTip = "Check for a new version of NetVista Studio"
        header.addSubview(updateButton)
        configure(accountButton,title:"Sign in",symbol:"person.crop.circle",action:#selector(openAccount),style:.outlined)
        header.addSubview(accountButton)
    }
    private func buildSidebar() {
        configure(homeButton,title:"Home",symbol:"house",action:#selector(showHome),style:.navigation)
        configure(recentButton,title:"Recent projects",symbol:"doc",action:#selector(showRecent),style:.navigation)
        homeButton.alignment = .left; recentButton.alignment = .left; homeButton.active = true
        add(homeButton,to:sidebar,x:12,y:28,w:168,h:38)
        add(recentButton,to:sidebar,x:12,y:76,w:168,h:38)
        let divider = NSBox(); divider.boxType = .separator
        add(divider,to:sidebar,x:24,y:141,w:144,h:1)
        add(homeLabel("W O R K S P A C E S",size:8,weight:.semibold,colour:"91959F"),to:sidebar,x:26,y:165,w:155,h:16)
        let video = button("Video Editor",symbol:"film",action:#selector(openVideoEditor))
        let photo = button("Photo Editor",symbol:"photo",action:#selector(openPhotoEditor))
        video.alignment = .left; photo.alignment = .left
        add(video,to:sidebar,x:12,y:196,w:168,h:38); add(photo,to:sidebar,x:12,y:244,w:168,h:38)
        let game = button("Game Maker",symbol:"gamecontroller",action:#selector(showGameMaker))
        game.alignment = .left
        add(game,to:sidebar,x:12,y:292,w:168,h:38)
        let guide = button("Quick guide",symbol:"book",action:#selector(showGuide)); guide.alignment = .left
        add(guide,to:footer,x:0,y:0,w:168,h:34)
        let version = Bundle.main.object(forInfoDictionaryKey:"CFBundleShortVersionString") as? String ?? "1.4.0"
        add(homeLabel("Version \(version)",size:10,colour:"92969F"),to:footer,x:17,y:49,w:158,h:18)
        sidebar.addSubview(footer)
    }
    private func buildContent() {
        configure(openButton,title:"Open project…",action:#selector(openProjectPicker),style:.outlined)
        openButton.toolTip = "Open a video or layered photo project"
        [titleLabel,subtitle,openButton,videoCard,photoCard,recentHeader,recentRows].forEach { content.addSubview($0) }
        makeCard(videoCard,title:"Video Editor",category:"C I N E M A",symbol:"film",asset:"home-video-coast",detail:"Timeline, colour, sound & 3D.",action:#selector(openVideoEditor))
        makeCard(photoCard,title:"Photo Editor",category:"I M A G E S",symbol:"photo",asset:"home-photo-petals",detail:"Layers, brushes & retouching.",action:#selector(openPhotoEditor))
        recentHeader.addSubview(recentTitle)
        for (index,title) in ["All","Video","Photos"].enumerated() {
            let filter = button(title,action:#selector(selectKind(_:)),style:.pill)
            filter.tag = index; filter.active = index == 0; filters.append(filter); recentHeader.addSubview(filter)
        }
        search.placeholderString = "Search projects…"; search.font = .systemFont(ofSize:12)
        search.target = self; search.action = #selector(filterRecent)
        search.sendsSearchStringImmediately = true; search.setAccessibilityLabel("Search recent projects")
        recentHeader.addSubview(search)
    }
    private func makeCard(_ card: StudioHomeCard, title: String, category: String, symbol: String, asset: String, detail: String, action: Selector) {
        card.artwork.artwork = resource(asset,"png"); card.category.stringValue = category
        card.heading.stringValue = title; card.detail.stringValue = detail
        card.icon.image = NSImage(systemSymbolName:symbol,accessibilityDescription:nil)
        configure(card.launch,title:"Open editor",action:action,style:.primary)
        card.launch.setAccessibilityLabel("Open \(title)")
        card.launch.toolTip = "Open \(title) in its own window; Studio Home stays available"
    }
    private func layoutHome() {
        guard isViewLoaded else { return }
        let width = view.bounds.width, height = view.bounds.height
        header.frame = NSRect(x:0,y:0,width:width,height:52)
        beta.frame = NSRect(x:width-380,y:18,width:84,height:19)
        accountButton.frame = NSRect(x:width-288,y:10,width:108,height:32)
        updateButton.frame = NSRect(x:width-170,y:10,width:148,height:32)
        sidebar.frame = NSRect(x:0,y:53,width:192,height:max(1,height-53))
        footer.frame = NSRect(x:12,y:max(320,sidebar.bounds.height-100),width:168,height:76)
        scroll.frame = NSRect(x:193,y:53,width:max(1,width-193),height:max(1,height-53))
        let available = max(1,scroll.contentSize.width), margin: CGFloat = available < 800 ? 28 : 36
        let bodyWidth = max(1,min(1240,available-margin*2)), x = max(margin,(available-bodyWidth)/2)
        titleLabel.font = .systemFont(ofSize:bodyWidth < 730 ? 25 : 28,weight:.semibold)
        titleLabel.frame = NSRect(x:x,y:31,width:bodyWidth-156,height:37)
        subtitle.frame = NSRect(x:x,y:76,width:bodyWidth,height:22)
        openButton.frame = NSRect(x:x+bodyWidth-137,y:34,width:137,height:34)
        let cardWidth = (bodyWidth-20)/2
        let imageHeight = min(320,max(168,cardWidth/1.73))
        let cardHeight = imageHeight+(cardWidth < 410 ? 126 : 94)
        for (index,card) in [videoCard,photoCard].enumerated() {
            card.artworkHeight = imageHeight
            card.frame = NSRect(x:x+CGFloat(index)*(cardWidth+20),y:124,width:cardWidth,height:cardHeight)
            card.needsLayout = true
        }
        recentOrigin = 124+cardHeight+36
        recentHeader.frame = NSRect(x:x,y:recentOrigin,width:bodyWidth,height:75)
        recentTitle.frame = NSRect(x:0,y:0,width:240,height:29)
        for (index,filter) in filters.enumerated() { filter.frame = NSRect(x:CGFloat(index)*67,y:41,width:60,height:28) }
        search.frame = NSRect(x:bodyWidth-min(248,bodyWidth-218),y:40,width:min(248,bodyWidth-218),height:29)
        let rowsY = recentOrigin+85
        recentRows.frame = NSRect(x:x,y:rowsY,width:bodyWidth,height:listedURLs.isEmpty ? 174 : CGFloat(listedURLs.count)*64)
        layoutRecentRows()
        content.frame = NSRect(x:0,y:0,width:available,height:max(scroll.contentSize.height,rowsY+recentRows.frame.height+36))
    }
    func refreshRecentProjects() {
        urls = NSDocumentController.shared.recentDocumentURLs.filter { ["netvistastudio","netvistaphoto","netvistagame"].contains($0.pathExtension.lowercased()) }
        filterRecent()
    }
    @objc private func selectKind(_ sender: NSButton) {
        selectedKind = sender.tag
        for filter in filters { filter.active = filter.tag == selectedKind }
        filterRecent()
    }
    @objc private func filterRecent() {
        listedURLs = Array(urls.filter { url in
            let isPhoto = url.pathExtension.lowercased() == "netvistaphoto"
            return (selectedKind == 0 || (selectedKind == 2 ? isPhoto : url.pathExtension.lowercased() == "netvistastudio")) && (search.stringValue.isEmpty || url.lastPathComponent.localizedCaseInsensitiveContains(search.stringValue))
        }.prefix(20))
        recentRows.subviews.forEach { $0.removeFromSuperview() }
        if listedURLs.isEmpty {
            let empty = StudioHomeEmptyState()
            let icon = NSImageView(image:NSImage(systemSymbolName:"folder",accessibilityDescription:nil) ?? NSImage())
            icon.contentTintColor = NSColor(hex:"A7ABB3"); icon.imageScaling = .scaleProportionallyUpOrDown
            let heading = homeLabel(urls.isEmpty ? "A fresh start." : "No matching projects",size:14,weight:.semibold)
            let detail = homeLabel(urls.isEmpty ? "Your saved projects will appear here." : "Try another search or choose All.",size:12,colour:"A5A8AE")
            heading.alignment = .center; detail.alignment = .center
            let open = button("Open a project",action:#selector(openProjectPicker),style:.link)
            [icon,heading,detail,open].forEach { empty.addSubview($0) }; recentRows.addSubview(empty)
        } else {
            for (index,url) in listedURLs.enumerated() {
                let row = button("",action:#selector(openRecent(_:))); row.autoresizesSubviews = false
                row.tag = index; row.toolTip = url.path; row.setAccessibilityLabel("Open \(url.lastPathComponent)")
                let icon = NSImageView(image:NSImage(systemSymbolName:url.pathExtension.lowercased() == "netvistaphoto" ? "photo" : url.pathExtension.lowercased() == "netvistagame" ? "gamecontroller" : "film",accessibilityDescription:nil) ?? NSImage())
                icon.contentTintColor = NSColor(hex:"B8BCC6")
                let name = homeLabel(url.deletingPathExtension().lastPathComponent,size:12,weight:.medium)
                let location = homeLabel(url.deletingLastPathComponent().lastPathComponent,size:10,colour:"92969F")
                let kind = homeLabel(url.pathExtension.lowercased() == "netvistaphoto" ? "Photo project" : url.pathExtension.lowercased() == "netvistagame" ? "Game project" : "Video project",size:11,colour:"A5A8AE"); kind.alignment = .right
                [icon,name,location,kind].forEach { row.addSubview($0); $0.setAccessibilityElement(false) }
                recentRows.addSubview(row)
            }
        }
        view.needsLayout = true
    }
    private func layoutRecentRows() {
        for (index,row) in recentRows.subviews.enumerated() {
            row.frame = NSRect(x:0,y:CGFloat(index)*64,width:recentRows.bounds.width,height:listedURLs.isEmpty ? 174 : 60)
            let width = row.bounds.width
            if listedURLs.isEmpty {
                row.subviews[0].frame = NSRect(x:(width-30)/2,y:25,width:30,height:30)
                row.subviews[1].frame = NSRect(x:20,y:69,width:width-40,height:23)
                row.subviews[2].frame = NSRect(x:20,y:97,width:width-40,height:20)
                row.subviews[3].frame = NSRect(x:(width-144)/2,y:127,width:144,height:29)
            } else {
                row.subviews[0].frame = NSRect(x:16,y:19,width:25,height:25)
                row.subviews[1].frame = NSRect(x:56,y:32,width:width-215,height:20)
                row.subviews[2].frame = NSRect(x:56,y:13,width:width-215,height:16)
                row.subviews[3].frame = NSRect(x:width-138,y:22,width:120,height:19)
            }
        }
    }
    @objc private func showHome() {
        homeButton.active = true; recentButton.active = false
        scroll.contentView.scroll(to:.zero); scroll.reflectScrolledClipView(scroll.contentView)
    }
    @objc private func showRecent() {
        homeButton.active = false; recentButton.active = true
        scroll.contentView.scroll(to:NSPoint(x:0,y:min(recentOrigin,max(0,content.bounds.height-scroll.contentSize.height))))
        scroll.reflectScrolledClipView(scroll.contentView); view.window?.makeFirstResponder(search)
    }
    @objc private func openVideoEditor() { onOpenVideoEditor?() }
    @objc private func openPhotoEditor() { onOpenPhotoEditor?() }
    @objc private func showGameMaker() { onOpenGameMaker?() }
    @objc private func checkForUpdates() { onCheckForUpdates?() }
    @objc private func openAccount() { onOpenAccount?() }
    func setAccountState(_ title: String, detail: String) {
        accountButton.title = title; accountButton.toolTip = detail; accountButton.setAccessibilityLabel(title)
    }
    func setUpdateState(_ title: String, enabled: Bool) {
        updateButton.title = title; updateButton.isEnabled = enabled; updateButton.needsDisplay = true
    }
    @objc private func showGuide() {
        let alert = NSAlert()
        alert.messageText = "Your studio, three workspaces."
        alert.informativeText = "VIDEO EDITOR\nBuild your timeline, then use Effects, Colour, Audio or 3D Scene. Save your work as a .netvistastudio project.\n\nPHOTO EDITOR\nCreate a blank document or import an image. Keep layers and masks by saving a .netvistaphoto project; export a PNG or JPEG for sharing.\n\nGAME MAKER\nChoose an empty 2D or 3D scene. Import PNG/JPG sprites or OBJ models, then use Add asset to scene. Select an object, add an Event and Action blocks, and press Play. Save as .netvistagame; Export game creates Three.js or Python source with your assets and blocks.\n\nRETURN TO YOUR WORK\nEach editor has its own window. Use Studio Home to switch editors without closing a project. Saved and opened projects appear under Recent projects."
        alert.addButton(withTitle:"Got it")
        if let window = view.window { alert.beginSheetModal(for:window) }
    }
    @objc private func openRecent(_ sender: NSButton) {
        guard listedURLs.indices.contains(sender.tag) else { return }; let url = listedURLs[sender.tag]
        guard FileManager.default.fileExists(atPath:url.path) else {
            let alert = NSAlert(); alert.messageText = "Project moved or unavailable"
            alert.informativeText = "Use Open project to choose the file from its new location.\n\n\(url.path)"
            alert.addButton(withTitle:"OK"); if let window = view.window { alert.beginSheetModal(for:window) }; return
        }
        onOpenProject?(url)
    }
    @objc private func openProjectPicker() {
        let panel = NSOpenPanel(); panel.title = "Open NetVista Studio Project"; panel.prompt = "Open Project"
        panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        panel.allowedFileTypes = ["netvistastudio","netvistaphoto","netvistagame"]
        let completion: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            if response == .OK, let url = panel.url { self?.onOpenProject?(url) }
        }
        if let window = view.window { panel.beginSheetModal(for:window,completionHandler:completion) } else { completion(panel.runModal()) }
    }

    #if STUDIO_HOME_CHECKS
    func checkHomeActions() {
        var video = 0, photo = 0, updates = 0
        onOpenVideoEditor = { video += 1 }; onOpenPhotoEditor = { photo += 1 }
        onCheckForUpdates = { updates += 1 }
        updateButton.performClick(nil); precondition(updates == 1,"Home Update must route to the shared updater")
        precondition(updateButton.frame.maxX <= header.bounds.width && beta.frame.maxX < updateButton.frame.minX)
        videoCard.launch.performClick(nil); photoCard.launch.performClick(nil)
        precondition(video == 1 && photo == 1,"Editor launches must route independently")
        for node in [sidebar,scroll,header,videoCard,photoCard,recentHeader,recentRows] {
            precondition(node.frame.width > 0 && node.frame.height > 0)
        }
        precondition(photoCard.frame.maxX <= content.bounds.width,"Content must not overflow")
        for parent in [videoCard,photoCard] {
            precondition(parent.artwork.artwork != nil,"Production artwork must be bundled")
            for child in parent.subviews {
                precondition(child.frame.minX >= 0 && child.frame.maxX <= parent.bounds.width && child.frame.minY >= 0 && child.frame.maxY <= parent.bounds.height,"Tile content must stay in bounds: \(child.frame)")
            }
        }
        precondition(titleLabel.frame.maxX < openButton.frame.minX,"Title and Open must not overlap")
        precondition(filters.last!.frame.maxX < search.frame.minX,"Filters and search must not overlap")
        showRecent(); precondition(!homeButton.active && recentButton.active)
        showHome(); precondition(homeButton.active && scroll.contentView.bounds.minY == 0)
    }
    func checkRecentFiltering() {
        urls = [URL(fileURLWithPath:"/private/tmp/check-video.netvistastudio"),URL(fileURLWithPath:"/private/tmp/check-photo.netvistaphoto")]
        filterRecent(); precondition(listedURLs.count == 2)
        filters[2].performClick(nil); precondition(listedURLs.count == 1 && listedURLs[0].pathExtension == "netvistaphoto")
        filters[1].performClick(nil); precondition(listedURLs.count == 1 && listedURLs[0].pathExtension == "netvistastudio")
        filters[0].performClick(nil); search.stringValue = "PHOTO"; filterRecent(); precondition(listedURLs.count == 1)
        search.stringValue = "unmatched"; filterRecent(); precondition(listedURLs.isEmpty)
        search.stringValue = ""; refreshRecentProjects()
    }
    func checkRecentRouting() throws {
        // Temporary fixtures never enter the real macOS recent-document registry.
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("netvista-home-check-" + UUID().uuidString)
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:directory); refreshRecentProjects(); view.layoutSubtreeIfNeeded() }
        let project = directory.appendingPathComponent("Existing project.netvistastudio")
        try Data("{}".utf8).write(to:project)
        urls = [project]; filterRecent(); view.layoutSubtreeIfNeeded()
        var opened: URL?
        onOpenProject = { opened = $0 }
        let row = recentRows.subviews[0] as! NSButton
        precondition(row.hitTest(NSPoint(x:row.frame.midX,y:row.frame.midY)) === row,"Recent labels must not swallow clicks")
        row.performClick(nil); precondition(opened == project,"Recent project must route its exact URL")
        for child in row.subviews {
            precondition(child.frame.minX >= 0 && child.frame.maxX <= row.bounds.width)
        }
        onOpenProject = nil
    }
    #endif
}
