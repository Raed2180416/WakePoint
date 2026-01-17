#!/usr/bin/env python3
"""
Critical Analysis of IMU Data for EKF Testing
"""

import csv
import os
from pathlib import Path
from dataclasses import dataclass
from typing import List, Tuple, Optional
import math

@dataclass
class RouteAnalysis:
    name: str
    path: str
    duration_seconds: float
    accel_samples: int
    gyro_samples: int
    gps_samples: int
    annotations: int
    gps_gaps_gt10s: List[Tuple[float, float, float]]  # (start, end, gap)
    gps_gaps_gt30s: List[Tuple[float, float, float]]
    gps_gaps_gt60s: List[Tuple[float, float, float]]
    start_coord: Tuple[float, float]
    end_coord: Tuple[float, float]
    avg_horizontal_accuracy: float
    station_dwell_times: List[Tuple[str, float, float]]  # (name, time, next_station_time)

def analyze_route(route_path: str) -> Optional[RouteAnalysis]:
    """Analyze a single route folder"""
    path = Path(route_path)
    name = path.name
    
    # Check required files exist
    loc_file = path / "Location.csv"
    accel_file = path / "Accelerometer.csv"
    gyro_file = path / "Gyroscope.csv"
    annot_file = path / "Annotation.csv"
    
    if not loc_file.exists():
        return None
    
    # Count samples
    accel_count = sum(1 for _ in open(accel_file)) - 1 if accel_file.exists() else 0
    gyro_count = sum(1 for _ in open(gyro_file)) - 1 if gyro_file.exists() else 0
    
    # Analyze location data
    with open(loc_file, 'r') as f:
        reader = csv.DictReader(f)
        loc_rows = list(reader)
    
    gps_count = len(loc_rows)
    if gps_count == 0:
        return None
    
    duration = float(loc_rows[-1]['seconds_elapsed'])
    
    # Find GPS gaps
    gaps_10 = []
    gaps_30 = []
    gaps_60 = []
    prev_time = 0
    total_accuracy = 0
    
    for row in loc_rows:
        elapsed = float(row['seconds_elapsed'])
        accuracy = float(row['horizontalAccuracy'])
        total_accuracy += accuracy
        
        if prev_time > 0:
            gap = elapsed - prev_time
            if gap > 10:
                gaps_10.append((prev_time, elapsed, gap))
            if gap > 30:
                gaps_30.append((prev_time, elapsed, gap))
            if gap > 60:
                gaps_60.append((prev_time, elapsed, gap))
        prev_time = elapsed
    
    avg_accuracy = total_accuracy / gps_count
    
    start_coord = (float(loc_rows[0]['latitude']), float(loc_rows[0]['longitude']))
    end_coord = (float(loc_rows[-1]['latitude']), float(loc_rows[-1]['longitude']))
    
    # Analyze annotations
    annotations = []
    station_dwells = []
    if annot_file.exists():
        with open(annot_file, 'r') as f:
            reader = csv.DictReader(f)
            annotations = list(reader)
        
        for i, ann in enumerate(annotations):
            name_text = ann.get('text', '')
            time = float(ann.get('seconds_elapsed', 0))
            next_time = float(annotations[i+1]['seconds_elapsed']) if i < len(annotations)-1 else duration
            station_dwells.append((name_text, time, next_time))
    
    return RouteAnalysis(
        name=name,
        path=route_path,
        duration_seconds=duration,
        accel_samples=accel_count,
        gyro_samples=gyro_count,
        gps_samples=gps_count,
        annotations=len(annotations),
        gps_gaps_gt10s=gaps_10,
        gps_gaps_gt30s=gaps_30,
        gps_gaps_gt60s=gaps_60,
        start_coord=start_coord,
        end_coord=end_coord,
        avg_horizontal_accuracy=avg_accuracy,
        station_dwell_times=station_dwells
    )

