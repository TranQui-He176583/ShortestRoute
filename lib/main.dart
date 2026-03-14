import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:geolocator/geolocator.dart';
import 'services.dart';

void main() {
  runApp(const MaterialApp(
    home: RoutePlannerScreen(),
    debugShowCheckedModeBanner: false,
  ));
}

class RoutePlannerScreen extends StatefulWidget {
  const RoutePlannerScreen({Key? key}) : super(key: key);

  @override
  State<RoutePlannerScreen> createState() => _RoutePlannerScreenState();
}

class _RoutePlannerScreenState extends State<RoutePlannerScreen> {
  final MapController _mapController = MapController();

  List<LatLng> points = [];
  List<String> pointNames = [];
  List<LatLng> optimizedPoints = [];
  List<LatLng> routePolyline = [];

  bool isOptimizing = false;
  double? totalDistance;

  // Search
  final TextEditingController _searchController = TextEditingController();
  Timer? _debounce;
  List<SearchResult> searchResults = [];
  bool isSearching = false;

  void _addPoint(LatLng latlng, [String name = "Điểm dừng"]) {
    setState(() {
      points.add(latlng);
      pointNames.add(name);
      optimizedPoints.clear();
      routePolyline.clear();
      totalDistance = null;
    });
  }

  void _onSearchChanged(String query) {
    if (_debounce?.isActive ?? false) _debounce!.cancel();
    _debounce = Timer(const Duration(milliseconds: 500), () async {
      if (query.length >= 2) {
        setState(() => isSearching = true);
        final results = await ApiServices.searchLocation(query);
        setState(() {
          searchResults = results;
          isSearching = false;
        });
      } else {
        setState(() => searchResults = []);
      }
    });
  }

  Future<void> _getCurrentLocation() async {
    bool serviceEnabled = await Geolocator.isLocationServiceEnabled();
    if (!serviceEnabled) return;

    LocationPermission permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
      if (permission == LocationPermission.denied) return;
    }

