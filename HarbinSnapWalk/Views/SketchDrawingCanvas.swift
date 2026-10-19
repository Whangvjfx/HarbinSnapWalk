import SwiftUI

struct SketchDrawingCanvas: View {
    @Binding var points: [CGPoint]
    var onFinishSketch: () -> Void

    var body: some View {
        Canvas { context, _ in
            guard points.count > 1 else { return }
            var path = Path()
            path.addLines(points)
            
            // 荧光外发光拖尾
            context.stroke(
                path,
                with: .color(Color.cyan.opacity(0.4)),
                style: StrokeStyle(lineWidth: 12, lineCap: .round, lineJoin: .round)
            )
            // 实体高亮中心线
            context.stroke(
                path,
                with: .color(Color.blue),
                style: StrokeStyle(lineWidth: 5, lineCap: .round, lineJoin: .round)
            )
        }
        .background(Color.black.opacity(0.04))
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { val in
                    points.append(val.location)
                }
                .onEnded { _ in
                    onFinishSketch()
                }
        )
    }
}
