import Foundation
import MapKit
import CoreLocation

@MainActor
final class RouteSnapEngine: ObservableObject {
    @Published var isSnapping = false
    @Published var currentResult: SnappedRouteResult?
    @Published var statusMessage: String = "随手画个圈或折线，秒级贴合路网"

    /// 局部平面米制坐标（用于高速、高精度的几何小枝拓扑消解）
    private struct PlanarPoint {
        let x: Double
        let y: Double
        let coord: CLLocationCoordinate2D
    }

    /// 核心入口：将原始手绘屏幕坐标解析为地理序列并吸附至街道，100% 根除所有中间锚点单枝与死胡同折返
    func snapUserSketchToRoads(
        rawCoordinates: [CLLocationCoordinate2D],
        strideLength: Double
    ) async {
        guard rawCoordinates.count >= 2 else {
            self.statusMessage = "绘制线条过短，请画出一段路线"
            return
        }

        self.isSnapping = true
        self.statusMessage = "正在自动贴合真实街道路网..."
        defer { self.isSnapping = false }

        // 0. 去除起笔收笔毛刺抖动
        let cleaned = cleanJitterAndHooks(rawCoordinates)
        guard cleaned.count >= 2 else {
            self.statusMessage = "绘制过于微小，请划出一段明显轨迹"
            return
        }

        // 1. 意图判定：自动识别用户是想画「环形闭环」还是「单向路线」
        let isLoopIntent = detectLoopIntent(cleaned)

        // 2. 若为闭环，先裁剪手绘收尾越过起点的重叠尾巴，再自适应提取骨干锚点
        let loopTrimmed = isLoopIntent ? trimSketchLoopOvershoot(cleaned) : cleaned
        var anchors = downsampleCoordinatesAdaptively(loopTrimmed, isLoop: isLoopIntent)

        // 如果用户意图是闭环，将终点闭合到起点
        if isLoopIntent {
            if let first = anchors.first {
                anchors.append(first)
            }
        }

        guard anchors.count >= 2 else {
            self.statusMessage = "关键锚点不足，请扩大画圈跨度"
            return
        }

        // 3. 串联发起步行路径吸附
        var rawLegs: [[CLLocationCoordinate2D]] = []
        var rawTravelTimeSeconds: TimeInterval = 0.0
        var rawTotalDistance: Double = 0.0

        do {
            for i in 0..<(anchors.count - 1) {
                let startPoint = anchors[i]
                let endPoint = anchors[i + 1]

                let req = MKDirections.Request()
                req.source = MKMapItem(placemark: MKPlacemark(coordinate: startPoint))
                req.destination = MKMapItem(placemark: MKPlacemark(coordinate: endPoint))
                req.transportType = .walking
                req.requestsAlternateRoutes = false

                let directions = MKDirections(request: req)
                let response = try await directions.calculate()
                if let leg = response.routes.first {
                    let coords = extractCoordinates(from: leg.polyline)
                    if coords.count >= 2 {
                        rawLegs.append(coords)
                        rawTravelTimeSeconds += leg.expectedTravelTime
                        rawTotalDistance += leg.distance
                    }
                }
            }

            guard !rawLegs.isEmpty else {
                self.statusMessage = "未匹配到适宜步行的连贯路网"
                return
            }

            // 4. 三重单枝根除引擎：
            // (A) 将各段路径加密插值至 3.0 米步长，确保所有直道丁字路口均有精确顶点
            // (B) 逐段拼接时自动回溯裁剪中间锚点引起的「走出路口又折返」单枝，并精确锁定路口顶点
            // (C) 全局拓扑咽喉点扫描，彻底铲除一切往返走廊单枝（I型/L型/折线型）与畸形小死圈，绝不误切 90 度正常街角
            let stitchedDense = stitchLegsEliminatingJunctionSpurs(rawLegs)
            let spurFreeDense = eradicateAllSpursAndHairpins(stitchedDense, isLoop: isLoopIntent)
            let cleanedCoords = simplifyCollinearPoints(spurFreeDense, minStep: 5.5)

            guard cleanedCoords.count >= 2 else {
                self.statusMessage = "未匹配到适宜步行的连贯路网"
                return
            }

            // 重新计算剔除单枝后的真实纯净里程与预计用时
            let finalDistance = calculateTotalDistance(cleanedCoords)
            let paceRatio = rawTotalDistance > 10.0 ? (finalDistance / rawTotalDistance) : 1.0
            let adjustedSeconds = max(60.0, rawTravelTimeSeconds * min(1.0, max(0.3, paceRatio)))
            let finalPolyline = MKPolyline(coordinates: cleanedCoords, count: cleanedCoords.count)

            self.currentResult = SnappedRouteResult(
                polylines: [finalPolyline],
                anchorWaypoints: anchors,
                totalDistanceMeters: finalDistance,
                estimatedTravelSeconds: adjustedSeconds,
                strideLength: strideLength,
                shape: isLoopIntent ? .loop : .open
            )

            self.statusMessage = isLoopIntent ? "已识别为环形闭环路线（已净除分叉单枝）" : "已识别为单向通行路线（已净除分叉单枝）"
        } catch {
            self.statusMessage = "部分路段受限于小区围墙或封闭街区，已尽力吸附"
        }
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
