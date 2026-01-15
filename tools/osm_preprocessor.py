#!/usr/bin/env python3
"""
OSM Preprocessor for WakePoint Deviation Dashboard

Converts OpenStreetMap PBF files into a compact binary format optimized
for the Flutter deviation simulation dashboard.

Output format (.wkp binary):
  Header (16 bytes):
    - Magic: "WKP1" (4 bytes)
    - Version: uint16
    - Node count: uint32
    - Edge count: uint32
    - Reserved: uint16
  
  Nodes section:
    - Each node: lat (float32), lon (float32), id (uint64) = 16 bytes
  
  Edges section:
    - Each edge: from_idx (uint32), to_idx (uint32), distance_m (float32),
                 road_type (uint8), oneway (uint8), padding (uint16) = 16 bytes

Usage:
    python osm_preprocessor.py <input.osm.pbf> <output.wkp> [--bbox=lat1,lon1,lat2,lon2]

Example:
    python osm_preprocessor.py bengaluru.osm.pbf bengaluru.wkp --bbox=12.85,77.45,13.10,77.75
"""

import argparse
import struct
import sys
from collections import defaultdict
from dataclasses import dataclass
from pathlib import Path
from typing import Dict, List, Optional, Set, Tuple

try:
    import osmium
except ImportError:
    print("Error: osmium not found. Install with: pip install osmium")
    sys.exit(1)

# Road types we care about (routable roads)
ROAD_TYPES = {
    'motorway': 1,
    'motorway_link': 2,
    'trunk': 3,
    'trunk_link': 4,
    'primary': 5,
    'primary_link': 6,
    'secondary': 7,
    'secondary_link': 8,
    'tertiary': 9,
    'tertiary_link': 10,
    'residential': 11,
    'living_street': 12,
    'unclassified': 13,
    'service': 14,
    'road': 15,
}

# Default speeds for road types (km/h) - used for travel time estimation
DEFAULT_SPEEDS = {
    'motorway': 100,
    'motorway_link': 60,
    'trunk': 80,
    'trunk_link': 50,
    'primary': 60,
    'primary_link': 40,
    'secondary': 50,
    'secondary_link': 35,
    'tertiary': 40,
    'tertiary_link': 30,
    'residential': 30,
    'living_street': 20,
    'unclassified': 30,
    'service': 20,
    'road': 30,
}


@dataclass
class Node:
    id: int
    lat: float
    lon: float


@dataclass
class Edge:
    from_id: int
    to_id: int
    distance_m: float
    road_type: int
    oneway: bool


class WayHandler(osmium.SimpleHandler):
    """First pass: collect all node IDs referenced by roads."""
    
    def __init__(self, bbox: Optional[Tuple[float, float, float, float]] = None):
        super().__init__()
        self.needed_nodes: Set[int] = set()
        self.bbox = bbox  # (min_lat, min_lon, max_lat, max_lon)
        self.way_count = 0
    
    def way(self, w):
        highway = w.tags.get('highway')
        if highway not in ROAD_TYPES:
            return
        
        # Collect all node IDs from this way
        node_ids = [n.ref for n in w.nodes]
        self.needed_nodes.update(node_ids)
        self.way_count += 1


class NodeHandler(osmium.SimpleHandler):
    """Second pass: collect coordinates for needed nodes."""
    
    def __init__(self, needed_nodes: Set[int], bbox: Optional[Tuple[float, float, float, float]] = None):
        super().__init__()
        self.needed_nodes = needed_nodes
        self.nodes: Dict[int, Node] = {}
        self.bbox = bbox
    
    def node(self, n):
        if n.id not in self.needed_nodes:
            return
        
        lat, lon = n.location.lat, n.location.lon
        
        # Apply bbox filter if specified
        if self.bbox:
            min_lat, min_lon, max_lat, max_lon = self.bbox
            if not (min_lat <= lat <= max_lat and min_lon <= lon <= max_lon):
                return
        
        self.nodes[n.id] = Node(id=n.id, lat=lat, lon=lon)


