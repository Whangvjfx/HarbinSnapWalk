import Foundation
import MapKit
import CoreLocation

@MainActor
final class RouteSnapEngine: ObservableObject {
    @Published var isSnapping = false
    @Published var currentResult: SnappedRouteResult?
    @Published var statusMessage: String = "随手画个圈或折线，秒级贴合双侧人行道平路"

    /// 局部平面米制坐标（用于高速、高精度的几何小枝拓扑消解）
    private struct PlanarPoint {
        let x: Double
        let y: Double
        let coord: CLLocationCoordinate2D
    }

    /// 1. 严禁/尽量规避的纯车行道与人车混行高危路段关键词（高架、隧道、匝道、快速路主路、无步道公路等）
    private let vehicleOnlyKeywords: [(keyword: String, label: String)] = [
        ("高架", "高架车行道"),
        ("快速路", "城市快速路"),
        ("高速", "高速车行道"),
        ("匝道", "立交匝道"),
        ("立交桥", "立交车行道"),
        ("立交", "立交匝道"),
        ("隧道", "车行隧道"),
        ("涵洞", "涵洞路段"),
        ("机动车道", "机动车道"),
        ("车行道", "纯车行道"),
        ("无人行道", "无人行道"),
        ("无步道", "无人行步道"),
        ("主路", "干道主路"),
        ("绕城", "绕城公路"),
        ("国道", "国道公路"),
        ("省道", "省道公路"),
        ("Expressway", "快速车行道"),
        ("Highway", "高速车行道"),
        ("Tunnel", "隧道车行道"),
        ("Ramp", "匝道"),
        ("Viaduct", "高架桥")
    ]

    /// 2. 无障碍垂直通行障碍关键词（人行天桥、地下通道、台阶等）
    private let verticalBarrierKeywords: [(keyword: String, label: String)] = [
        ("人行天桥", "人行天桥"),
        ("过街天桥", "过街天桥"),
        ("天桥", "人行天桥"),
        ("人行桥", "人行桥"),
        ("地下通道", "地下通道"),
        ("过街地道", "地下通道"),
        ("地道", "地下通道"),
        ("台阶", "台阶路段"),
        ("阶梯", "台阶路段"),
        ("步梯", "台阶路段"),
        ("扶梯", "扶梯/天桥"),
        ("连廊", "空中连廊"),
        ("渡轮", "轮渡路段"),
        ("Overpass", "人行天桥"),
        ("Underpass", "地下通道"),
        ("Stairs", "台阶路段")
    ]

    /// 3. 双侧人行道/行人友好街道正向特征关键词（用于备选路线加分优选）
    private let sidewalkFriendlyKeywords: [String] = [
        "人行道", "人行横道", "斑马线", "步行街", "步道", "绿道", "林荫", "辅路", "辅道", "公园", "广场"
    ]

    /// 核心入口：将原始手绘屏幕坐标解析为地理序列并吸附至街道
    /// - 100% 根除所有中间锚点单枝与死胡同折返
    /// - 优先筛选两侧有人行道的城市生活街道，主动规避纯车行高架、隧道、匝道及人行天桥/台阶
    /// 每次画线递增；旧请求返回时若编号已过期则丢弃，防止连续快速画线时旧结果覆盖新结果
    private var snapGeneration: Int = 0

