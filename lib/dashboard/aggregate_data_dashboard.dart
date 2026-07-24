// lib/dashboard/aggregate_data_dashboard.dart
//
// GeoWake — buyer-facing aggregate mobility data dashboard.
//
// Fetches k-anonymized, DP-noised aggregate O-D flow data from the backend
// merge engine and visualizes it for transit-authority / urban-planner buyers.
//
// Run with:
//   flutter run -d chrome -t lib/main_aggregate_dashboard.dart --web-port 8081

import 'dart:convert';
import 'dart:developer' as dev;

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

/// Entry point for the aggregate data dashboard.
void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const AggregateDashboardApp());
}

class AggregateDashboardApp extends StatelessWidget {
  const AggregateDashboardApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'GeoWake — Mobility Data Dashboard',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF1A73E8),
          brightness: Brightness.light,
        ),
        cardTheme: const CardThemeData(
          elevation: 2,
          margin: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        ),
      ),
      home: const AggregateDashboard(),
    );
  }
}

// ---------------------------------------------------------------------------
// API client
// ---------------------------------------------------------------------------

class AggregateApiClient {
  static const String _defaultBaseUrl =
      'https://geowake-production.up.railway.app/api/aggregate';

  final String baseUrl;
  final http.Client _client;

  AggregateApiClient({String? baseUrl, http.Client? client})
      : baseUrl = baseUrl ?? _defaultBaseUrl,
        _client = client ?? http.Client();

  Future<Map<String, dynamic>> fetchSummary() async {
    final res = await _client
        .get(Uri.parse('$baseUrl/summary'))
        .timeout(const Duration(seconds: 15));
    if (res.statusCode != 200) {
      throw Exception('GET /summary failed: ${res.statusCode}');
    }
    final body = jsonDecode(res.body);
    if (body['success'] != true) {
      throw Exception('API error: ${body['error']}');
    }
    return body['data'] as Map<String, dynamic>;
  }

  Future<Map<String, dynamic>> fetchStats() async {
    final res = await _client
        .get(Uri.parse('$baseUrl/stats'))
        .timeout(const Duration(seconds: 15));
    if (res.statusCode != 200) {
      throw Exception('GET /stats failed: ${res.statusCode}');
    }
    final body = jsonDecode(res.body);
    if (body['success'] != true) {
      throw Exception('API error: ${body['error']}');
    }
    return body['data'] as Map<String, dynamic>;
  }

  void close() => _client.close();
}

// ---------------------------------------------------------------------------
// Dashboard screen
// ---------------------------------------------------------------------------

class AggregateDashboard extends StatefulWidget {
  const AggregateDashboard({super.key});

  @override
  State<AggregateDashboard> createState() => _AggregateDashboardState();
}

class _AggregateDashboardState extends State<AggregateDashboard>
    with SingleTickerProviderStateMixin {
  late final TabController _tabController;
  final AggregateApiClient _api = AggregateApiClient();

  Map<String, dynamic>? _summary;
  Map<String, dynamic>? _stats;
  String? _error;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 4, vsync: this);
    _refresh();
  }

  @override
  void dispose() {
    _tabController.dispose();
    _api.close();
    super.dispose();
  }

  Future<void> _refresh() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final results = await Future.wait([
        _api.fetchSummary(),
        _api.fetchStats(),
      ]);
      setState(() {
        _summary = results[0];
        _stats = results[1];
        _loading = false;
      });
    } catch (e) {
      dev.log('Dashboard fetch failed: $e', name: 'AggregateDashboard');
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Row(
          children: [
            Icon(Icons.analytics, size: 28),
            SizedBox(width: 12),
            Text('GeoWake Mobility Data'),
          ],
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: _loading ? null : _refresh,
            tooltip: 'Refresh data',
          ),
        ],
        bottom: TabBar(
          controller: _tabController,
          tabs: const [
            Tab(text: 'Overview', icon: Icon(Icons.dashboard)),
            Tab(text: 'O-D Flows', icon: Icon(Icons.swap_horiz)),
            Tab(text: 'Station Catchment', icon: Icon(Icons.place)),
            Tab(text: 'Privacy', icon: Icon(Icons.shield)),
          ],
        ),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? _ErrorView(error: _error!, onRetry: _refresh)
              : TabBarView(
                  controller: _tabController,
                  children: [
                    OverviewTab(summary: _summary, stats: _stats),
                    OdFlowsTab(summary: _summary),
                    CatchmentTab(summary: _summary),
                    PrivacyTab(summary: _summary, stats: _stats),
                  ],
                ),
    );
  }
}