class EdgeHandler(osmium.SimpleHandler):
    """Third pass: build edges from ways."""
    
    def __init__(self, nodes: Dict[int, Node]):
        super().__init__()
        self.nodes = nodes
        self.edges: List[Edge] = []
    
    def way(self, w):
        highway = w.tags.get('highway')
        if highway not in ROAD_TYPES:
            return
        
        road_type = ROAD_TYPES[highway]
        
        # Check if oneway
        oneway_tag = w.tags.get('oneway', 'no')
        oneway = oneway_tag in ('yes', '1', 'true')
        
        # Motorways are typically oneway
        if highway in ('motorway', 'motorway_link') and oneway_tag != 'no':
            oneway = True
        
        # Get node IDs that exist in our filtered set
        node_ids = [n.ref for n in w.nodes if n.ref in self.nodes]
        
        if len(node_ids) < 2:
            return
        
        # Create edges between consecutive nodes
        for i in range(len(node_ids) - 1):
            from_id, to_id = node_ids[i], node_ids[i + 1]
            from_node = self.nodes[from_id]
            to_node = self.nodes[to_id]
            
            distance = haversine_distance(
                from_node.lat, from_node.lon,
                to_node.lat, to_node.lon
            )
            
            # Forward edge
            self.edges.append(Edge(
                from_id=from_id,
                to_id=to_id,
                distance_m=distance,
                road_type=road_type,
                oneway=oneway,
            ))
            
            # Reverse edge (if not oneway)
            if not oneway:
                self.edges.append(Edge(
                    from_id=to_id,
                    to_id=from_id,
                    distance_m=distance,
                    road_type=road_type,
                    oneway=False,
                ))


def haversine_distance(lat1: float, lon1: float, lat2: float, lon2: float) -> float:
    """Calculate distance between two points in meters."""
    import math
    
    R = 6371000  # Earth radius in meters
    
    phi1 = math.radians(lat1)
    phi2 = math.radians(lat2)
    delta_phi = math.radians(lat2 - lat1)
    delta_lambda = math.radians(lon2 - lon1)
    
    a = (math.sin(delta_phi / 2) ** 2 +
         math.cos(phi1) * math.cos(phi2) * math.sin(delta_lambda / 2) ** 2)
    c = 2 * math.atan2(math.sqrt(a), math.sqrt(1 - a))
    
    return R * c


def _point_in_bbox(lat: float, lon: float, bbox: Tuple[float, float, float, float]) -> bool:
    min_lat, min_lon, max_lat, max_lon = bbox
    return (min_lat <= lat <= max_lat) and (min_lon <= lon <= max_lon)


class BboxNodeCollector(osmium.SimpleHandler):
    """Optimized bbox mode: collect only nodes inside bbox."""

    def __init__(self, bbox: Tuple[float, float, float, float]):
        super().__init__()
        self.bbox = bbox
        self.nodes: Dict[int, Node] = {}
        self.seen = 0

    def node(self, n):
        self.seen += 1
        if not n.location or not n.location.valid():
            return
        lat, lon = n.location.lat, n.location.lon
        if not _point_in_bbox(lat, lon, self.bbox):
            return
        self.nodes[n.id] = Node(id=n.id, lat=lat, lon=lon)


