#!/usr/bin/env python3
"""
Convert Natural Earth 110m GeoJSON country boundaries to GDScript polygon data.

Reads ne_110m_admin_0_countries.geojson and outputs scripts/country_data.gd
with accurate normalized polygon coordinates for use in the map generator.

Usage:
    python3 tools/convert_countries.py
"""

import json
import math
import os
import sys
from shapely.geometry import shape, MultiPolygon, Polygon
from shapely.ops import unary_union

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
PROJECT_DIR = os.path.dirname(SCRIPT_DIR)
GEOJSON_PATH = "/tmp/ne_110m_countries.geojson"
OUTPUT_PATH = os.path.join(PROJECT_DIR, "scripts", "country_data.gd")

# Target maps and their source countries
MAP_CONFIGS = {
    "usa": {
        "name": "United States",
        "countries": ["United States of America"],
        "continental_only": True,  # exclude Alaska, Hawaii — continental US only
        "min_polygon_area_deg2": 2.0,  # filter tiny islands
    },
    "canada": {
        "name": "Canada",
        "countries": ["Canada"],
        "min_polygon_area_deg2": 5.0,  # filter small arctic islands
    },
    "europe": {
        "name": "Europe",
        "countries": [
            "Portugal", "Spain", "France", "Belgium", "Netherlands", "Luxembourg",
            "Germany", "Switzerland", "Austria", "Italy", "Slovenia", "Croatia",
            "Bosnia and Herz.", "Serbia", "Montenegro", "Kosovo", "North Macedonia",
            "Albania", "Greece", "Bulgaria", "Romania", "Hungary", "Slovakia",
            "Czechia", "Poland", "Denmark", "Norway", "Sweden", "Finland",
            "Estonia", "Latvia", "Lithuania", "United Kingdom", "Ireland",
            "Iceland",
        ],
        "min_polygon_area_deg2": 0.5,
    },
}

# RDP simplification tolerance in normalized space (~2px at 800px)
RDP_TOLERANCE = 0.003
# Max vertices per polygon ring before forcing simplification
MAX_VERTICES = 400
# Padding fraction on each side when normalizing to 0-1
PADDING = 0.05


def load_geojson():
    with open(GEOJSON_PATH) as f:
        return json.load(f)


def get_country_polygons(geojson_data, country_name):
    """Extract all polygons for a given country name."""
    for feature in geojson_data["features"]:
        if feature["properties"]["NAME"] == country_name:
            geom = shape(feature["geometry"])
            if isinstance(geom, Polygon):
                return [geom]
            elif isinstance(geom, MultiPolygon):
                return list(geom.geoms)
    return []


def equirectangular_project(lon, lat, center_lat):
    """Simple equirectangular projection with latitude correction."""
    x = lon * math.cos(math.radians(center_lat))
    y = -lat  # flip Y so north is up (lower y value)
    return x, y


def project_polygons(polygons, center_lat):
    """Project all polygon coordinates using equirectangular projection."""
    projected = []
    for poly in polygons:
        coords = list(poly.exterior.coords)
        proj_coords = [equirectangular_project(lon, lat, center_lat) for lon, lat in coords]
        projected.append(proj_coords)
    return projected


def compute_bounds(all_coords):
    """Compute bounding box of all coordinate lists."""
    min_x = min_y = float('inf')
    max_x = max_y = float('-inf')
    for coords in all_coords:
        for x, y in coords:
            min_x = min(min_x, x)
            max_x = max(max_x, x)
            min_y = min(min_y, y)
            max_y = max(max_y, y)
    return min_x, min_y, max_x, max_y


def normalize_coords(coords, min_x, min_y, range_x, range_y, padding):
    """Normalize coordinates to 0-1 range with padding."""
    normalized = []
    usable = 1.0 - 2.0 * padding
    for x, y in coords:
        nx = padding + ((x - min_x) / range_x) * usable
        ny = padding + ((y - min_y) / range_y) * usable
        normalized.append((round(nx, 4), round(ny, 4)))
    return normalized


def rdp_simplify(coords, tolerance):
    """Ramer-Douglas-Peucker simplification."""
    if len(coords) <= 3:
        return coords

    poly = Polygon(coords)
    simplified = poly.simplify(tolerance, preserve_topology=True)
    return list(simplified.exterior.coords)


def compute_centroid(coords):
    """Compute the centroid of a polygon."""
    poly = Polygon(coords)
    c = poly.centroid
    return (round(c.x, 4), round(c.y, 4))


