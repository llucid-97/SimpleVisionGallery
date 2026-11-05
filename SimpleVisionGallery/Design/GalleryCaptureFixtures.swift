#if DEBUG
import Foundation

/// The same declared synthetic records are bundled in the capture app and imported into Photos.
enum GalleryCaptureFixtures {
    struct Record: Decodable, Identifiable {
        let index: Int
        let filename: String
        let title: String
        let scene: Int
        let orientation: String
        let width: Int
        let height: Int
        let duplicateOf: Int?
        var id: Int { index }
    }
    private struct Fixture: Decodable { let records: [Record] }
    static let records: [Record] = {
        guard let url = Bundle.main.url(forResource: "capture-fixtures", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let fixture = try? JSONDecoder().decode(Fixture.self, from: data) else { return [] }
        return fixture.records
    }()
    static let titles = ["City at Dusk", "Coastal Walk", "Forest Light", "Mountain Lakes", "High Country", "Last Light"]
    static func filename(index: Int) -> String { String(format: "capture-%02d", index) }
}
#endif