class BboxEdgeHandler(osmium.SimpleHandler):
    """Optimized bbox mode: build edges using only nodes inside bbox."""

    def __init__(self, nodes: Dict[int, Node]):
        super().__init__()
        self.nodes = nodes
        self.edges: List[Edge] = []
        self.way_count = 0

    def way(self, w):
        highway = w.tags.get('highway')
        if highway not in ROAD_TYPES:
            return

        self.way_count += 1
        road_type = ROAD_TYPES[highway]

        oneway_tag = w.tags.get('oneway', 'no')
        oneway = oneway_tag in ('yes', '1', 'true')
        if highway in ('motorway', 'motorway_link') and oneway_tag != 'no':
            oneway = True

        node_ids = [n.ref for n in w.nodes if n.ref in self.nodes]
        if len(node_ids) < 2:
            return

        for i in range(len(node_ids) - 1):
            from_id, to_id = node_ids[i], node_ids[i + 1]
            from_node = self.nodes[from_id]
            to_node = self.nodes[to_id]

            distance = haversine_distance(
                from_node.lat, from_node.lon,
                to_node.lat, to_node.lon
            )

            self.edges.append(Edge(
                from_id=from_id,
                to_id=to_id,
                distance_m=distance,
                road_type=road_type,
                oneway=oneway,
            ))

            if not oneway:
                self.edges.append(Edge(
                    from_id=to_id,
                    to_id=from_id,
                    distance_m=distance,
                    road_type=road_type,
                    oneway=False,
                ))


class BboxGraphBuilder(osmium.SimpleHandler):
    """Single-pass bbox build: keep bbox nodes and build edges as ways stream in.

    This avoids reading the input PBF twice, which is a major speedup for large regional extracts.
    """

    def __init__(self, bbox: Tuple[float, float, float, float]):
        super().__init__()
        self.bbox = bbox
        self.nodes: Dict[int, Node] = {}
        self.edges: List[Edge] = []

        self.total_nodes_seen = 0
        self.total_nodes_kept = 0
        self.routable_ways_seen = 0

    def node(self, n):
        self.total_nodes_seen += 1
        if self.total_nodes_seen % 5_000_000 == 0:
            print(
                f"  ... scanned {self.total_nodes_seen:,} nodes, kept {self.total_nodes_kept:,}",
                flush=True,
            )

        if not n.location or not n.location.valid():
            return

        lat, lon = n.location.lat, n.location.lon
        if not _point_in_bbox(lat, lon, self.bbox):
            return

        self.nodes[n.id] = Node(id=n.id, lat=lat, lon=lon)
        self.total_nodes_kept += 1

    def way(self, w):
        highway = w.tags.get('highway')
        if highway not in ROAD_TYPES:
            return

        self.routable_ways_seen += 1
        if self.routable_ways_seen % 50_000 == 0:
            print(
                f"  ... scanned {self.routable_ways_seen:,} routable ways, edges {len(self.edges):,}",
                flush=True,
            )

        road_type = ROAD_TYPES[highway]

        oneway_tag = w.tags.get('oneway', 'no')
        oneway = oneway_tag in ('yes', '1', 'true')
        if highway in ('motorway', 'motorway_link') and oneway_tag != 'no':
            oneway = True

        node_ids = [n.ref for n in w.nodes if n.ref in self.nodes]
        if len(node_ids) < 2:
            return

        for i in range(len(node_ids) - 1):
            from_id, to_id = node_ids[i], node_ids[i + 1]
            from_node = self.nodes[from_id]
            to_node = self.nodes[to_id]

            distance = haversine_distance(
                from_node.lat, from_node.lon,
                to_node.lat, to_node.lon
            )

            self.edges.append(Edge(
                from_id=from_id,
                to_id=to_id,
                distance_m=distance,
                road_type=road_type,
                oneway=oneway,
            ))

            if not oneway:
                self.edges.append(Edge(
                    from_id=to_id,
                    to_id=from_id,
                    distance_m=distance,
                    road_type=road_type,
                    oneway=False,
                ))


def write_binary(output_path: Path, nodes: Dict[int, Node], edges: List[Edge]):
    """Write the graph to binary format."""
    
    # Create node index mapping (node_id -> index)
    node_list = list(nodes.values())
    node_id_to_idx = {n.id: i for i, n in enumerate(node_list)}
    
    # Filter edges to only those with valid node indices
    valid_edges = [
        e for e in edges
        if e.from_id in node_id_to_idx and e.to_id in node_id_to_idx
    ]
    
    with open(output_path, 'wb') as f:
        # Write header
        f.write(b'WKP1')  # Magic
        f.write(struct.pack('<H', 1))  # Version
        f.write(struct.pack('<I', len(node_list)))  # Node count
        f.write(struct.pack('<I', len(valid_edges)))  # Edge count
        f.write(struct.pack('<H', 0))  # Reserved
        
        # Write nodes
        for node in node_list:
            f.write(struct.pack('<ffQ', node.lat, node.lon, node.id))
        
        # Write edges
        for edge in valid_edges:
            from_idx = node_id_to_idx[edge.from_id]
            to_idx = node_id_to_idx[edge.to_id]
            f.write(struct.pack(
                '<IIfBBH',
                from_idx,
                to_idx,
                edge.distance_m,
                edge.road_type,
                1 if edge.oneway else 0,
                0,  # padding
            ))
    
    return len(node_list), len(valid_edges)