    @discardableResult
    func snapUserSketchToRoads(
        rawCoordinates: [CLLocationCoordinate2D],
        strideLength: Double
    ) async -> SnappedRouteResult? {
        guard rawCoordinates.count >= 2 else {
            self.statusMessage = "绘制线条过短，请画出一段路线"
            return nil
        }

        snapGeneration += 1
        let myGeneration = snapGeneration
        self.isSnapping = true
        self.statusMessage = "正在优选双侧人行道平路并避开车行干道..."
        defer {
            if myGeneration == snapGeneration {
                self.isSnapping = false
            }
        }

        // 0. 去除起笔收笔毛刺抖动
        let cleaned = cleanJitterAndHooks(rawCoordinates)
        guard cleaned.count >= 2 else {
            self.statusMessage = "绘制过于微小，请划出一段明显轨迹"
            return nil
        }

        // 1. 意图判定：自动识别用户是想画「环形闭环」还是「单向路线」
        let isLoopIntent = detectLoopIntent(cleaned)

        // 2. 若为闭环，先裁剪手绘收尾越过起点的重叠尾巴，再自适应提取骨干锚点
        let loopTrimmed = isLoopIntent ? trimSketchLoopOvershoot(cleaned) : cleaned
        var anchors = downsampleCoordinatesAdaptively(loopTrimmed, isLoop: isLoopIntent)

        if isLoopIntent, let first = anchors.first {
            anchors.append(first)
        }

        guard anchors.count >= 2 else {
            self.statusMessage = "关键锚点不足，请扩大画圈跨度"
            return nil
        }

        // 3. 串联发起步行路径吸附
        // 单段失败（如锚点落在河面/封闭园区内无路可达、或请求过于频繁被限流）不再导致整条路线失败：
        // 限流时等待后重试一次；仍失败则跳过该中间锚点，从上一个成功点直接连到下一个锚点
        var rawLegs: [[CLLocationCoordinate2D]] = []
        var rawTravelTimeSeconds: TimeInterval = 0.0
        var rawTotalDistance: Double = 0.0
        var candidateBarrierAlerts: [RouteBarrierAlert] = []
        var totalAvoidedHazards: Int = 0
        var skippedAnchors = 0
        var wasThrottled = false

        var legStart = anchors[0]
        var i = 1
        while i < anchors.count {
            var endPoint = anchors[i]
            let isIntermediateEnd = i < (anchors.count - 1)

            var selection = await requestWithRetry(from: legStart, to: endPoint, throttledFlag: &wasThrottled)

            if selection == nil {
                if isIntermediateEnd {
                    // 跳过这个无法到达的中间锚点
                    skippedAnchors += 1
                    i += 1
                    continue
                } else {
                    break
                }
            }

            // 若所有备选仍需走车行道/天桥，且终点是中间锚点：尝试把锚点向两侧平移 85 米再寻路
            if let current = selection, current.penaltyScore > 0, isIntermediateEnd {
                let nudgedCandidates = generateSidewalkNudgeCandidates(from: legStart, target: endPoint, offsetMeters: 85.0)
                for nudgedEnd in nudgedCandidates {
                    if let alt = try? await requestBestPedestrianRoute(from: legStart, to: nudgedEnd),
                       alt.route != nil,
                       alt.penaltyScore < (selection?.penaltyScore ?? 999) {
                        selection = alt
                        endPoint = nudgedEnd
                        anchors[i] = nudgedEnd
                        totalAvoidedHazards += 1
                        if alt.penaltyScore == 0 { break }
                    }
                }
            }

            if let chosen = selection, let chosenRoute = chosen.route {
                totalAvoidedHazards += chosen.avoidedCount
                candidateBarrierAlerts.append(contentsOf: chosen.remainingAlerts)
                let coords = extractCoordinates(from: chosenRoute.polyline)
                if coords.count >= 2 {
                    rawLegs.append(coords)
                    rawTravelTimeSeconds += chosenRoute.expectedTravelTime
                    rawTotalDistance += chosenRoute.distance
                }
            }
            legStart = endPoint
            i += 1
        }

        // 用户在等待期间又画了新线：丢弃本次旧结果
        guard myGeneration == snapGeneration else { return nil }

        guard !rawLegs.isEmpty else {
            self.statusMessage = wasThrottled
                ? "地图服务请求过于频繁，请稍等半分钟再画"
                : "此区域未匹配到可步行的连贯道路，请换个位置重画"
            return nil
        }

        // 4. 三重单枝根除引擎
        let stitchedDense = stitchLegsEliminatingJunctionSpurs(rawLegs)
        var spurFreeDense = eradicateAllSpursAndHairpins(stitchedDense, isLoop: isLoopIntent)

        // 安全阀：若裁剪后长度不足原路线 30%，说明用户本意可能就是「沿同一条路走出去再走回来」，此时只保留接缝级裁剪，避免路线被裁没
        let stitchedLen = calculateTotalDistance(stitchedDense)
        if stitchedLen > 0, calculateTotalDistance(spurFreeDense) < stitchedLen * 0.30 {
            spurFreeDense = stitchedDense
        }

        // 环形路线：裁掉起终点处「从起点走出去、最后又原路走回起点」的重叠尾巴，让起点落在真正的路口
        if isLoopIntent {
            spurFreeDense = trimLoopStartStub(spurFreeDense)
        }

        let cleanedCoords = simplifyCollinearPoints(spurFreeDense, minStep: 5.5)

        guard cleanedCoords.count >= 2 else {
            self.statusMessage = "未匹配到适宜步行的连贯路网"
            return nil
        }

        let activeAlerts = filterAlertsOnFinalRoute(alerts: candidateBarrierAlerts, routeCoords: cleanedCoords)

        let finalDistance = calculateTotalDistance(cleanedCoords)
        let paceRatio = rawTotalDistance > 10.0 ? (finalDistance / rawTotalDistance) : 1.0
        let adjustedSeconds = max(60.0, rawTravelTimeSeconds * min(1.0, max(0.3, paceRatio)))
        let finalPolyline = MKPolyline(coordinates: cleanedCoords, count: cleanedCoords.count)

        // 起终点标记使用真正贴在道路上的坐标（而不是手指画在楼房/园区里的原始点）
        var displayAnchors = anchors
        displayAnchors[0] = cleanedCoords.first!
        displayAnchors[displayAnchors.count - 1] = isLoopIntent ? cleanedCoords.first! : cleanedCoords.last!

        let result = SnappedRouteResult(
            polylines: [finalPolyline],
            anchorWaypoints: displayAnchors,
            totalDistanceMeters: finalDistance,
            estimatedTravelSeconds: adjustedSeconds,
            strideLength: strideLength,
            shape: isLoopIntent ? .loop : .open,
            barrierAlerts: activeAlerts,
            avoidedBarrierCount: totalAvoidedHazards
        )
        self.currentResult = result

        let routeTypeLabel = isLoopIntent ? "环形闭环" : "单向路线"
        let skipNote = skippedAnchors > 0 ? "（\(skippedAnchors) 处无路可达已绕开）" : ""
        if !activeAlerts.isEmpty {
            self.statusMessage = "⚠️ \(routeTypeLabel)：含 \(activeAlerts.count) 处天桥/车行段，地图已标橙色\(skipNote)"
        } else if totalAvoidedHazards > 0 {
            self.statusMessage = "✅ \(routeTypeLabel)：已避开 \(totalAvoidedHazards) 处车行道/天桥\(skipNote)"
        } else {
            self.statusMessage = "✅ \(routeTypeLabel)：未发现天桥/车行高架提示\(skipNote)"
        }
        return result
    }