def print_analysis(analysis: RouteAnalysis):
    """Pretty print route analysis"""
    print(f"\n{'='*80}")
    print(f"ROUTE: {analysis.name}")
    print(f"{'='*80}")
    print(f"Duration: {analysis.duration_seconds/60:.1f} minutes ({analysis.duration_seconds:.0f}s)")
    print(f"IMU Samples: Accel={analysis.accel_samples:,}, Gyro={analysis.gyro_samples:,}")
    print(f"GPS Points: {analysis.gps_samples:,} (avg interval: {analysis.duration_seconds/analysis.gps_samples:.2f}s)")
    print(f"Avg Horizontal Accuracy: {analysis.avg_horizontal_accuracy:.1f}m")
    print(f"Annotations: {analysis.annotations} stations")
    print(f"Start: ({analysis.start_coord[0]:.6f}, {analysis.start_coord[1]:.6f})")
    print(f"End:   ({analysis.end_coord[0]:.6f}, {analysis.end_coord[1]:.6f})")
    
    print(f"\nGPS GAPS:")
    print(f"  > 10s: {len(analysis.gps_gaps_gt10s)} gaps")
    print(f"  > 30s: {len(analysis.gps_gaps_gt30s)} gaps")
    print(f"  > 60s: {len(analysis.gps_gaps_gt60s)} gaps")
    
    if analysis.gps_gaps_gt60s:
        print(f"\n  Major gaps (>60s):")
        for start, end, gap in analysis.gps_gaps_gt60s[:5]:
            print(f"    {start:.0f}s - {end:.0f}s: {gap:.0f}s gap")
    
    if analysis.station_dwell_times:
        print(f"\nSTATION TIMING:")
        for i, (station, time, next_time) in enumerate(analysis.station_dwell_times):
            inter_station = next_time - time
            print(f"  {i+1:2d}. {station:25s} @ {time:7.1f}s (next in {inter_station:5.0f}s)")

def analyze_imu_for_zupt(route_path: str, station_time: float, window_seconds: float = 30):
    """Analyze IMU data around a station stop for ZUPT detection potential"""
    path = Path(route_path)
    accel_file = path / "Accelerometer.csv"
    
    if not accel_file.exists():
        return None
    
    with open(accel_file, 'r') as f:
        reader = csv.DictReader(f)
        # Filter to window around station
        samples = []
        for row in reader:
            elapsed = float(row['seconds_elapsed'])
            if station_time - window_seconds <= elapsed <= station_time + window_seconds:
                x = float(row['x'])
                y = float(row['y'])
                z = float(row['z'])
                magnitude = math.sqrt(x*x + y*y + z*z)
                samples.append((elapsed, magnitude))
    
    if not samples:
        return None
    
    # Look for low-variance periods (stationary)
    window_size = 100  # 1 second at 100Hz
    variances = []
    for i in range(len(samples) - window_size):
        window_mags = [s[1] for s in samples[i:i+window_size]]
        mean = sum(window_mags) / len(window_mags)
        variance = sum((m - mean)**2 for m in window_mags) / len(window_mags)
        variances.append((samples[i][0], variance))
    
    # Find minimum variance periods (likely stationary)
    min_var = min(v[1] for v in variances) if variances else 0
    return min_var


if __name__ == "__main__":
    base_path = Path(r"d:\WakePoint\GeoWake IMU  (File responses)")
    
    print("\n" + "="*80)
    print("CRITICAL ANALYSIS OF IMU DATA FOR EKF TESTING")
    print("="*80)
    
    # Analyze Metro routes
    metro_path = base_path / "Metro_Log_File"
    print(f"\n\n{'#'*80}")
    print("# METRO ROUTES")
    print(f"{'#'*80}")
    
    for folder in metro_path.iterdir():
        if folder.is_dir():
            analysis = analyze_route(str(folder))
            if analysis:
                print_analysis(analysis)
    
    # Analyze non-metro routes
    upload_path = base_path / "Upload Log File (Zipped CSV) (File responses)"
    print(f"\n\n{'#'*80}")
    print("# NON-METRO ROUTES (with annotations only)")
    print(f"{'#'*80}")
    
    for folder in upload_path.iterdir():
        if folder.is_dir():
            analysis = analyze_route(str(folder))
            if analysis and analysis.annotations > 0:
                print_analysis(analysis)
    
    print(f"\n\n{'#'*80}")
    print("# NON-METRO ROUTES (without annotations - summary)")
    print(f"{'#'*80}")
    
    non_annotated = []
    for folder in upload_path.iterdir():
        if folder.is_dir():
            analysis = analyze_route(str(folder))
            if analysis and analysis.annotations == 0:
                non_annotated.append(analysis)
    
    if non_annotated:
        print(f"\n{'Name':<50} {'Dur(min)':<10} {'GPS':<8} {'Accel':<10}")
        print("-"*80)
        for a in sorted(non_annotated, key=lambda x: x.duration_seconds, reverse=True):
            print(f"{a.name[:49]:<50} {a.duration_seconds/60:<10.1f} {a.gps_samples:<8} {a.accel_samples:<10,}")
