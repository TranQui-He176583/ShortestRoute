import 'dart:convert';
import "package:http/http.dart" as http;
import 'package:latlong2/latlong.dart';

class SearchResult {
  final String displayName;
  final double lat;
  final double lon;

  SearchResult({required this.displayName, required this.lat, required this.lon});

  factory SearchResult.fromJson(Map<String, dynamic> json) {
    return SearchResult(
      displayName: json['display_name'],
      lat: double.parse(json['lat']),
      lon: double.parse(json['lon']),
    );
  }
}

class ApiServices {
  static const String osrmBaseUrl = 'https://router.project-osrm.org';
  static const String nominatimUrl = 'https://nominatim.openstreetmap.org';
  // 1. Tìm kiếm địa điểm (Đã sửa lỗi User-Agent)
  static Future<List<SearchResult>> searchLocation(String query) async {
    if (query.trim().isEmpty) return [];

    try {
      // Encode query để xử lý tiếng Việt có dấu và dấu cách
      final encodedQuery = Uri.encodeComponent(query);
      final url = Uri.parse(
          '$nominatimUrl/search?q=$encodedQuery&format=json&limit=5&addressdetails=1&countrycodes=vn');

      final response = await http.get(
        url,
        headers: {
          'User-Agent': 'SmartRoutePlannerApp/1.0 (quitdhe176583@fpt.edu.vn)', // Thay email của bạn vào đây
          'Accept-Language': 'vi-VN,vi;q=0.9,en-US;q=0.8,en;q=0.7', // Ưu tiên kết quả tiếng Việt
        },
      );

      if (response.statusCode == 200) {
        final List data = json.decode(response.body);
        return data.map((json) => SearchResult.fromJson(json)).toList();
      } else {
        print('Nominatim Error: ${response.statusCode} - ${response.body}');
      }
    } catch (e) {
      print('Search Exception: $e');
    }
    return [];
  }

  // 2. Lấy ma trận khoảng cách
  static Future<List<List<double>>> getDistanceMatrix(List<LatLng> points) async {
    if (points.length < 2) return [];
    final coords = points.map((p) => '${p.longitude},${p.latitude}').join(';');
    try {
      final response = await http.get(
          Uri.parse('$osrmBaseUrl/table/v1/driving/$coords?annotations=distance'));
      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        List<dynamic> distances = data['distances'];
        return distances.map((row) => (row as List).map((v) => (v as num).toDouble()).toList()).toList();
      }
    } catch (e) {
      print('Matrix error: $e');
    }
    return [];
  }

  // 3. Lấy đường vẽ (Polyline)
  static Future<Map<String, dynamic>?> getRouteGeometry(List<LatLng> points) async {
    if (points.length < 2) return null;
    final coords = points.map((p) => '${p.longitude},${p.latitude}').join(';');
    try {
      final response = await http.get(
          Uri.parse('$osrmBaseUrl/route/v1/driving/$coords?overview=full&geometries=geojson'));
      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        final route = data['routes'][0];
        final coordinates = route['geometry']['coordinates'] as List;

        List<LatLng> polyline = coordinates
            .map((coord) => LatLng(coord[1], coord[0]))
            .toList();

        return {
          'distance': route['distance'],
          'duration': route['duration'],
          'polyline': polyline,
        };
      }
    } catch (e) {
      print('Route error: $e');
    }
    return null;
  }
}

// Thuật toán TSP (Nearest Neighbor + 2-opt)
class RouteOptimizer {
  final List<List<double>> distanceMatrix;
  final int numPoints;

  RouteOptimizer(this.distanceMatrix) : numPoints = distanceMatrix.length;

  List<int> solve() {
    if (numPoints < 2) return [0];
    List<int> currentPath = _nearestNeighbor();
    return _twoOpt(currentPath);
  }

  List<int> _nearestNeighbor() {
    Set<int> visited = {0};
    List<int> path = [0];
    int current = 0;

    while (visited.length < numPoints) {
      int nearest = -1;
      double minDist = double.infinity;

      for (int i = 0; i < numPoints; i++) {
        if (!visited.contains(i)) {
          double dist = distanceMatrix[current][i];
          if (dist < minDist) {
            minDist = dist;
            nearest = i;
          }
        }
      }
      if (nearest != -1) {
        path.add(nearest);
        visited.add(nearest);
        current = nearest;
      } else {
        break;
      }
    }
    return path;
  }

  List<int> _twoOpt(List<int> path) {
    List<int> bestPath = List.from(path);
    bool improved = true;
    int iterations = 0;

    while (improved && iterations < 100) {
      improved = false;
      iterations++;
      int n = bestPath.length;

      for (int i = 1; i < n - 1; i++) {
        for (int j = i + 1; j < n; j++) {
          if (j - i == 1) continue;

          List<int> newPath = _twoOptSwap(bestPath, i, j);
          double currentDist = _calculatePathDistance(bestPath);
          double newDist = _calculatePathDistance(newPath);

          if (newDist < currentDist) {
            bestPath = newPath;
            improved = true;
          }
        }
      }
    }
    return bestPath;
  }

  List<int> _twoOptSwap(List<int> path, int i, int j) {
    List<int> newPath = List.from(path);
    List<int> segment = newPath.sublist(i, j + 1).reversed.toList();
    newPath.replaceRange(i, j + 1, segment);
    return newPath;
  }

  double _calculatePathDistance(List<int> path) {
    double dist = 0;
    for (int i = 0; i < path.length - 1; i++) {
      dist += distanceMatrix[path[i]][path[i + 1]];
    }
    return dist;
  }
}