    /// 带限流重试的单段寻路
    private func requestWithRetry(
        from start: CLLocationCoordinate2D,
        to end: CLLocationCoordinate2D,
        throttledFlag: inout Bool
    ) async -> RouteEvaluationResult? {
        for attempt in 0..<2 {
            do {
                let r = try await requestBestPedestrianRoute(from: start, to: end)
                return r.route == nil ? nil : r
            } catch {
                let nsErr = error as NSError
                let isThrottled = nsErr.domain == MKErrorDomain && nsErr.code == Int(MKError.loadingThrottled.rawValue)
                if isThrottled {
                    throttledFlag = true
                    if attempt == 0 {
                        try? await Task.sleep(nanoseconds: 2_500_000_000)
                        continue
                    }
                }
                return nil
            }
        }
        return nil
    }

    /// 环形路线起终点重叠尾巴裁剪：从首尾两端同时向内走，只要两端仍在同一条路上（≤10 米）就继续收缩
    private func trimLoopStartStub(_ coords: [CLLocationCoordinate2D]) -> [CLLocationCoordinate2D] {
        guard coords.count > 20 else { return coords }
        let ref = coords[0]
        let pts = toPlanarPoints(coords, reference: ref)
        let total = calculateTotalDistance(coords)
        var head = 0
        var tail = pts.count - 1
        var trimmedLen = 0.0

        while head + 1 < tail - 1 {
            let nextHead = head + 1
            var bestTail = -1
            var bestDSq = 100.0 // 10 米
            let low = max(nextHead + 1, tail - 6)
            if low > tail { break }
            for t in low...tail {
                let dx = pts[nextHead].x - pts[t].x
                let dy = pts[nextHead].y - pts[t].y
                let dSq = dx * dx + dy * dy
                if dSq <= bestDSq {
                    bestDSq = dSq
                    bestTail = t
                }
            }
            guard bestTail >= 0 else { break }
            let step = distanceBetween(coords[head], coords[nextHead])
            trimmedLen += step * 2
            if trimmedLen > total * 0.30 { break }
            head = nextHead
            tail = bestTail
        }

        guard head >= 3, tail > head + 10 else { return coords }
        var result = Array(coords[head...tail])
        result[result.count - 1] = result[0]
        return result
    }

    // MARK: - 行人步道优选与车行道/天桥规避引擎

    private struct RouteEvaluationResult {
        let route: MKRoute?
        let remainingAlerts: [RouteBarrierAlert]
        let avoidedCount: Int
        let penaltyScore: Int
    }

    /// 请求两点间步行路线，并在多条备选方案中综合评分，严厉排斥纯车行道（高架/隧道/匝道）与天桥台阶，优先选择双侧人行道街道
    private func requestBestPedestrianRoute(
        from startPoint: CLLocationCoordinate2D,
        to endPoint: CLLocationCoordinate2D
    ) async throws -> RouteEvaluationResult {
        let req = MKDirections.Request()
        req.source = MKMapItem(placemark: MKPlacemark(coordinate: startPoint))
        req.destination = MKMapItem(placemark: MKPlacemark(coordinate: endPoint))
        req.transportType = .walking
        req.requestsAlternateRoutes = true

        let directions = MKDirections(request: req)
        let response = try await directions.calculate()
        let routes = response.routes
        guard !routes.isEmpty else {
            return RouteEvaluationResult(route: nil, remainingAlerts: [], avoidedCount: 0, penaltyScore: 999)
        }

        struct ScoredCandidate {
            let route: MKRoute
            let alerts: [RouteBarrierAlert]
            let penaltyScore: Int
            let sidewalkBonus: Int
        }

        var candidates: [ScoredCandidate] = []
        for r in routes {
            let eval = evaluateRouteForPedestrianSidewalks(r)
            candidates.append(
                ScoredCandidate(
                    route: r,
                    alerts: eval.alerts,
                    penaltyScore: eval.penaltyScore,
                    sidewalkBonus: eval.sidewalkBonus
                )
            )
        }

        let defaultAlertsCount = candidates.first?.alerts.count ?? 0
        let shortestDist = routes.map { $0.distance }.min() ?? 1.0

        // 排序准则：
        // 1. 惩罚分（车行道 +100/处，天桥台阶 +60/处）越低越优先
        // 2. 同为 0 惩罚时，人行道正向特征分（sidewalkBonus）越高越优先
        // 3. 其次选路程更紧凑的方案
        let sorted = candidates.sorted { a, b in
            if a.penaltyScore != b.penaltyScore {
                return a.penaltyScore < b.penaltyScore
            }
            if a.sidewalkBonus != b.sidewalkBonus {
                return a.sidewalkBonus > b.sidewalkBonus
            }
            return a.route.distance < b.route.distance
        }

        if let best = sorted.first {
            // 允许为了避开车行道/天桥而合理绕行（距离不超过最短路线 1.85 倍或增量 <= 650 米）
            if best.route.distance <= shortestDist * 1.85 || (best.route.distance - shortestDist) <= 650.0 {
                let avoided = max(0, defaultAlertsCount - best.alerts.count)
                return RouteEvaluationResult(
                    route: best.route,
                    remainingAlerts: best.alerts,
                    avoidedCount: avoided,
                    penaltyScore: best.penaltyScore
                )
            }
        }

        let first = candidates[0]
        return RouteEvaluationResult(
            route: first.route,
            remainingAlerts: first.alerts,
            avoidedCount: 0,
            penaltyScore: first.penaltyScore
        )
    }