// ---------------------------------------------------------------------------
// Overview tab
// ---------------------------------------------------------------------------

class OverviewTab extends StatelessWidget {
  final Map<String, dynamic>? summary;
  final Map<String, dynamic>? stats;

  const OverviewTab({this.summary, this.stats, super.key});

  @override
  Widget build(BuildContext context) {
    final overview = summary?['overview'] as Map<String, dynamic>?;
    final hourlyDemand = summary?['hourlyDemand'] as List<dynamic>?;

    if (overview == null) {
      return const Center(child: Text('No data available'));
    }

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        // KPI cards
        Wrap(
          spacing: 12,
          runSpacing: 12,
          children: [
            _KpiCard(
              title: 'Contributing Devices',
              value: '${overview['totalDevices'] ?? 0}',
              icon: Icons.phone_android,
              color: Colors.blue,
            ),
            _KpiCard(
              title: 'Released O-D Cells',
              value: '${overview['releasedOdCells'] ?? 0}',
              icon: Icons.grid_on,
              color: Colors.green,
            ),
            _KpiCard(
              title: 'Origin Stations',
              value: '${overview['uniqueOriginStations'] ?? 0}',
              icon: Icons.my_location,
              color: Colors.orange,
            ),
            _KpiCard(
              title: 'Destination Stations',
              value: '${overview['uniqueDestStations'] ?? 0}',
              icon: Icons.place,
              color: Colors.purple,
            ),
            _KpiCard(
              title: 'Weekday Demand',
              value: '${overview['weekdayDemand'] ?? 0}',
              icon: Icons.work,
              color: Colors.indigo,
            ),
            _KpiCard(
              title: 'Weekend Demand',
              value: '${overview['weekendDemand'] ?? 0}',
              icon: Icons.weekend,
              color: Colors.teal,
            ),
          ],
        ),
        const SizedBox(height: 24),
        // Hourly demand chart
        if (hourlyDemand != null && hourlyDemand.isNotEmpty) ...[
          Text('Hourly Demand Distribution',
              style: Theme.of(context).textTheme.headlineSmall),
          const SizedBox(height: 12),
          _HourlyDemandChart(hourlyDemand: hourlyDemand),
        ],
        const SizedBox(height: 24),
        // Last ingest
        if (overview['lastIngestAt'] != null)
          Card(
            child: ListTile(
              leading: const Icon(Icons.schedule, color: Colors.grey),
              title: const Text('Last Data Ingest'),
              subtitle: Text('${overview['lastIngestAt']}'),
            ),
          ),
      ],
    );
  }
}

class _KpiCard extends StatelessWidget {
  final String title;
  final String value;
  final IconData icon;
  final Color color;

  const _KpiCard({
    required this.title,
    required this.value,
    required this.icon,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 200,
      child: Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(icon, color: color, size: 24),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      title,
                      style: Theme.of(context).textTheme.bodySmall,
                      maxLines: 2,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Text(
                value,
                style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                      fontWeight: FontWeight.bold,
                      color: color,
                    ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _HourlyDemandChart extends StatelessWidget {
  final List<dynamic> hourlyDemand;

  const _HourlyDemandChart({required this.hourlyDemand});

  @override
  Widget build(BuildContext context) {
    final maxCount = hourlyDemand.fold<double>(
      0,
      (max, item) {
        final count = (item as Map<String, dynamic>)['count'] as num? ?? 0;
        return count > max ? count.toDouble() : max;
      },
    );

    if (maxCount == 0) {
      return const Card(
        child: Padding(
          padding: EdgeInsets.all(32),
          child: Center(child: Text('No released demand data yet')),
        ),
      );
    }

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            for (final item in hourlyDemand)
              _HourBar(
                hour: (item as Map<String, dynamic>)['hour'] as int? ?? 0,
                count: (item['count'] as num?)?.toDouble() ?? 0,
                maxCount: maxCount,
              ),
          ],
        ),
      ),
    );
  }
}