    Position position = await Geolocator.getCurrentPosition();
    LatLng currentLoc = LatLng(position.latitude, position.longitude);
    _addPoint(currentLoc, "Vị trí hiện tại");
    _mapController.move(currentLoc, 14);
  }

  Future<void> _optimizeRoute() async {
    if (points.length < 2) return;
    setState(() => isOptimizing = true);

    try {
      final matrix = await ApiServices.getDistanceMatrix(points);
      if (matrix.isEmpty) throw Exception("Lỗi lấy ma trận");

      final optimizer = RouteOptimizer(matrix);
      final pathIndices = optimizer.solve();

      List<LatLng> newOrderedPoints = pathIndices.map((i) => points[i]).toList();

      final routeData = await ApiServices.getRouteGeometry(newOrderedPoints);

      setState(() {
        optimizedPoints = newOrderedPoints;
        if (routeData != null) {
          routePolyline = routeData['polyline'];
          totalDistance = routeData['distance'];
        }
      });
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Lỗi tối ưu hóa lộ trình!')),
      );
    } finally {
      setState(() => isOptimizing = false);
    }
  }

  void _openGoogleMaps() async {
    if (optimizedPoints.isEmpty) return;

    final origin = optimizedPoints.first;
    final dest = optimizedPoints.last;

    String waypoints = "";
    if (optimizedPoints.length > 2) {
      final wpList = optimizedPoints.sublist(1, optimizedPoints.length - 1);
      waypoints = "&waypoints=${wpList.map((p) => '${p.latitude},${p.longitude}').join('|')}";
    }

    final url = Uri.parse(
        'https://www.google.com/maps/dir/?api=1&origin=${origin.latitude},${origin.longitude}&destination=${dest.latitude},${dest.longitude}$waypoints&travelmode=driving');

    if (await canLaunchUrl(url)) {
      await launchUrl(
        url,
        mode: LaunchMode.externalApplication,
      );
    } else {
      throw 'Could not launch $url';
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('SmartRoute Planner'),
        actions: [
          if (points.isNotEmpty)
            IconButton(
              icon: const Icon(Icons.delete_sweep),
              onPressed: () => setState(() {
                points.clear();
                pointNames.clear();
                optimizedPoints.clear();
                routePolyline.clear();
                totalDistance = null;
              }),
            )
        ],
      ),
      body: Column(
        children: [
          // Thanh tìm kiếm
          Padding(
            padding: const EdgeInsets.all(8.0),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _searchController,
                    onChanged: _onSearchChanged,
                    decoration: InputDecoration(
                      hintText: 'Tìm kiếm địa điểm...',
                      prefixIcon: const Icon(Icons.search),
                      suffixIcon: isSearching
                          ? const Padding(
                        padding: EdgeInsets.all(12.0),
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                          : null,
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
                      contentPadding: const EdgeInsets.symmetric(vertical: 0),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                IconButton.filledTonal(
                  icon: const Icon(Icons.my_location),
                  onPressed: _getCurrentLocation,
                ),
              ],
            ),
          ),

          // Kết quả tìm kiếm (Đã sửa layout)
          if (searchResults.isNotEmpty)
            Container(
              margin: const EdgeInsets.symmetric(horizontal: 8.0),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(8),
                boxShadow: const [
                  BoxShadow(color: Colors.black12, blurRadius: 4, offset: Offset(0, 2))
                ],
              ),
              // Giới hạn chiều cao tối đa để không đẩy bản đồ biến mất
              constraints: const BoxConstraints(maxHeight: 250),
              child: ListView.separated(
                shrinkWrap: true, // Quan trọng: Để ListView tự co lại theo nội dung
                itemCount: searchResults.length,
                separatorBuilder: (context, index) => const Divider(height: 1),
                itemBuilder: (context, index) {
                  final res = searchResults[index];
                  // Tách tên chính và địa chỉ phụ cho đẹp
                  final parts = res.displayName.split(',');
                  final mainName = parts.isNotEmpty ? parts[0].trim() : res.displayName;
                  final subName = parts.length > 1 ? parts.sublist(1).join(',').trim() : '';

                  return ListTile(
                    leading: const Icon(Icons.location_on, color: Colors.blue),
                    title: Text(mainName, style: const TextStyle(fontWeight: FontWeight.bold)),
                    subtitle: subName.isNotEmpty
                        ? Text(subName, maxLines: 1, overflow: TextOverflow.ellipsis)
                        : null,
                    onTap: () {
                      FocusScope.of(context).unfocus();

                      _addPoint(LatLng(res.lat, res.lon), mainName);
                      _mapController.move(LatLng(res.lat, res.lon), 15);
                      setState(() {
                        searchResults.clear();
                        _searchController.clear();
                      });
                    },
                  );
                },
              ),
            ),

          // Bản đồ
          Expanded(
            child: FlutterMap(
              mapController: _mapController,
              options: MapOptions(
                initialCenter: const LatLng(21.0285, 105.8542), // Hà Nội
                initialZoom: 13.0,
                onTap: (tapPosition, point) => _addPoint(point),
              ),
              children: [
                TileLayer(
                  urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                  userAgentPackageName: 'com.example.manylocationmap',
                ),
                if (routePolyline.isNotEmpty)
                  PolylineLayer(
                    polylines: [
                      Polyline(
                        points: routePolyline,
                        color: Colors.blue,
                        strokeWidth: 4.0,
                      ),
                    ],
                  ),
                MarkerLayer(
                  markers: points.asMap().entries.map((entry) {
                    int idx = entry.key;
                    LatLng point = entry.value;

                    int displayIdx = idx + 1;
                    if (optimizedPoints.isNotEmpty) {
                      displayIdx = optimizedPoints.indexOf(point) + 1;
                    }

                    return Marker(
                      point: point,
                      width: 30,
                      height: 30,
                      child: Container(
                        decoration: const BoxDecoration(
                          color: Colors.blue,
                          shape: BoxShape.circle,
                        ),
                        child: Center(
                          child: Text(
                            '$displayIdx',
                            style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
                          ),
                        ),
                      ),
                    );
                  }).toList(),
                ),
              ],
            ),
          ),

          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: Colors.white,
              boxShadow: [BoxShadow(color: Colors.black12, blurRadius: 10, offset: Offset(0, -2))],
            ),
            child: Column(
              children: [
                if (totalDistance != null)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8.0),
                    child: Text(
                      'Tổng quãng đường: ${(totalDistance! / 1000).toStringAsFixed(2)} km',
                      style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
                    ),
                  ),
                Row(
                  children: [
                    Expanded(
                      child: ElevatedButton.icon(
                        icon: isOptimizing
                            ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2))
                            : const Icon(Icons.route),
                        label: const Text('Tối ưu lộ trình'),
                        onPressed: (points.length < 2 || isOptimizing) ? null : _optimizeRoute,
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.blue,
                          foregroundColor: Colors.white,
                          padding: const EdgeInsets.symmetric(vertical: 12),
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: ElevatedButton.icon(
                        icon: const Icon(Icons.navigation),
                        label: const Text('Điều hướng'),
                        onPressed: optimizedPoints.isEmpty ? null : _openGoogleMaps,
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.green,
                          foregroundColor: Colors.white,
                          padding: const EdgeInsets.symmetric(vertical: 12),
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}