    /// 深度剖析单条路线的所有路段指令与告示：检验是否误入纯车行道、是否含天桥台阶、是否具备良好人行道
    private func evaluateRouteForPedestrianSidewalks(
        _ route: MKRoute
    ) -> (alerts: [RouteBarrierAlert], penaltyScore: Int, sidewalkBonus: Int) {
        var alerts: [RouteBarrierAlert] = []
        var penaltyScore = 0
        var sidewalkBonus = 0

        let routeNotices = route.advisoryNotices.joined(separator: " ")
        for item in vehicleOnlyKeywords {
            if routeNotices.localizedCaseInsensitiveContains(item.keyword) {
                penaltyScore += 100
            }
        }

        for step in route.steps {
            let text = step.instructions + " " + (step.notice ?? "")
            var matchedHazard = false

            // 1. 检查是否包含纯车行道（高架、快速路、匝道、隧道、机动车道等）
            for item in vehicleOnlyKeywords {
                if text.localizedCaseInsensitiveContains(item.keyword) {
                    // 特例排除：如果明确写着“人行道”或“辅路人行横道”，不误判为纯车行
                    if text.contains("人行") || text.contains("步行") {
                        continue
                    }
                    penaltyScore += 100
                    matchedHazard = true
                    let stepCoords = extractCoordinates(from: step.polyline)
                    if let coord = stepCoords.first {
                        alerts.append(
                            RouteBarrierAlert(
                                coordinate: coord,
                                title: item.label,
                                instruction: step.instructions.isEmpty ? "注意：此处靠近\(item.label)，请走外侧人行步道" : step.instructions
                            )
                        )
                    }
                    break
                }
            }

            // 2. 检查是否包含垂直通行障碍（人行天桥、地下通道、台阶等）
            if !matchedHazard {
                for item in verticalBarrierKeywords {
                    if text.localizedCaseInsensitiveContains(item.keyword) {
                        penaltyScore += 60
                        matchedHazard = true
                        let stepCoords = extractCoordinates(from: step.polyline)
                        if let coord = stepCoords.first {
                            alerts.append(
                                RouteBarrierAlert(
                                    coordinate: coord,
                                    title: item.label,
                                    instruction: step.instructions.isEmpty ? "此处含\(item.label)，可走附近平地斑马线绕行" : step.instructions
                                )
                            )
                        }
                        break
                    }
                }
            }

            // 3. 统计双侧人行道/斑马线/步行友好街区正向得分
            for friendly in sidewalkFriendlyKeywords {
                if text.localizedCaseInsensitiveContains(friendly) {
                    sidewalkBonus += 15
                }
            }
            // 常规城市生活街道（包含“街”或“路”且无高架/快速路字样）通常两侧均设有人行道
            if !matchedHazard && (text.contains("街") || text.contains("路")) {
                sidewalkBonus += 5
            }
        }

        return (alerts, penaltyScore, sidewalkBonus)
    }

    /// 当手绘锚点不幸刚好落在高架桥、车行隧道或主干道中央隔离带上时，生成向道路两侧垂直偏移 85 米的人行道候选锚点
    private func generateSidewalkNudgeCandidates(
        from start: CLLocationCoordinate2D,
        target: CLLocationCoordinate2D,
        offsetMeters: Double
    ) -> [CLLocationCoordinate2D] {
        let metersPerLat = 111132.0
        let metersPerLon = 111319.5 * cos(target.latitude * .pi / 180.0)
        guard metersPerLon > 1.0 else { return [] }

        let dx = (target.longitude - start.longitude) * metersPerLon
        let dy = (target.latitude - start.latitude) * metersPerLat
        let len = sqrt(dx * dx + dy * dy)
        guard len > 1.0 else { return [] }

        // 垂直于行进方向的左右单位法向量
        let nx = -dy / len
        let ny = dx / len

        let leftCoord = CLLocationCoordinate2D(
            latitude: target.latitude + (ny * offsetMeters) / metersPerLat,
            longitude: target.longitude + (nx * offsetMeters) / metersPerLon
        )
        let rightCoord = CLLocationCoordinate2D(
            latitude: target.latitude - (ny * offsetMeters) / metersPerLat,
            longitude: target.longitude - (nx * offsetMeters) / metersPerLon
        )
        return [leftCoord, rightCoord]
    }