class _HourBar extends StatelessWidget {
  final int hour;
  final double count;
  final double maxCount;

  const _HourBar({
    required this.hour,
    required this.count,
    required this.maxCount,
  });

  @override
  Widget build(BuildContext context) {
    final fraction = maxCount > 0 ? count / maxCount : 0.0;
    final isPeak = fraction > 0.7;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          SizedBox(
            width: 50,
            child: Text(
              '${hour.toString().padLeft(2, '0')}:00',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
          Expanded(
            child: Stack(
              children: [
                Container(
                  height: 20,
                  decoration: BoxDecoration(
                    color: Colors.grey.shade200,
                    borderRadius: BorderRadius.circular(4),
                  ),
                ),
                FractionallySizedBox(
                  widthFactor: fraction.clamp(0.0, 1.0),
                  child: Container(
                    height: 20,
                    decoration: BoxDecoration(
                      color: isPeak ? Colors.red.shade400 : Colors.blue.shade400,
                      borderRadius: BorderRadius.circular(4),
                    ),
                  ),
                ),
              ],
            ),
          ),
          SizedBox(
            width: 60,
            child: Text(
              count > 0 ? count.toInt().toString() : '',
              style: Theme.of(context).textTheme.bodySmall,
              textAlign: TextAlign.right,
            ),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// O-D Flows tab
// ---------------------------------------------------------------------------

class OdFlowsTab extends StatelessWidget {
  final Map<String, dynamic>? summary;

  const OdFlowsTab({this.summary, super.key});

  @override
  Widget build(BuildContext context) {
    final flows = summary?['topFlows'] as List<dynamic>?;

    if (flows == null || flows.isEmpty) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(32),
          child: Text(
            'No released O-D flows yet.\n\n'
            'Flows appear here once enough contributing devices '
            '(≥100 per cell) generate k-anonymous aggregate data.',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 16, color: Colors.grey),
          ),
        ),
      );
    }

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            children: [
              Text('Top O-D Flows',
                  style: Theme.of(context).textTheme.headlineSmall),
              const Spacer(),
              Text('${flows.length} flows',
                  style: Theme.of(context).textTheme.bodySmall),
            ],
          ),
        ),
        Expanded(
          child: ListView.builder(
            itemCount: flows.length,
            itemBuilder: (context, index) {
              final flow = flows[index] as Map<String, dynamic>;
              return _FlowTile(flow: flow, rank: index + 1);
            },
          ),
        ),
      ],
    );
  }
}

class _FlowTile extends StatelessWidget {
  final Map<String, dynamic> flow;
  final int rank;

  const _FlowTile({required this.flow, required this.rank});

  @override
  Widget build(BuildContext context) {
    final origin = flow['originStationId'] as String? ?? '?';
    final dest = flow['destStationId'] as String? ?? '?';
    final count = flow['noisyCount'] as int? ?? 0;
    final hour = flow['hourBin'] as int? ?? 0;
    final dayType = flow['dayType'] as String? ?? '?';
    final contributing = flow['contributingUsers'] as int? ?? 0;

    return Card(
      child: ListTile(
        leading: CircleAvatar(
          backgroundColor: Colors.blue.shade100,
          child: Text('#$rank',
              style: TextStyle(color: Colors.blue.shade700, fontSize: 12)),
        ),
        title: Text(
          '$origin → $dest',
          style: const TextStyle(fontWeight: FontWeight.w600),
        ),
        subtitle: Text(
          '${hour.toString().padLeft(2, '0')}:00 · $dayType · '
          '$contributing devices',
        ),
        trailing: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          decoration: BoxDecoration(
            color: Colors.green.shade100,
            borderRadius: BorderRadius.circular(12),
          ),
          child: Text(
            '$count riders',
            style: TextStyle(
              color: Colors.green.shade800,
              fontWeight: FontWeight.bold,
            ),
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Station Catchment tab
// ---------------------------------------------------------------------------

class CatchmentTab extends StatelessWidget {
  final Map<String, dynamic>? summary;

  const CatchmentTab({this.summary, super.key});

  @override
  Widget build(BuildContext context) {
    final stations = summary?['topStations'] as List<dynamic>?;

    if (stations == null || stations.isEmpty) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(32),
          child: Text(
            'No released catchment data yet.\n\n'
            'Station arrival volumes appear here once enough '
            'contributing devices generate k-anonymous data.',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 16, color: Colors.grey),
          ),
        ),
      );
    }

    final maxArrivals = stations.fold<double>(
      0,
      (max, item) {
        final total =
            (item as Map<String, dynamic>)['totalArrivals'] as num? ?? 0;
        return total > max ? total.toDouble() : max;
      },
    );

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.all(16),
          child: Text('Top Stations by Arrival Volume',
              style: Theme.of(context).textTheme.headlineSmall),
        ),
        Expanded(
          child: ListView.builder(
            itemCount: stations.length,
            itemBuilder: (context, index) {
              final station = stations[index] as Map<String, dynamic>;
              return _StationBar(
                stationId: station['stationId'] as String? ?? '?',
                arrivals: (station['totalArrivals'] as num?)?.toDouble() ?? 0,
                maxArrivals: maxArrivals,
                rank: index + 1,
              );
            },
          ),
        ),
      ],
    );
  }
}