def process_osm(input_path: Path, output_path: Path, bbox: Optional[Tuple[float, float, float, float]] = None):
    """Process OSM file and write binary output."""
    
    print(f"Processing: {input_path}")
    print(f"Output: {output_path}")
    if bbox:
        print(f"Bounding box: {bbox}")
    
    if bbox:
        print("\nUsing bbox-optimized pipeline (single-pass; best for city-only builds)")

        print("\nPass 1: Scanning nodes+ways (single pass)...")
        builder = BboxGraphBuilder(bbox)
        builder.apply_file(str(input_path))
        print(f"  Kept {len(builder.nodes)} nodes within bounds")
        print(f"  Scanned {builder.routable_ways_seen} routable ways")
        print(f"  Created {len(builder.edges)} edges")

        print("\nWriting binary file...")
        node_count, edge_count = write_binary(output_path, builder.nodes, builder.edges)
    else:
        # Full pipeline (keeps all routable ways and all referenced nodes)
        print("\nPass 1: Scanning ways...")
        way_handler = WayHandler(bbox)
        way_handler.apply_file(str(input_path))
        print(f"  Found {way_handler.way_count} roads referencing {len(way_handler.needed_nodes)} nodes")

        print("\nPass 2: Loading nodes...")
        node_handler = NodeHandler(way_handler.needed_nodes, bbox)
        node_handler.apply_file(str(input_path), locations=True)
        print(f"  Loaded {len(node_handler.nodes)} nodes within bounds")

        print("\nPass 3: Building edges...")
        edge_handler = EdgeHandler(node_handler.nodes)
        edge_handler.apply_file(str(input_path))
        print(f"  Created {len(edge_handler.edges)} edges")

        print("\nWriting binary file...")
        node_count, edge_count = write_binary(output_path, node_handler.nodes, edge_handler.edges)
    
    file_size = output_path.stat().st_size
    print(f"\nDone!")
    print(f"  Nodes: {node_count:,}")
    print(f"  Edges: {edge_count:,}")
    print(f"  File size: {file_size / 1024 / 1024:.2f} MB")


def parse_bbox(bbox_str: str) -> Tuple[float, float, float, float]:
    """Parse bbox string 'lat1,lon1,lat2,lon2' to tuple."""
    parts = [float(x.strip()) for x in bbox_str.split(',')]
    if len(parts) != 4:
        raise ValueError("Bounding box must have 4 values: lat1,lon1,lat2,lon2")
    return tuple(parts)


def main():
    parser = argparse.ArgumentParser(
        description='Convert OSM PBF to WakePoint binary format',
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=__doc__,
    )
    parser.add_argument('input', type=Path, help='Input OSM PBF file')
    parser.add_argument('output', type=Path, help='Output .wkp file')
    parser.add_argument('--bbox', type=str, help='Bounding box: lat1,lon1,lat2,lon2')
    
    args = parser.parse_args()
    
    if not args.input.exists():
        print(f"Error: Input file not found: {args.input}")
        sys.exit(1)
    
    bbox = None
    if args.bbox:
        try:
            bbox = parse_bbox(args.bbox)
        except ValueError as e:
            print(f"Error parsing bbox: {e}")
            sys.exit(1)
    
    process_osm(args.input, args.output, bbox)


if __name__ == '__main__':
    main()