    private func filterAlertsOnFinalRoute(
        alerts: [RouteBarrierAlert],
        routeCoords: [CLLocationCoordinate2D]
    ) -> [RouteBarrierAlert] {
        guard !alerts.isEmpty, !routeCoords.isEmpty else { return [] }
        var valid: [RouteBarrierAlert] = []

        for alert in alerts {
            var isOnRoute = false
            for pt in routeCoords {
                if distanceBetween(alert.coordinate, pt) <= 30.0 {
                    isOnRoute = true
                    break
                }
            }
            if isOnRoute {
                let isDuplicate = valid.contains { distanceBetween($0.coordinate, alert.coordinate) <= 45.0 }
                if !isDuplicate {
                    valid.append(alert)
                }
            }
        }
        return valid
    }

    // MARK: - 1. 智能闭环意图判定
    private func detectLoopIntent(_ points: [CLLocationCoordinate2D]) -> Bool {
        guard let first = points.first, let last = points.last, points.count >= 3 else {
            return false
        }
        let straightDist = distanceBetween(first, last)

        var totalPathDist: Double = 0.0
        for i in 0..<(points.count - 1) {
            totalPathDist += distanceBetween(points[i], points[i + 1])
        }

        if straightDist <= 220.0 {
            return true
        }
        if totalPathDist >= 350.0 && (straightDist / totalPathDist) <= 0.22 {
            return true
        }
        return false
    }

    /// 裁剪手绘画圈收笔时越过起点的重叠尾巴，防止最后一个锚点落在起点后方造成折返单枝
    private func trimSketchLoopOvershoot(_ points: [CLLocationCoordinate2D]) -> [CLLocationCoordinate2D] {
        guard points.count >= 12, let start = points.first else { return points }

        let searchStart = Int(Double(points.count) * 0.72)
        guard searchStart < points.count else { return points }

        var bestIdx = points.count - 1
        var minDist = distanceBetween(start, points[bestIdx])

        for i in searchStart..<(points.count - 1) {
            let d = distanceBetween(start, points[i])
            if d < minDist {
                minDist = d
                bestIdx = i
            }
        }

        return Array(points[0...bestIdx])
    }

    // MARK: - 2. 自适应降采样（保护大圈跨度并避免尾部锚点过密）
    private func downsampleCoordinatesAdaptively(_ points: [CLLocationCoordinate2D], isLoop: Bool) -> [CLLocationCoordinate2D] {
        guard points.count > 3 else { return points }

        var totalLen = 0.0
        for i in 0..<(points.count - 1) {
            totalLen += distanceBetween(points[i], points[i + 1])
        }

        let targetSegments = totalLen > 3000 ? 6 : (totalLen > 1200 ? 5 : 4)
        let stepInterval = totalLen / Double(targetSegments)

        var result: [CLLocationCoordinate2D] = [points.first!]
        var accumulated = 0.0
        var travelled = 0.0

        for i in 0..<(points.count - 1) {
            let seg = distanceBetween(points[i], points[i + 1])
            accumulated += seg
            travelled += seg

            // 若是环形路线，最后一个中间锚点与终点（起点）至少保留 0.65 个步长的余量，防止在起点旁产生小尾巴
            let remaining = totalLen - travelled
            if isLoop && remaining < stepInterval * 0.65 {
                break
            }

            if accumulated >= stepInterval && result.count < targetSegments {
                if !isLoop || distanceBetween(points[i + 1], points.first!) > stepInterval * 0.45 {
                    result.append(points[i + 1])
                    accumulated = 0.0
                }
            }
        }

        if !isLoop {
            if let last = points.last, distanceBetween(result.last!, last) > 40.0 {
                result.append(last)
            }
        }

        return result
    }

    private func cleanJitterAndHooks(_ raw: [CLLocationCoordinate2D]) -> [CLLocationCoordinate2D] {
        guard raw.count > 4 else { return raw }
        var filtered: [CLLocationCoordinate2D] = [raw[0]]
        for i in 1..<raw.count {
            if distanceBetween(filtered.last!, raw[i]) >= 8.0 {
                filtered.append(raw[i])
            }
        }
        return filtered
    }

    private func extractCoordinates(from poly: MKPolyline) -> [CLLocationCoordinate2D] {
        let count = poly.pointCount
        guard count > 0 else { return [] }
        var coords = [CLLocationCoordinate2D](repeating: CLLocationCoordinate2D(), count: count)
        poly.getCoordinates(&coords, range: NSRange(location: 0, length: count))
        return coords
    }

    // MARK: - 3. 路径加密与分段拼接回溯裁剪（第一道单枝防火墙）

    /// 将稀疏折线按固定步长（默认 3.0m）线性插值加密，确保直道上的任意丁字路口都有密集顶点
    private func densifyCoordinates(_ coords: [CLLocationCoordinate2D], stepMeters: Double = 3.0) -> [CLLocationCoordinate2D] {
        guard coords.count >= 2 else { return coords }
        var dense: [CLLocationCoordinate2D] = [coords[0]]

        for i in 0..<(coords.count - 1) {
            let a = coords[i]
            let b = coords[i + 1]
            let dist = distanceBetween(a, b)
            if dist <= 0.4 { continue }

            let steps = Int(ceil(dist / stepMeters))
            if steps <= 1 {
                dense.append(b)
            } else {
                for s in 1...steps {
                    let t = Double(s) / Double(steps)
                    let lat = a.latitude + (b.latitude - a.latitude) * t
                    let lon = a.longitude + (b.longitude - a.longitude) * t
                    dense.append(CLLocationCoordinate2D(latitude: lat, longitude: lon))
                }
            }
        }
        return dense
    }