class _StationBar extends StatelessWidget {
  final String stationId;
  final double arrivals;
  final double maxArrivals;
  final int rank;

  const _StationBar({
    required this.stationId,
    required this.arrivals,
    required this.maxArrivals,
    required this.rank,
  });

  @override
  Widget build(BuildContext context) {
    final fraction = maxArrivals > 0 ? arrivals / maxArrivals : 0.0;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: Row(
        children: [
          SizedBox(
            width: 30,
            child: Text('#$rank',
                style: Theme.of(context).textTheme.bodySmall),
          ),
          SizedBox(
            width: 180,
            child: Text(
              stationId,
              style: Theme.of(context).textTheme.bodyMedium,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          Expanded(
            child: Stack(
              children: [
                Container(
                  height: 24,
                  decoration: BoxDecoration(
                    color: Colors.grey.shade200,
                    borderRadius: BorderRadius.circular(6),
                  ),
                ),
                FractionallySizedBox(
                  widthFactor: fraction.clamp(0.0, 1.0),
                  child: Container(
                    height: 24,
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        colors: [
                          Colors.purple.shade300,
                          Colors.purple.shade500,
                        ],
                      ),
                      borderRadius: BorderRadius.circular(6),
                    ),
                  ),
                ),
              ],
            ),
          ),
          SizedBox(
            width: 60,
            child: Text(
              arrivals.toInt().toString(),
              style: Theme.of(context).textTheme.bodySmall,
              textAlign: TextAlign.right,
            ),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Privacy tab
// ---------------------------------------------------------------------------

class PrivacyTab extends StatelessWidget {
  final Map<String, dynamic>? summary;
  final Map<String, dynamic>? stats;

  const PrivacyTab({this.summary, this.stats, super.key});

  @override
  Widget build(BuildContext context) {
    final privacy = summary?['privacy'] as Map<String, dynamic>?;

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Text('Privacy Protections',
            style: Theme.of(context).textTheme.headlineSmall),
        const SizedBox(height: 16),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (privacy != null) ...[
                  _PrivacyRow(
                    label: 'DP Mechanism',
                    value: '${privacy['mechanism']}',
                    icon: Icons.lock,
                  ),
                  _PrivacyRow(
                    label: 'DP Model',
                    value: '${privacy['model']}',
                    icon: Icons.settings,
                  ),
                  _PrivacyRow(
                    label: 'Epsilon (per cell)',
                    value: '${privacy['epsilonPerCell']}',
                    icon: Icons.security,
                  ),
                  _PrivacyRow(
                    label: 'Sensitivity',
                    value: '${privacy['sensitivity']}',
                    icon: Icons.tune,
                  ),
                  _PrivacyRow(
                    label: 'k-Anonymity Threshold',
                    value: '≥ ${privacy['kAnonymityThreshold']} users',
                    icon: Icons.group,
                  ),
                  _PrivacyRow(
                    label: 'Noise Applied At',
                    value: '${privacy['noiseAppliedAt']}',
                    icon: Icons.cloud_upload,
                  ),
                ] else ...[
                  const Text('Privacy parameters not available'),
                ],
              ],
            ),
          ),
        ),
        const SizedBox(height: 24),
        Text('Data Pipeline Guarantees',
            style: Theme.of(context).textTheme.titleLarge),
        const SizedBox(height: 12),
        const Card(
          child: Column(
            children: [
              ListTile(
                leading: Icon(Icons.phone_android, color: Colors.green),
                title: Text('On-Device Aggregation'),
                subtitle: Text(
                    'Raw trajectories never leave the device. Only aggregate '
                    'counts are transmitted — never coordinates, never paths.'),
              ),
              Divider(height: 1),
              ListTile(
                leading: Icon(Icons.group, color: Colors.blue),
                title: Text('k-Anonymity Suppression'),
                subtitle: Text(
                    'Any O-D cell with fewer than 100 contributing devices is '
                    'dropped. Sparse cells that could re-identify a rider are '
                    'never released.'),
              ),
              Divider(height: 1),
              ListTile(
                leading: Icon(Icons.shield, color: Colors.orange),
                title: Text('Differential Privacy'),
                subtitle: Text(
                    'Laplace noise (ε = 0.44 per cell) is added to every '
                    'released count at the merge step. The noise prevents '
                    'any individual contribution from being inferred.'),
              ),
              Divider(height: 1),
              ListTile(
                leading: Icon(Icons.toggle_off, color: Colors.red),
                title: Text('Default-OFF Consent'),
                subtitle: Text(
                    'Data collection requires explicit, unbundled opt-in. '
                    'The core alarm works fully with sharing disabled. '
                    'One-tap withdrawal erases all on-device aggregate data.'),
              ),
              Divider(height: 1),
              ListTile(
                leading: Icon(Icons.block, color: Colors.purple),
                title: Text('No Trajectories, Ever'),
                subtitle: Text(
                    'The schema is coordinate-free by construction. Station '
                    'IDs come from a fixed catalogue — there is no field '
                    'for a lat/lng in any transmitted type.'),
              ),
            ],
          ),
        ),
        const SizedBox(height: 24),
        if (stats != null) ...[
          Text('Merge Engine Stats',
              style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 12),
          Card(
            child: Column(
              children: [
                ListTile(
                  title: const Text('Total O-D Cells (pre-suppression)'),
                  trailing: Text('${stats!['totalOdCells'] ?? 0}'),
                ),
                const Divider(height: 1),
                ListTile(
                  title: const Text('Total Catchment Cells'),
                  trailing: Text('${stats!['totalCatchmentCells'] ?? 0}'),
                ),
                const Divider(height: 1),
                ListTile(
                  title: const Text('Last Ingest'),
                  trailing: Text('${stats!['lastIngestAt'] ?? 'N/A'}'),
                ),
              ],
            ),
          ),
        ],
      ],
    );
  }
}

class _PrivacyRow extends StatelessWidget {
  final String label;
  final String value;
  final IconData icon;

  const _PrivacyRow({
    required this.label,
    required this.value,
    required this.icon,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        children: [
          Icon(icon, size: 20, color: Colors.grey.shade600),
          const SizedBox(width: 12),
          Text(label, style: Theme.of(context).textTheme.bodyMedium),
          const Spacer(),
          Text(
            value,
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  fontWeight: FontWeight.bold,
                ),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Error view
// ---------------------------------------------------------------------------

class _ErrorView extends StatelessWidget {
  final String error;
  final VoidCallback onRetry;

  const _ErrorView({required this.error, required this.onRetry});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.cloud_off, size: 64, color: Colors.grey),
            const SizedBox(height: 16),
            Text(
              'Failed to load data',
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: 8),
            Text(
              error,
              style: Theme.of(context).textTheme.bodySmall,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 24),
            FilledButton.icon(
              onPressed: onRetry,
              icon: const Icon(Icons.refresh),
              label: const Text('Retry'),
            ),
          ],
        ),
      ),
    );
  }
}
