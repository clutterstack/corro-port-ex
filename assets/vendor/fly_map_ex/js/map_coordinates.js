/**
 * Map coordinate transformation utilities for FlyMapEx real-time maps.
 *
 * Provides JavaScript implementations of coordinate transformations and
 * region lookups that mirror the Elixir backend functionality for
 * client-side marker rendering.
 */

/**
 * Convert WGS84 geographic coordinates to SVG pixel coordinates.
 *
 * This function performs the same linear transformation as the Elixir
 * backend (WorldMap.wgs84_to_svg/2) for client-side consistency.
 *
 * @param {number} lat - Latitude (-90 to 90)
 * @param {number} lng - Longitude (-180 to 180)
 * @param {Object} bbox - Bounding box {minX, minY, maxX, maxY}
 * @returns {Object} SVG coordinates {x, y}
 *
 * @example
 * // Equator and Prime Meridian -> center of map
 * wgs84ToSvg(0, 0, {minX: 0, minY: 0, maxX: 800, maxY: 400})
 * // => {x: 400.0, y: 200.0}
 *
 * @example
 * // San Francisco
 * wgs84ToSvg(37.7749, -122.4194, {minX: 0, minY: 0, maxX: 800, maxY: 400})
 * // => {x: 166.9, y: 131.1}
 */
export function wgs84ToSvg(lat, lng, bbox) {
  const {minX, minY, maxX, maxY} = bbox;
  const svgWidth = maxX - minX;
  const svgHeight = maxY - minY;

  // Geographic bounds (WGS84)
  const bounds = {
    minLng: -180,
    maxLng: 180,
    minLat: -90,
    maxLat: 90
  };

  // Calculate percentage position along each axis
  const xPercent = (lng - bounds.minLng) / (bounds.maxLng - bounds.minLng);
  // Note the inversion for y-axis since SVG's y increases downward
  const yPercent = 1 - (lat - bounds.minLat) / (bounds.maxLat - bounds.minLat);

  // Convert to pixel positions
  const x = xPercent * svgWidth + minX;
  const y = yPercent * svgHeight + minY;

  return {x, y};
}

/**
 * Default map bounding box matching Elixir backend configuration.
 * Maps to WorldMap @bbox constant.
 */
export const MAP_BBOX = {
  minX: 0,
  minY: 0,
  maxX: 800,
  maxY: 391
};

/**
 * Fly.io regions with their geographic coordinates.
 * Mirrors FlyMapEx.FlyRegions.fly_regions() data.
 */
export const FLY_REGIONS = {
  'ams': [52, 5],      // Amsterdam
  'iad': [39, -77],    // Ashburn
  'atl': [34, -84],    // Atlanta
  'bog': [5, -74],     // Bogotá
  'bos': [42, -71],    // Boston
  'otp': [45, 26],     // Bucharest
  'ord': [42, -88],    // Chicago
  'dfw': [33, -97],    // Dallas
  'den': [40, -105],   // Denver
  'eze': [-35, -59],   // Ezeiza
  'fra': [50, 9],      // Frankfurt
  'gdl': [21, -103],   // Guadalajara
  'hkg': [22, 114],    // Hong Kong
  'jnb': [-26, 28],    // Johannesburg
  'lhr': [51, 0],      // London
  'lax': [34, -118],   // Los Angeles
  'mad': [40, -4],     // Madrid
  'mia': [26, -80],    // Miami
  'yul': [45, -74],    // Montreal
  'bom': [19, 73],     // Mumbai
  'cdg': [49, 3],      // Paris
  'phx': [33, -112],   // Phoenix
  'qro': [21, -100],   // Querétaro
  'gig': [-23, -43],   // Rio de Janeiro
  'sjc': [37, -122],   // San Jose
  'scl': [-33, -71],   // Santiago
  'gru': [-23, -46],   // Sao Paulo
  'sea': [47, -122],   // Seattle
  'ewr': [41, -74],    // Secaucus
  'sin': [1, 104],     // Singapore
  'arn': [60, 18],     // Stockholm
  'syd': [-34, 151],   // Sydney
  'nrt': [36, 140],    // Tokyo
  'yyz': [44, -80],    // Toronto
  'waw': [52, 21]      // Warsaw
};

/**
 * Human-readable names for Fly.io regions.
 * Mirrors FlyMapEx.FlyRegions region names.
 */