    /// 逐段拼接路径，在每个中间锚点接缝处检测并切除「走出主路口到达锚点、再原路返回主路口」的折返单枝，精准停靠在主路口交点
    private func stitchLegsEliminatingJunctionSpurs(_ rawLegs: [[CLLocationCoordinate2D]]) -> [CLLocationCoordinate2D] {
        guard let firstLeg = rawLegs.first else { return [] }
        var accumulated = densifyCoordinates(firstLeg, stepMeters: 3.0)

        for legIdx in 1..<rawLegs.count {
            let nextLeg = densifyCoordinates(rawLegs[legIdx], stepMeters: 3.0)
            guard nextLeg.count >= 2, accumulated.count >= 2 else { continue }

            let refCoord = accumulated[accumulated.count - 1]
            let tailLimit = max(1, Int(Double(accumulated.count) * 0.12))
            let headLimit = min(nextLeg.count - 2, Int(Double(nextLeg.count) * 0.88))

            let accPlanar = toPlanarPoints(accumulated, reference: refCoord)
            let nextPlanar = toPlanarPoints(nextLeg, reference: refCoord)

            // 沿 accumulated 尾部向回搜索与 nextLeg 头部贴合的同路折返走廊（<= 8.5米代表同一条道路）
            let sameRoadThresholdSq = 8.5 * 8.5
            var divergentIa = accumulated.count - 1
            var matchedIbAtDivergence = 0
            var ia = accumulated.count - 1

            while ia >= tailLimit {
                let pa = accPlanar[ia]
                let searchStartIb = max(0, matchedIbAtDivergence - 4)
                let searchEndIb = min(headLimit, matchedIbAtDivergence + 120)

                var closestIb = -1
                var minDSq = Double.greatestFiniteMagnitude
                if searchStartIb <= searchEndIb {
                    for ib in searchStartIb...searchEndIb {
                        let pb = nextPlanar[ib]
                        let dSq = (pa.x - pb.x) * (pa.x - pb.x) + (pa.y - pb.y) * (pa.y - pb.y)
                        if dSq < minDSq {
                            minDSq = dSq
                            closestIb = ib
                        }
                    }
                }

                if minDSq <= sameRoadThresholdSq && closestIb >= 0 {
                    divergentIa = ia
                    if closestIb > matchedIbAtDivergence {
                        matchedIbAtDivergence = closestIb
                    }
                } else {
                    // 允许锚点顶端存在最多 18 个点（约 54m）的小掉头弯
                    let distFromSeam = accumulated.count - 1 - ia
                    if distFromSeam > 18 {
                        break
                    }
                }
                ia -= 1
            }

            // 在分叉路口附近微调 (bestIa, bestIb) 取距离最小的正交路口顶点，严禁斜切街角
            var bestIa = divergentIa
            var bestIb = matchedIbAtDivergence
            if divergentIa < accumulated.count - 1 {
                var bestPairDistSq = Double.greatestFiniteMagnitude
                let iaStart = max(tailLimit, divergentIa)
                let iaEnd = min(accumulated.count - 1, divergentIa + 5)
                let ibStart = max(0, matchedIbAtDivergence - 5)
                let ibEnd = min(headLimit, matchedIbAtDivergence + 5)

                if iaStart <= iaEnd && ibStart <= ibEnd {
                    for candIa in iaStart...iaEnd {
                        let pa = accPlanar[candIa]
                        for candIb in ibStart...ibEnd {
                            let pb = nextPlanar[candIb]
                            let dSq = (pa.x - pb.x) * (pa.x - pb.x) + (pa.y - pb.y) * (pa.y - pb.y)
                            if dSq < bestPairDistSq {
                                bestPairDistSq = dSq
                                bestIa = candIa
                                bestIb = candIb
                            }
                        }
                    }
                }
            }

            accumulated = Array(accumulated[0...bestIa])
            if bestIb + 1 < nextLeg.count {
                accumulated.append(contentsOf: nextLeg[(bestIb + 1)...])
            }
        }

        return accumulated
    }

    // MARK: - 4. 全局拓扑单枝与死胡同折返根除算法（第二道单枝防火墙 + 咽喉点精准对齐）

