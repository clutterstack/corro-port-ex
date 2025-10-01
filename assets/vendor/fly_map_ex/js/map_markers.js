/**
 * Client-side marker rendering utilities for FlyMapEx real-time maps.
 *
 * Provides JavaScript functions to create, update, and remove SVG markers
 * that mirror the Elixir backend Marker component functionality for
 * efficient client-side map updates.
 */

import { markerToSvg, MAP_BBOX } from './map_coordinates.js';

/**
 * Default marker configuration matching Elixir backend.
 */
export const MARKER_CONFIG = {
  defaultRadius: 8,
  regionMarkerRadius: 4,
  markerOpacity: 1.0,
  animationDuration: '2s',
  pulseSizeDelta: 2,
  animationOpacityRange: [0.5, 1.0],
  legendContainerMultiplier: 2.0
};

/**
 * Create a new SVG marker element.
 *
 * @param {Object} options - Marker creation options
 * @param {string} options.id - Unique marker ID
 * @param {Object} options.style - Marker style configuration
 * @param {number} options.x - X coordinate
 * @param {number} options.y - Y coordinate
 * @param {Object} options.dataAttrs - Additional data attributes
 * @returns {SVGElement} Created marker group element
 *
 * @example
 * const marker = createMarker({
 *   id: 'marker-sjc',
 *   style: {colour: '#3b82f6', size: 8, animation: 'pulse'},
 *   x: 166.9,
 *   y: 131.1
 * });
 */
export function createMarker(options) {
  const {
    id,
    style = {},
    x = 0,
    y = 0,
    dataAttrs = {}
  } = options;

  // Extract style properties with defaults
  const radius = style.size || MARKER_CONFIG.defaultRadius;
  const colour = style.colour || '#6b7280';
  const animation = style.animation || 'none';
  const glow = style.glow || false;

  // Create marker group
  const group = document.createElementNS('http://www.w3.org/2000/svg', 'g');
  group.setAttribute('id', id);
  group.setAttribute('class', getMarkerClass(animation));

  // Add data attributes
  Object.entries(dataAttrs).forEach(([key, value]) => {
    group.setAttribute(key, value);
  });

  // Create main circle
  const circle = document.createElementNS('http://www.w3.org/2000/svg', 'circle');
  circle.setAttribute('cx', x);
  circle.setAttribute('cy', y);
  circle.setAttribute('r', radius);
  circle.setAttribute('stroke', 'none');
  circle.setAttribute('fill', glow ? getGlowFill(colour, id) : colour);

  // Add animations
  if (animation === 'pulse') {
    addPulseAnimation(circle, radius);
  } else if (animation === 'fade') {
    addFadeAnimation(circle);
  }

  group.appendChild(circle);

  // Create glow gradient if needed
  if (glow) {
    createGlowGradient(colour, id);
  }

  return group;
}

/**
 * Update an existing marker's position and style.
 *
 * @param {string} markerId - ID of marker to update
 * @param {Object} updates - Updates to apply
 * @param {number} updates.x - New X coordinate
 * @param {number} updates.y - New Y coordinate
 * @param {Object} updates.style - New style properties
 * @returns {boolean} True if marker was found and updated
 *
 * @example
 * updateMarker('marker-sjc', {
 *   x: 200,
 *   y: 150,
 *   style: {colour: '#ef4444', size: 10}
 * });
 */
export function updateMarker(markerId, updates) {
  const marker = document.getElementById(markerId);
  if (!marker) {
    return false;
  }

  const circle = marker.querySelector('circle');
  if (!circle) {
    return false;
  }

  // Update position
  if (updates.x !== undefined) {
    circle.setAttribute('cx', updates.x);
  }
  if (updates.y !== undefined) {
    circle.setAttribute('cy', updates.y);
  }

  // Update style
  if (updates.style) {
    const style = updates.style;

    if (style.colour) {
      const glow = style.glow || false;
      circle.setAttribute('fill', glow ? getGlowFill(style.colour, markerId) : style.colour);

      if (glow) {
        createGlowGradient(style.colour, markerId);
      }
    }

    if (style.size !== undefined) {
      circle.setAttribute('r', style.size);

      // Update pulse animation if present
      const pulseAnim = circle.querySelector('animate[attributeName="r"]');
      if (pulseAnim) {
        updatePulseAnimation(pulseAnim, style.size);
      }
    }

    if (style.animation !== undefined) {
      updateMarkerAnimation(marker, circle, style.animation, style.size || MARKER_CONFIG.defaultRadius);
    }
  }

  return true;
}

/**
 * Remove a marker from the map.
 *
 * @param {string} markerId - ID of marker to remove
 * @returns {boolean} True if marker was found and removed
 */
export function removeMarker(markerId) {
  const marker = document.getElementById(markerId);
  if (!marker) {
    return false;
  }

  marker.remove();

  // Clean up glow gradient if it exists
  const gradientId = `glow-gradient-${markerId}`;
  const gradient = document.getElementById(gradientId);
  if (gradient) {
    gradient.remove();
  }

  return true;
}

/**
 * Batch create markers from marker groups data.
 *
 * @param {Array} markerGroups - Array of marker group objects
 * @param {Object} bbox - Bounding box for coordinate transformation
 * @returns {Array} Array of created marker elements
 *
 * @example
 * const markers = createMarkersFromGroups([
 *   {
 *     id: 'production',
 *     nodes: ['sjc', 'fra'],
 *     style: {colour: '#3b82f6', size: 8, animation: 'pulse'}
 *   }
 * ]);
 */