def polygon_area(coords):
    """Compute the area of a polygon using the shoelace formula."""
    n = len(coords)
    area = 0.0
    for i in range(n):
        j = (i + 1) % n
        area += coords[i][0] * coords[j][1]
        area -= coords[j][0] * coords[i][1]
    return abs(area) / 2.0


def process_country(geojson_data, map_id, config):
    """Process a single map entry (may merge multiple countries for Europe)."""
    all_polygons = []

    for country_name in config["countries"]:
        polys = get_country_polygons(geojson_data, country_name)
        if not polys:
            print(f"  WARNING: Country '{country_name}' not found in GeoJSON", file=sys.stderr)
            continue
        all_polygons.extend(polys)

    if not all_polygons:
        print(f"  ERROR: No polygons found for {map_id}", file=sys.stderr)
        return None

    # Filter by minimum area (in degrees squared)
    min_area = config.get("min_polygon_area_deg2", 1.0)
    filtered = [p for p in all_polygons if p.area >= min_area]

    if not filtered:
        # If all were filtered, keep the largest one
        filtered = [max(all_polygons, key=lambda p: p.area)]

    print(f"  {map_id}: {len(all_polygons)} raw polygons -> {len(filtered)} after area filter (min={min_area} deg²)")

    # For USA: exclude Alaska (continental US only for better map fill)
    if map_id == "usa" and config.get("continental_only"):
        continental = []
        excluded = 0
        for poly in filtered:
            c = poly.centroid
            # Alaska: longitude roughly west of -130, Hawaii: lat < 25
            if c.x < -130 or c.y < 25:
                excluded += 1
            else:
                continental.append(poly)
        if excluded > 0:
            print(f"    Excluded {excluded} non-continental polygons (Alaska/Hawaii)")
        filtered = continental

    # Compute center latitude for projection
    all_lats = []
    for poly in filtered:
        for lon, lat in poly.exterior.coords:
            all_lats.append(lat)
    center_lat = sum(all_lats) / len(all_lats)

    # Project
    projected = project_polygons(filtered, center_lat)

    # Compute bounds
    min_x, min_y, max_x, max_y = compute_bounds(projected)
    range_x = max_x - min_x
    range_y = max_y - min_y

    # Make aspect ratio fit nicely (pad the shorter dimension to match 800x600 = 4:3)
    target_ratio = 800.0 / 600.0  # 4:3
    current_ratio = range_x / range_y if range_y > 0 else 1.0

    if current_ratio > target_ratio:
        # Too wide, pad height
        new_range_y = range_x / target_ratio
        pad = (new_range_y - range_y) / 2.0
        min_y -= pad
        range_y = new_range_y
    else:
        # Too tall, pad width
        new_range_x = range_y * target_ratio
        pad = (new_range_x - range_x) / 2.0
        min_x -= pad
        range_x = new_range_x

    # Normalize all polygons
    normalized_polys = []
    for coords in projected:
        normed = normalize_coords(coords, min_x, min_y, range_x, range_y, PADDING)
        # Simplify if too many vertices
        if len(normed) > MAX_VERTICES:
            normed = rdp_simplify(normed, RDP_TOLERANCE)
        # Remove closing duplicate vertex if present
        if len(normed) > 1 and normed[0] == normed[-1]:
            normed = normed[:-1]
        if len(normed) >= 3:
            normalized_polys.append(normed)

    # Find the largest polygon (main landmass)
    areas = [polygon_area(p) for p in normalized_polys]
    main_idx = areas.index(max(areas))
    centroid = compute_centroid(normalized_polys[main_idx])

    total_verts = sum(len(p) for p in normalized_polys)
    print(f"    {len(normalized_polys)} final polygons, {total_verts} total vertices, centroid={centroid}")

    return {
        "name": config["name"],
        "polygons": normalized_polys,
        "centroid": centroid,
    }