    /// 全局扫描加密路径，彻底剪除一切往返走廊单枝（直枝、L型枝、折线枝、长短盲端）及路口寄生死圈，同时保护 90 度正常街角与宏观大圈
    private func eradicateAllSpursAndHairpins(_ denseCoords: [CLLocationCoordinate2D], isLoop: Bool) -> [CLLocationCoordinate2D] {
        guard denseCoords.count > 6 else { return denseCoords }
        let ref = denseCoords[0]
        var pts = toPlanarPoints(denseCoords, reference: ref)

        let junctionRadius = 22.0
        let junctionRadiusSq = junctionRadius * junctionRadius

        for _ in 0..<6 {
            guard pts.count > 6 else { break }

            // 计算累计弧长数组
            var cumLen = [Double](repeating: 0.0, count: pts.count)
            for k in 1..<pts.count {
                let dx = pts[k].x - pts[k - 1].x
                let dy = pts[k].y - pts[k - 1].y
                cumLen[k] = cumLen[k - 1] + sqrt(dx * dx + dy * dy)
            }
            let totalLength = cumLen.last ?? 0.0
            guard totalLength > 30.0 else { break }

            // 任何单枝/局部死圈的弧长绝不可能超过整条路线的 44%（以此 100% 保护用户画的主体大环线）
            let maxSpurArcLength = totalLength * 0.44

            var nextPts: [PlanarPoint] = []
            var i = 0
            var modifiedInPass = false

            while i < pts.count {
                let pi = pts[i]
                var cutTargetJ: Int? = nil

                // 找到满足弧长上限的最大索引 maxJ
                var maxJ = i + 2
                while maxJ < pts.count && (cumLen[maxJ] - cumLen[i]) <= maxSpurArcLength {
                    maxJ += 1
                }
                maxJ -= 1

                if maxJ >= i + 2 {
                    // 从最远的潜在重合口向近处倒序扫描
                    for j in stride(from: maxJ, through: i + 2, by: -1) {
                        let pj = pts[j]
                        let dx = pi.x - pj.x
                        let dy = pi.y - pj.y
                        let directDistSq = dx * dx + dy * dy

                        if directDistSq <= junctionRadiusSq {
                            let directDist = sqrt(directDistSq)
                            let subArcLength = cumLen[j] - cumLen[i]

                            // 关键防护：正常 90 度街角的弧弦比约为 1.414；只有当弧长远大于直线距离（>= 3.8 倍且至少 8 米）时才可能是折返单枝或死圈
                            if subArcLength < 8.0 || subArcLength < directDist * 3.8 {
                                continue
                            }

                            if isSpurOrParasiticLoop(pts: pts, cumLen: cumLen, startIdx: i, endIdx: j, totalRouteLength: totalLength) {
                                // 在 j 附近收缩寻找离 pi 最近的真正路口顶点 bestJ（防止切过头产生街角斜边）
                                let refineStartJ = max(i + 2, j - 16)
                                let refineEndJ = min(maxJ, j + 2)
                                var bestJ = j
                                var bestDistSqAtI = directDistSq

                                for candJ in refineStartJ...refineEndJ {
                                    let pc = pts[candJ]
                                    let dSq = (pi.x - pc.x) * (pi.x - pc.x) + (pi.y - pc.y) * (pi.y - pc.y)
                                    let candArc = cumLen[candJ] - cumLen[i]
                                    if dSq < bestDistSqAtI && candArc >= max(6.0, sqrt(dSq) * 3.5) {
                                        bestDistSqAtI = dSq
                                        bestJ = candJ
                                    }
                                }

                                // 检查 i+1 是否正在逼近丁字路口顶点 J：如果再往前走一步距离路口更近，则先不提前斜切，让 i 走到正交路口顶点再切！
                                if i + 1 < bestJ - 2 && bestDistSqAtI > 2.2 * 2.2 {
                                    let pNextI = pts[i + 1]
                                    var minNextDistSq = Double.greatestFiniteMagnitude
                                    let checkLowJ = max(i + 3, bestJ - 10)
                                    let checkHighJ = min(maxJ, bestJ + 6)
                                    if checkLowJ <= checkHighJ {
                                        for cj in checkLowJ...checkHighJ {
                                            let pc = pts[cj]
                                            let dSq = (pNextI.x - pc.x) * (pNextI.x - pc.x) + (pNextI.y - pc.y) * (pNextI.y - pc.y)
                                            if dSq < minNextDistSq {
                                                minNextDistSq = dSq
                                            }
                                        }
                                    }
                                    if minNextDistSq < bestDistSqAtI - 1.2 {
                                        // i 尚未到达丁字路口咽喉点，放行当前点 pi，下一步在更精准的路口顶点处切除
                                        cutTargetJ = nil
                                        break
                                    }
                                }

                                cutTargetJ = bestJ
                                break
                            }
                        }
                    }
                }

                nextPts.append(pi)
                if let targetJ = cutTargetJ {
                    i = targetJ
                    modifiedInPass = true
                } else {
                    i += 1
                }
            }

            pts = nextPts
            if !modifiedInPass {
                break
            }
        }

        return pts.map { $0.coord }
    }

