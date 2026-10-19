import Foundation
import CoreLocation
import MapKit

struct SavedRoute: Identifiable, Codable {
    let id: UUID
    var name: String
    let cityName: String
    let createdAt: Date
    let distanceMeters: Double
    let estimatedTravelSeconds: TimeInterval
    let estimatedSteps: Int
    let estimatedCalories: Double
    let isLoop: Bool
    let coordinatesData: [[Double]] // [[lat, lon], ...]

    var distanceKmFormatted: String {
        String(format: "%.2f km", distanceMeters / 1000.0)
    }

    var durationFormatted: String {
        let mins = Int(round(estimatedTravelSeconds / 60.0))
        let hrs = mins / 60
        let remainMins = mins % 60
        if hrs > 0 {
            return "\(hrs)小时\(remainMins)分"
        } else {
            return "\(mins)分钟"
        }
    }

    var coordinates: [CLLocationCoordinate2D] {
        coordinatesData.map { CLLocationCoordinate2D(latitude: $0[0], longitude: $0[1]) }
    }

    func toSnappedRouteResult(strideLength: Double) -> SnappedRouteResult {
        let coords = self.coordinates
        let poly = MKPolyline(coordinates: coords, count: coords.count)
        return SnappedRouteResult(
            polylines: [poly],
            anchorWaypoints: coords.isEmpty ? [] : [coords.first!, coords.last!],
            totalDistanceMeters: distanceMeters,
            estimatedTravelSeconds: estimatedTravelSeconds,
            strideLength: strideLength,
            shape: isLoop ? .loop : .open
        )
    }
}

@MainActor
final class SavedRouteStore: ObservableObject {
    @Published var savedRoutes: [SavedRoute] = []
    
    private let fileName = "saved_routes.json"

    private var fileURL: URL {
        let paths = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)
        return paths[0].appendingPathComponent(fileName)
    }

    init() {
        load()
    }

    func saveRoute(
        name: String,
        result: SnappedRouteResult,
        cityName: String,
        weightKg: Double
    ) {
        let coords = result.allRouteCoordinates
        let coordsData = coords.map { [$0.latitude, $0.longitude] }
        let newRoute = SavedRoute(
            id: UUID(),
            name: name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "\(cityName) \(result.distanceKmFormatted) 路线" : name,
            cityName: cityName,
            createdAt: Date(),
            distanceMeters: result.totalDistanceMeters,
            estimatedTravelSeconds: result.estimatedTravelSeconds,
            estimatedSteps: result.estimatedSteps,
            estimatedCalories: result.estimatedCalories(weightKg: weightKg),
            isLoop: result.shape == .loop,
            coordinatesData: coordsData
        )
        savedRoutes.insert(newRoute, at: 0)
        persist()
    }

    func renameRoute(id: UUID, newName: String) {
        if let idx = savedRoutes.firstIndex(where: { $0.id == id }) {
            savedRoutes[idx].name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
            persist()
        }
    }

    func deleteRoute(by id: UUID) {
        savedRoutes.removeAll { $0.id == id }
        persist()
    }

    func deleteRoute(at offsets: IndexSet) {
        savedRoutes.remove(atOffsets: offsets)
        persist()
    }

    private func persist() {
        do {
            let data = try JSONEncoder().encode(savedRoutes)
            try data.write(to: fileURL, options: [.atomicWrite, .completeFileProtection])
        } catch {
            print("保存收藏路线失败: \(error.localizedDescription)")
        }
    }

    private func load() {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        do {
            let data = try Data(contentsOf: fileURL)
            self.savedRoutes = try JSONDecoder().decode([SavedRoute].self, from: data)
        } catch {
            print("加载收藏路线失败: \(error.localizedDescription)")
        }
    }
}
