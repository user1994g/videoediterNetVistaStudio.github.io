import UIKit

/// An actual editable connected-block canvas, not a decorative diagram. Tap a
/// block for its settings; drag its body to arrange it. Connections are edited
/// explicitly so Yes/No branches never silently become a linear chain.
final class GameWorkspaceGraphView: UIScrollView, UIScrollViewDelegate {
    var onSelect: ((UUID) -> Void)?
    var onPosition: ((UUID, CGPoint, Int) -> Void)?
    var canEdit = false
    var rule: GameRule? { didSet { canvas.rule = rule; updateSize() } }
    var selectedNode: UUID? { didSet { canvas.selected = selectedNode; canvas.setNeedsDisplay() } }
    private let canvas = GameWorkspaceGraphCanvas()
    fileprivate var graphScale: CGFloat = 1
    private var pinchScale: CGFloat = 1
    private var virtualSize = CGSize(width: 300, height: 180)
    override init(frame: CGRect) {
        super.init(frame:frame); backgroundColor = MobileTheme.top; delegate = self
        addSubview(canvas); canvas.owner = self; canvas.backgroundColor = MobileTheme.top
        addGestureRecognizer(UIPinchGestureRecognizer(target:self,action:#selector(pinched(_:))))
        accessibilityIdentifier = "game.graph"; accessibilityLabel = "Connected behaviour graph"
    }
    required init?(coder:NSCoder) { fatalError("init(coder:)") }
    private func updateSize() {
        let positions = rule.map { ($0.graph ?? .chain($0)).positions } ?? []
        virtualSize = CGSize(width:CGFloat(positions.map(\.x).max() ?? 0)+270,height:CGFloat(positions.map(\.y).max() ?? 0)+140)
        contentSize = CGSize(width:max(bounds.width,virtualSize.width*graphScale),height:max(bounds.height,virtualSize.height*graphScale)); layoutCanvas()
    }
    override func layoutSubviews() { super.layoutSubviews(); updateSize() }
    private func layoutCanvas() { canvas.frame = CGRect(origin:contentOffset,size:bounds.size); canvas.setNeedsDisplay() }
    func scrollViewDidScroll(_ scrollView:UIScrollView) { layoutCanvas() }
    @objc private func pinched(_ recognizer:UIPinchGestureRecognizer) { if recognizer.state == .began { pinchScale = graphScale }; graphScale = max(0.035,min(2,pinchScale*recognizer.scale)); updateSize() }
    func frameAll() { graphScale = max(0.035,min(1,min(bounds.width/max(1,virtualSize.width),bounds.height/max(1,virtualSize.height)))); updateSize(); setContentOffset(.zero,animated:false) }
    func nodeRect(_ id: UUID) -> CGRect? { canvas.boxes().first { $0.0 == id }?.1 }
}

private final class GameWorkspaceGraphCanvas: UIView {
    weak var owner: GameWorkspaceGraphView?
    var rule: GameRule?, selected: UUID?
    private var dragged: UUID?, origin = CGPoint.zero, pointer = CGPoint.zero
    override init(frame:CGRect) {
        super.init(frame:frame)
        addGestureRecognizer(UITapGestureRecognizer(target:self,action:#selector(tapped(_:))))
        let drag = UILongPressGestureRecognizer(target:self,action:#selector(moved(_:))); drag.minimumPressDuration = 0.2; addGestureRecognizer(drag)
    }
    required init?(coder:NSCoder) { fatalError("init(coder:)") }
    func boxes() -> [(UUID,CGRect)] {
        guard let rule else { return [] }; let graph = rule.graph ?? .chain(rule)
        return ([rule.id]+rule.actions.map(\.id)).enumerated().map { i,id in
            let p = graph.positions.first { $0.id == id }
            return (id,CGRect(x:p?.x ?? Double(i)*250+30,y:p?.y ?? 40,width:218,height:88))
        }
    }
    private func worldPoint(_ point:CGPoint) -> CGPoint { guard let owner else { return point }; return CGPoint(x:(point.x+owner.contentOffset.x)/owner.graphScale,y:(point.y+owner.contentOffset.y)/owner.graphScale) }
    @objc private func tapped(_ recognizer:UITapGestureRecognizer) { if let id = boxes().last(where: { $0.1.contains(worldPoint(recognizer.location(in:self))) })?.0 { owner?.onSelect?(id) } }
    @objc private func moved(_ recognizer:UILongPressGestureRecognizer) {
        guard owner?.canEdit == true else { return }; let p = worldPoint(recognizer.location(in:self))
        if recognizer.state == .began { guard let item = boxes().last(where: { $0.1.contains(p) }) else { return }; dragged = item.0; origin = item.1.origin; pointer = p; owner?.onSelect?(item.0); owner?.onPosition?(item.0,origin,0) }
        guard let dragged else { return }
        let point = CGPoint(x:max(0,min(10000,origin.x+p.x-pointer.x)),y:max(0,min(10000,origin.y+p.y-pointer.y)))
        owner?.onPosition?(dragged,point,recognizer.state == .cancelled ? -1 : recognizer.state == .ended ? 2 : 1)
        if [.ended,.cancelled,.failed].contains(recognizer.state) { self.dragged = nil }
    }
    override func draw(_ rect:CGRect) {
        guard let rule, let owner, let c = UIGraphicsGetCurrentContext() else { return }
        // Only a viewport-sized backing store is allocated, even if a saved
        // graph arranges its nodes 10,000 world points apart.
        c.translateBy(x:-owner.contentOffset.x,y:-owner.contentOffset.y); c.scaleBy(x:owner.graphScale,y:owner.graphScale)
        let graph = rule.graph ?? .chain(rule), list = boxes(), lookup = Dictionary(uniqueKeysWithValues:list)
        for wire in graph.wires {
            guard let a = lookup[wire.from], let b = lookup[wire.to] else { continue }
            let p = CGPoint(x:a.maxX,y:a.midY+(wire.port == .yes ? -18 : wire.port == .no ? 18 : 0)), q = CGPoint(x:b.minX,y:b.midY)
            c.setStrokeColor((wire.port == .yes ? UIColor.systemGreen : wire.port == .no ? .systemRed : .systemTeal).cgColor); c.setLineWidth(2)
            c.move(to:p); c.addCurve(to:q,control1:CGPoint(x:p.x+70,y:p.y),control2:CGPoint(x:q.x-70,y:q.y)); c.strokePath()
            (wire.port == .next ? "" : wire.port.rawValue.uppercased() as NSString).draw(at:CGPoint(x:p.x+4,y:p.y-13),withAttributes:[.font:UIFont.systemFont(ofSize:9,weight:.bold),.foregroundColor:UIColor.white])
        }
        for (id,box) in list {
            let action = rule.actions.first { $0.id == id }, isEvent = id == rule.id
            let colour:UIColor = isEvent ? .systemPurple : action?.kind.isCondition == true ? .systemOrange : .systemTeal
            let path = UIBezierPath(roundedRect:box,cornerRadius:7); MobileTheme.panel.setFill(); path.fill()
            (id == selected ? UIColor.white : colour).setStroke(); path.lineWidth = id == selected ? 2 : 1; path.stroke()
            let title = isEvent ? rule.event.title : action?.kind.title ?? "Action"
            (title as NSString).draw(in:box.insetBy(dx:12,dy:10),withAttributes:[.font:UIFont.systemFont(ofSize:12,weight:.semibold),.foregroundColor:UIColor.white])
            let detail = isEvent ? (rule.event == .timer ? "Every \(rule.interval)s" : rule.event == .keyHeld || rule.event == .keyPressed ? rule.key : "Event") : action.map { "x \($0.x)   y \($0.y)   value \($0.value)" } ?? ""
            (detail as NSString).draw(in:CGRect(x:box.minX+12,y:box.minY+48,width:box.width-24,height:30),withAttributes:[.font:UIFont.monospacedSystemFont(ofSize:10,weight:.regular),.foregroundColor:MobileTheme.secondary])
            c.setFillColor(colour.cgColor); if !isEvent { c.fillEllipse(in:CGRect(x:box.minX-4,y:box.midY-4,width:8,height:8)) }
            for y in action?.kind.isCondition == true ? [box.midY-18,box.midY+18] : [box.midY] { c.fillEllipse(in:CGRect(x:box.maxX-4,y:y-4,width:8,height:8)) }
        }
    }
}