export function createMarkersFromGroups(markerGroups, bbox = MAP_BBOX) {
  const markers = [];

  markerGroups.forEach((group, groupIndex) => {
    const nodes = group.nodes || group.markers || [];
    const groupStyle = group.style || {};
    const groupId = group.id || `group-${groupIndex}`;

    nodes.forEach((node, nodeIndex) => {
      const coords = markerToSvg(node, bbox);
      if (!coords) {
        console.warn(`Failed to get coordinates for marker:`, node);
        return;
      }

      const markerId = `${groupId}-${nodeIndex}`;
      const dataAttrs = group.group_label ? {
        'data-group': sanitizeGroupLabel(group.group_label)
      } : {};

      const marker = createMarker({
        id: markerId,
        style: groupStyle,
        x: coords.x,
        y: coords.y,
        dataAttrs
      });

      markers.push(marker);
    });
  });

  return markers;
}

/**
 * Toggle visibility of marker group.
 *
 * @param {string} groupLabel - Group label to toggle
 * @param {boolean} visible - Whether group should be visible
 */
export function toggleMarkerGroup(groupLabel, visible) {
  const safeLabel = sanitizeGroupLabel(groupLabel);
  const className = `group-hidden-${safeLabel}`;
  const existingStyle = document.getElementById('group-visibility-styles');

  if (!existingStyle) {
    const style = document.createElement('style');
    style.id = 'group-visibility-styles';
    document.head.appendChild(style);
  }

  const styleSheet = document.getElementById('group-visibility-styles').sheet;
  const rule = `.${className} { display: none !important; }`;

  // Remove existing rule if present
  for (let i = styleSheet.cssRules.length - 1; i >= 0; i--) {
    if (styleSheet.cssRules[i].selectorText === `.${className}`) {
      styleSheet.deleteRule(i);
    }
  }

  // Add rule if hiding group
  if (!visible) {
    styleSheet.insertRule(rule, styleSheet.cssRules.length);
  }
}

// Helper functions

function getMarkerClass(animation) {
  return animation === 'none' ? 'marker-group static' : 'marker-group animated';
}

function getGlowFill(colour, markerId) {
  const gradientId = `glow-gradient-${sanitizeId(markerId)}`;
  return `url(#${gradientId})`;
}

function sanitizeId(id) {
  return id.replace(/[^a-zA-Z0-9_-]/g, '_');
}

function sanitizeGroupLabel(label) {
  return label.replace(/[^a-zA-Z0-9_-]/g, '_');
}

function createGlowGradient(colour, markerId) {
  const gradientId = `glow-gradient-${sanitizeId(markerId)}`;

  // Check if gradient already exists
  if (document.getElementById(gradientId)) {
    return;
  }

  // Find or create defs section
  let defs = document.querySelector('svg defs');
  if (!defs) {
    const svg = document.querySelector('svg');
    if (!svg) return;

    defs = document.createElementNS('http://www.w3.org/2000/svg', 'defs');
    svg.insertBefore(defs, svg.firstChild);
  }

  // Create radial gradient
  const gradient = document.createElementNS('http://www.w3.org/2000/svg', 'radialGradient');
  gradient.setAttribute('id', gradientId);
  gradient.setAttribute('cx', '50%');
  gradient.setAttribute('cy', '50%');
  gradient.setAttribute('r', '50%');
  gradient.setAttribute('fx', '50%');
  gradient.setAttribute('fy', '50%');

  // Create gradient stops
  const stops = [
    { offset: '60%', opacity: '1' },
    { offset: '80%', opacity: '0.6' },
    { offset: '100%', opacity: '0.2' }
  ];

  stops.forEach(stop => {
    const stopElement = document.createElementNS('http://www.w3.org/2000/svg', 'stop');
    stopElement.setAttribute('offset', stop.offset);
    stopElement.setAttribute('stop-color', colour);
    stopElement.setAttribute('stop-opacity', stop.opacity);
    gradient.appendChild(stopElement);
  });

  defs.appendChild(gradient);
}

function addPulseAnimation(circle, radius) {
  const animate = document.createElementNS('http://www.w3.org/2000/svg', 'animate');
  animate.setAttribute('attributeName', 'r');
  animate.setAttribute('values', getPulseValues(radius));
  animate.setAttribute('dur', MARKER_CONFIG.animationDuration);
  animate.setAttribute('repeatCount', '2');
  circle.appendChild(animate);
}

function addFadeAnimation(circle) {
  const animate = document.createElementNS('http://www.w3.org/2000/svg', 'animate');
  animate.setAttribute('attributeName', 'opacity');
  animate.setAttribute('values', getFadeValues());
  animate.setAttribute('dur', MARKER_CONFIG.animationDuration);
  animate.setAttribute('repeatCount', 'indefinite');
  circle.appendChild(animate);
}

function updatePulseAnimation(animateElement, newRadius) {
  animateElement.setAttribute('values', getPulseValues(newRadius));
}

function updateMarkerAnimation(marker, circle, newAnimation, radius) {
  // Remove existing animations
  const animations = circle.querySelectorAll('animate');
  animations.forEach(anim => anim.remove());

  // Update marker class
  marker.setAttribute('class', getMarkerClass(newAnimation));

  // Add new animation
  if (newAnimation === 'pulse') {
    addPulseAnimation(circle, radius);
  } else if (newAnimation === 'fade') {
    addFadeAnimation(circle);
  }
}

function getPulseValues(radius) {
  const maxRadius = radius + MARKER_CONFIG.pulseSizeDelta;
  return `${radius};${maxRadius};${radius}`;
}

function getFadeValues() {
  const [min, max] = MARKER_CONFIG.animationOpacityRange;
  return `${min};${max};${min}`;
}