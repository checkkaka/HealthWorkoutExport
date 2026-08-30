import MapKit
import SwiftUI

enum TrackMapBaseLayer: Hashable {
    case china
    case openStreetMap
}

struct TrackMapLine {
    var id: String
    var coordinates: [CLLocationCoordinate2D]
    var color: UIColor
}

enum TrackMapProjection {
    static func coordinates(_ points: [FITTrackPoint], sourceIsGCJ: Bool) -> [CLLocationCoordinate2D] {
        points.map {
            let coordinate = sourceIsGCJ
                ? Gcj02ToWgs84.convert(latitude: $0.latitude, longitude: $0.longitude)
                : ($0.latitude, $0.longitude)
            return CLLocationCoordinate2D(latitude: coordinate.0, longitude: coordinate.1)
        }
    }
}

/// 国内原始轨迹使用系统国内底图；WGS 同步版使用 OSM 瓦片，避免混用坐标系。
struct TrackMapView: View {
    var baseLayer: TrackMapBaseLayer
    var lines: [TrackMapLine]
    var contentID: String
    var height: CGFloat

    @State private var focusToken = 0

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            TrackMKMapView(
                baseLayer: baseLayer,
                lines: lines,
                contentID: contentID,
                focusToken: focusToken
            )
            .id(baseLayer)
            Button { focusToken &+= 1 } label: {
                Image(systemName: "scope")
                    .font(.title3.weight(.semibold))
                    .frame(width: 44, height: 44)
                    .background(.regularMaterial, in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("回到轨迹")
            .padding(12)
        }
        .overlay(alignment: .bottomLeading) {
            if baseLayer == .openStreetMap {
                Link(destination: URL(string: "https://www.openstreetmap.org/copyright")!) {
                    Text("© OpenStreetMap contributors")
                        .font(.caption2)
                        .foregroundStyle(.primary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 4)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 5))
                }
                .padding(8)
            }
        }
        .frame(height: height)
    }
}

private struct TrackMKMapView: UIViewRepresentable {
    var baseLayer: TrackMapBaseLayer
    var lines: [TrackMapLine]
    var contentID: String
    var focusToken: Int

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> MKMapView {
        let mapView = MKMapView()
        mapView.delegate = context.coordinator
        mapView.showsCompass = true
        mapView.showsScale = true
        return mapView
    }

    func updateUIView(_ mapView: MKMapView, context: Context) {
        let coordinator = context.coordinator
        if coordinator.baseLayer != baseLayer {
            mapView.removeOverlays(mapView.overlays)
            coordinator.colors.removeAll()
            coordinator.contentID = nil
            coordinator.baseLayer = baseLayer
            if baseLayer == .openStreetMap {
                let tiles = OpenStreetMapTileOverlay()
                mapView.addOverlay(tiles, level: .aboveLabels)
            }
        }

        if coordinator.contentID != contentID {
            mapView.removeOverlays(mapView.overlays.compactMap { $0 as? MKPolyline })
            coordinator.colors.removeAll()
            for line in lines where line.coordinates.count > 1 {
                let polyline = MKPolyline(coordinates: line.coordinates, count: line.coordinates.count)
                coordinator.colors[ObjectIdentifier(polyline)] = line.color
                mapView.addOverlay(polyline, level: .aboveLabels)
            }
            coordinator.contentID = contentID
            focus(mapView)
        } else if coordinator.focusToken != focusToken {
            focus(mapView)
        }
        coordinator.focusToken = focusToken
    }

    private func focus(_ mapView: MKMapView) {
        let rects = mapView.overlays.compactMap { ($0 as? MKPolyline)?.boundingMapRect }
        guard var rect = rects.first else { return }
        for candidate in rects.dropFirst() { rect = rect.union(candidate) }
        mapView.setVisibleMapRect(
            rect,
            edgePadding: UIEdgeInsets(top: 28, left: 28, bottom: 28, right: 28),
            animated: true
        )
    }

    final class Coordinator: NSObject, MKMapViewDelegate {
        var baseLayer: TrackMapBaseLayer?
        var contentID: String?
        var focusToken = 0
        var colors: [ObjectIdentifier: UIColor] = [:]

        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            if let tiles = overlay as? MKTileOverlay {
                return MKTileOverlayRenderer(tileOverlay: tiles)
            }
            if let polyline = overlay as? MKPolyline {
                let renderer = MKPolylineRenderer(polyline: polyline)
                renderer.strokeColor = colors[ObjectIdentifier(polyline)] ?? .systemBlue
                renderer.lineWidth = 4
                renderer.lineJoin = .round
                renderer.lineCap = .round
                return renderer
            }
            return MKOverlayRenderer(overlay: overlay)
        }
    }
}

private final class OpenStreetMapTileOverlay: MKTileOverlay {
    init() {
        super.init(urlTemplate: "https://tile.openstreetmap.org/{z}/{x}/{y}.png")
        canReplaceMapContent = true
        minimumZ = 0
        maximumZ = 19
    }

    override func loadTile(
        at path: MKTileOverlayPath,
        result: @escaping (Data?, Error?) -> Void
    ) {
        let url = url(forTilePath: path)
        var request = URLRequest(url: url, cachePolicy: .useProtocolCachePolicy, timeoutInterval: 20)
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
        request.setValue(
            "HealthWorkoutExport/\(version)",
            forHTTPHeaderField: "User-Agent"
        )
        URLSession.shared.dataTask(with: request) { data, response, error in
            guard error == nil,
                  let http = response as? HTTPURLResponse,
                  (200...299).contains(http.statusCode),
                  let data else {
                result(nil, error ?? URLError(.badServerResponse))
                return
            }
            result(data, nil)
        }.resume()
    }
}