def process_usa_split(continental_polys, alaska_polys):
    """Process USA with continental and Alaska as separate polygon groups, all normalized together."""
    all_polys = continental_polys + alaska_polys

    # Compute center latitude from all polygons
    all_lats = []
    for poly in all_polys:
        for lon, lat in poly.exterior.coords:
            all_lats.append(lat)
    center_lat = sum(all_lats) / len(all_lats)

    # Project all together
    projected = project_polygons(all_polys, center_lat)

    # Compute bounds from all
    min_x, min_y, max_x, max_y = compute_bounds(projected)
    range_x = max_x - min_x
    range_y = max_y - min_y

    # Aspect ratio adjustment (4:3)
    target_ratio = 800.0 / 600.0
    current_ratio = range_x / range_y if range_y > 0 else 1.0

    if current_ratio > target_ratio:
        new_range_y = range_x / target_ratio
        pad = (new_range_y - range_y) / 2.0
        min_y -= pad
        range_y = new_range_y
    else:
        new_range_x = range_y * target_ratio
        pad = (new_range_x - range_x) / 2.0
        min_x -= pad
        range_x = new_range_x

    # Normalize all polygons
    normalized_polys = []
    for coords in projected:
        normed = normalize_coords(coords, min_x, min_y, range_x, range_y, PADDING)
        if len(normed) > MAX_VERTICES:
            normed = rdp_simplify(normed, RDP_TOLERANCE)
        if len(normed) > 1 and normed[0] == normed[-1]:
            normed = normed[:-1]
        if len(normed) >= 3:
            normalized_polys.append(normed)

    # Find the continental US polygon (largest by area)
    areas = [polygon_area(p) for p in normalized_polys]
    main_idx = areas.index(max(areas))
    centroid = compute_centroid(normalized_polys[main_idx])

    total_verts = sum(len(p) for p in normalized_polys)
    print(f"    {len(normalized_polys)} final polygons (continental + Alaska), {total_verts} total vertices, centroid={centroid}")

    return {
        "name": "United States",
        "polygons": normalized_polys,
        "centroid": centroid,
    }


def format_vector2_array(coords, indent="\t\t"):
    """Format coordinate list as GDScript Array[Vector2] with line wrapping."""
    lines = []
    line_items = []
    for x, y in coords:
        item = f"Vector2({x}, {y})"
        line_items.append(item)
        # Wrap every 4 items
        if len(line_items) >= 4:
            lines.append(f"{indent}{', '.join(line_items)},")
            line_items = []
    if line_items:
        lines.append(f"{indent}{', '.join(line_items)},")
    return "\n".join(lines)


def generate_gdscript(results):
    """Generate the country_data.gd file content."""
    lines = [
        'class_name CountryData',
        'extends RefCounted',
        '',
        '## Accurate country boundary data derived from Natural Earth 110m dataset.',
        '## Generated by tools/convert_countries.py — do not edit manually.',
        '',
    ]

    # Generate polygon constants for each country
    for map_id, data in results.items():
        lines.append(f'# --- {data["name"]} ---')
        for poly_idx, poly_coords in enumerate(data["polygons"]):
            const_name = f'{map_id.upper()}_POLY_{poly_idx}'
            lines.append(f'const {const_name}: Array[Vector2] = [')
            lines.append(format_vector2_array(poly_coords))
            lines.append(']')
            lines.append('')

    # Generate the COUNTRIES dictionary
    lines.append('')
    lines.append('const COUNTRIES: Dictionary = {')

    for map_id, data in results.items():
        lines.append(f'\t"{map_id}": {{')
        lines.append(f'\t\t"name": "{data["name"]}",')

        # Polygons array referencing the const arrays
        poly_refs = [f'{map_id.upper()}_POLY_{i}' for i in range(len(data["polygons"]))]
        if len(poly_refs) == 1:
            lines.append(f'\t\t"polygons": [{poly_refs[0]}],')
        else:
            lines.append(f'\t\t"polygons": [')
            for ref in poly_refs:
                lines.append(f'\t\t\t{ref},')
            lines.append(f'\t\t],')

        cx, cy = data["centroid"]
        lines.append(f'\t\t"centroid": Vector2({cx}, {cy}),')
        lines.append('\t},')

    lines.append('}')
    lines.append('')

    # MAP_IDS array
    ids_str = ', '.join(f'"{mid}"' for mid in results.keys())
    lines.append(f'const MAP_IDS: Array[String] = [{ids_str}]')
    lines.append('')

    return '\n'.join(lines)


def main():
    print("Loading GeoJSON data...")
    geojson_data = load_geojson()
    print(f"Loaded {len(geojson_data['features'])} features")

    results = {}
    for map_id, config in MAP_CONFIGS.items():
        print(f"\nProcessing: {config['name']}")
        result = process_country(geojson_data, map_id, config)
        if result:
            results[map_id] = result

    print(f"\nGenerating GDScript output...")
    gdscript = generate_gdscript(results)

    with open(OUTPUT_PATH, 'w') as f:
        f.write(gdscript)

    print(f"Written to: {OUTPUT_PATH}")
    print(f"File size: {len(gdscript)} bytes")


if __name__ == "__main__":
    main()