export const FLY_REGION_NAMES = {
  'ams': 'Amsterdam',
  'iad': 'Ashburn',
  'atl': 'Atlanta',
  'bog': 'Bogotá',
  'bos': 'Boston',
  'otp': 'Bucharest',
  'ord': 'Chicago',
  'dfw': 'Dallas',
  'den': 'Denver',
  'eze': 'Ezeiza',
  'fra': 'Frankfurt',
  'gdl': 'Guadalajara',
  'hkg': 'Hong Kong',
  'jnb': 'Johannesburg',
  'lhr': 'London',
  'lax': 'Los Angeles',
  'mad': 'Madrid',
  'mia': 'Miami',
  'yul': 'Montreal',
  'bom': 'Mumbai',
  'cdg': 'Paris',
  'phx': 'Phoenix',
  'qro': 'Querétaro',
  'gig': 'Rio de Janeiro',
  'sjc': 'San Jose',
  'scl': 'Santiago',
  'gru': 'Sao Paulo',
  'sea': 'Seattle',
  'ewr': 'Secaucus',
  'sin': 'Singapore',
  'arn': 'Stockholm',
  'syd': 'Sydney',
  'nrt': 'Tokyo',
  'yyz': 'Toronto',
  'waw': 'Warsaw'
};

/**
 * Get coordinates for a region code.
 *
 * @param {string} region - Region code (e.g., "sjc", "fra")
 * @returns {Object|null} Coordinates {lat, lng} or null if not found
 *
 * @example
 * getRegionCoordinates("sjc") // => {lat: 37, lng: -122}
 * getRegionCoordinates("invalid") // => null
 */
export function getRegionCoordinates(region) {
  const coords = FLY_REGIONS[region];
  if (!coords) {
    return null;
  }

  const [lat, lng] = coords;
  return {lat, lng};
}

/**
 * Get human-readable name for a region code.
 *
 * @param {string} region - Region code (e.g., "sjc", "fra")
 * @returns {string|null} Region name or null if not found
 *
 * @example
 * getRegionName("sjc") // => "San Jose"
 * getRegionName("invalid") // => null
 */
export function getRegionName(region) {
  return FLY_REGION_NAMES[region] || null;
}

/**
 * Check if a region code is valid.
 *
 * @param {string} region - Region code to validate
 * @returns {boolean} True if region is known
 *
 * @example
 * isValidRegion("sjc") // => true
 * isValidRegion("invalid") // => false
 */
export function isValidRegion(region) {
  return Object.prototype.hasOwnProperty.call(FLY_REGIONS, region);
}

/**
 * Convert region code to SVG coordinates.
 *
 * Convenience function that combines region lookup and coordinate transformation.
 *
 * @param {string} region - Region code (e.g., "sjc", "fra")
 * @param {Object} bbox - Bounding box (optional, uses MAP_BBOX if not provided)
 * @returns {Object|null} SVG coordinates {x, y} or null if region not found
 *
 * @example
 * regionToSvg("sjc") // => {x: 166.9, y: 131.1}
 * regionToSvg("invalid") // => null
 */
export function regionToSvg(region, bbox = MAP_BBOX) {
  const coords = getRegionCoordinates(region);
  if (!coords) {
    return null;
  }

  return wgs84ToSvg(coords.lat, coords.lng, bbox);
}

/**
 * Convert marker coordinates to SVG coordinates.
 *
 * Handles multiple coordinate formats:
 * - Region codes: "sjc", "fra"
 * - Coordinate objects: {lat: 37, lng: -122}
 * - Coordinate maps: {lat: 37, lng: -122}
 * - Array tuples: [37, -122]
 *
 * @param {string|Object|Array} marker - Marker coordinate data
 * @param {Object} bbox - Bounding box (optional, uses MAP_BBOX if not provided)
 * @returns {Object|null} SVG coordinates {x, y} or null if invalid
 *
 * @example
 * markerToSvg("sjc") // => {x: 166.9, y: 131.1}
 * markerToSvg({lat: 37, lng: -122}) // => {x: 166.9, y: 131.1}
 * markerToSvg([37, -122]) // => {x: 166.9, y: 131.1}
 */
export function markerToSvg(marker, bbox = MAP_BBOX) {
  let lat, lng;

  if (typeof marker === 'string') {
    // Region code
    const coords = getRegionCoordinates(marker);
    if (!coords) {
      return null;
    }
    lat = coords.lat;
    lng = coords.lng;
  } else if (Array.isArray(marker) && marker.length === 2) {
    // Array tuple [lat, lng]
    [lat, lng] = marker;
  } else if (typeof marker === 'object' && marker !== null) {
    // Object with lat/lng properties
    lat = marker.lat || marker.latitude;
    lng = marker.lng || marker.longitude;

    if (lat === undefined || lng === undefined) {
      return null;
    }
  } else {
    return null;
  }

  // Validate coordinate ranges
  if (typeof lat !== 'number' || typeof lng !== 'number' ||
      lat < -90 || lat > 90 || lng < -180 || lng > 180) {
    return null;
  }

  return wgs84ToSvg(lat, lng, bbox);
}