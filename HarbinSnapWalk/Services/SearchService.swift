import Foundation
import MapKit
import Combine

struct SearchResultItem: Identifiable, Equatable {
    let id = UUID()
    let title: String
    let subtitle: String
    let coordinate: CLLocationCoordinate2D?
    
    static func == (lhs: SearchResultItem, rhs: SearchResultItem) -> Bool {
        lhs.title == rhs.title && lhs.subtitle == rhs.subtitle
    }
}

@MainActor
final class SearchService: NSObject, ObservableObject, MKLocalSearchCompleterDelegate {
    @Published var queryText = "" {
        didSet { completer.queryFragment = queryText }
    }
    @Published var searchResults: [SearchResultItem] = []
    @Published var isSearching = false

    private let completer = MKLocalSearchCompleter()
    
    override init() {
        super.init()
        completer.delegate = self
        completer.resultTypes = [.address, .pointOfInterest]
    }

    func completerDidUpdateResults(_ completer: MKLocalSearchCompleter) {
        self.searchResults = completer.results.map { res in
            SearchResultItem(title: res.title, subtitle: res.subtitle, coordinate: nil)
        }
    }

    func completer(_ completer: MKLocalSearchCompleter, didFailWithError error: Error) {
        print("搜索联想失败: \(error.localizedDescription)")
    }

    /// 根据选中的联想词解析精确经纬度
    func resolveCoordinate(for item: SearchResultItem) async -> CLLocationCoordinate2D? {
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = "\(item.title) \(item.subtitle)"
        let search = MKLocalSearch(request: request)
        do {
            let resp = try await search.start()
            return resp.mapItems.first?.placemark.coordinate
        } catch {
            print("地点解析失败: \(error.localizedDescription)")
            return nil
        }
    }
}