    /// 精确判定子路径 pts[startIdx...endIdx] 是否属于「往返单枝」或「路口寄生死圈」
    private func isSpurOrParasiticLoop(
        pts: [PlanarPoint],
        cumLen: [Double],
        startIdx: Int,
        endIdx: Int,
        totalRouteLength: Double
    ) -> Bool {
        let subLen = cumLen[endIdx] - cumLen[startIdx]
        let count = endIdx - startIdx + 1
        if count <= 4 || subLen <= 45.0 {
            return true
        }

        // 判据 1：路口微型寄生死圈（周长 <= 260m 且占全长比例 < 22%）
        if subLen <= 260.0 && subLen < totalRouteLength * 0.22 {
            return true
        }

        // 判据 2：计算子路径围合的多边形面积（鞋带公式）与等效平均宽度
        // 真正的往返单枝（哪怕长达上千米、呈 L 型或弯曲状）由于去程与回程沿同一街道折返，围合面积极小，等效宽度 <= 26m
        var twiceArea = 0.0
        let originX = pts[startIdx].x
        let originY = pts[startIdx].y
        for k in startIdx..<endIdx {
            let x1 = pts[k].x - originX
            let y1 = pts[k].y - originY
            let x2 = pts[k + 1].x - originX
            let y2 = pts[k + 1].y - originY
            twiceArea += (x1 * y2 - x2 * y1)
        }
        let enclosedArea = abs(twiceArea) * 0.5
        let halfPerimeter = max(1.0, subLen * 0.5)
        let meanWidth = enclosedArea / halfPerimeter

        if meanWidth <= 26.0 {
            return true
        }

        // 判据 3：去程与返程双向走廊贴合度检验（应对自交 8 字形折返单枝）
        let midArc = cumLen[startIdx] + subLen * 0.5
        var midIdx = startIdx + count / 2
        for k in startIdx...endIdx {
            if cumLen[k] >= midArc {
                midIdx = k
                break
            }
        }

        if midIdx > startIdx && midIdx < endIdx {
            let corridorThresholdSq = 28.0 * 28.0
            var matchedCount = 0
            var sampleCount = 0
            let sampleStep = max(1, (midIdx - startIdx) / 20)

            for a in stride(from: startIdx, through: midIdx, by: sampleStep) {
                sampleCount += 1
                let pa = pts[a]
                var minDSq = Double.greatestFiniteMagnitude
                for b in midIdx...endIdx {
                    let pb = pts[b]
                    let dSq = (pa.x - pb.x) * (pa.x - pb.x) + (pa.y - pb.y) * (pa.y - pb.y)
                    if dSq < minDSq {
                        minDSq = dSq
                    }
                }
                if minDSq <= corridorThresholdSq {
                    matchedCount += 1
                }
            }

            if sampleCount > 0 && Double(matchedCount) / Double(sampleCount) >= 0.80 {
                return true
            }
        }

        return false
    }

    // MARK: - 5. 坐标抽稀简化与平面投影工具

    /// 将加密处理后的纯净路线恢复为适度间隔的折线顶点，兼顾渲染流畅度与拐角锐利度
    private func simplifyCollinearPoints(_ coords: [CLLocationCoordinate2D], minStep: Double = 5.5) -> [CLLocationCoordinate2D] {
        guard coords.count > 2 else { return coords }
        var result: [CLLocationCoordinate2D] = [coords[0]]

        for i in 1..<(coords.count - 1) {
            let prev = result.last!
            let curr = coords[i]
            let next = coords[i + 1]

            let dist = distanceBetween(prev, curr)
            if dist >= minStep || turnAngleDegrees(prev, curr, next) >= 10.0 {
                result.append(curr)
            }
        }

        if let last = coords.last {
            result.append(last)
        }
        return result
    }

    private func turnAngleDegrees(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D, _ c: CLLocationCoordinate2D) -> Double {
        let cosLat = cos(b.latitude * .pi / 180.0)
        let v1x = (b.longitude - a.longitude) * cosLat
        let v1y = b.latitude - a.latitude
        let v2x = (c.longitude - b.longitude) * cosLat
        let v2y = c.latitude - b.latitude

        let len1 = sqrt(v1x * v1x + v1y * v1y)
        let len2 = sqrt(v2x * v2x + v2y * v2y)
        guard len1 > 1e-9 && len2 > 1e-9 else { return 0.0 }

        let dot = max(-1.0, min(1.0, (v1x * v2x + v1y * v2y) / (len1 * len2)))
        return acos(dot) * 180.0 / .pi
    }

    private func toPlanarPoints(_ coords: [CLLocationCoordinate2D], reference: CLLocationCoordinate2D) -> [PlanarPoint] {
        let metersPerLat = 111132.0
        let metersPerLon = 111319.5 * cos(reference.latitude * .pi / 180.0)
        return coords.map { c in
            PlanarPoint(
                x: (c.longitude - reference.longitude) * metersPerLon,
                y: (c.latitude - reference.latitude) * metersPerLat,
                coord: c
            )
        }
    }

    private func calculateTotalDistance(_ coords: [CLLocationCoordinate2D]) -> Double {
        guard coords.count > 1 else { return 0 }
        var dist = 0.0
        for i in 0..<(coords.count - 1) {
            dist += distanceBetween(coords[i], coords[i + 1])
        }
        return dist
    }

    private func distanceBetween(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D) -> Double {
        let locA = CLLocation(latitude: a.latitude, longitude: a.longitude)
        let locB = CLLocation(latitude: b.latitude, longitude: b.longitude)
        return locA.distance(from: locB)
    }

    func clear() {
        self.currentResult = nil
        self.statusMessage = "路线已清空，点击画笔即可重新随手涂鸦"
    }
}
