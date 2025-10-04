/**
 * Phoenix LiveView hook for real-time map marker updates.
 *
 * This hook manages client-side marker rendering and real-time updates
 * via Phoenix channels, providing efficient map updates without full
 * LiveView rerenders.
 */

import {
  createMarkersFromGroups,
  updateMarker,
  removeMarker,
  toggleMarkerGroup
} from './map_markers.js';

/**
 * Factory function to create a RealTimeMapHook with a provided socket.
 *
 * @param {Socket} socket - Phoenix socket instance
 * @returns {Object} Phoenix LiveView hook object
 */
export function createRealTimeMapHook(socket) {
  return {
  mounted() {
    console.log('RealTimeMapHook: Mounting real-time map');

    // Check if real-time mode is supported
    if (!this.isRealTimeModeSupported()) {
      console.log('RealTimeMapHook: Real-time mode not supported, using server rendering');
      this.fallbackToServerRendering();
      return;
    }

    // Get configuration from data attributes
    this.channelTopic = this.el.dataset.channel || 'map:default';
    this.mapId = this.el.dataset.mapId || 'fly-region-map';

    // Parse initial state
    try {
      this.initialState = JSON.parse(this.el.dataset.initialState || '{}');
    } catch (e) {
      console.error('RealTimeMapHook: Failed to parse initial state', e);
      this.initialState = {};
    }

    // Initialize client state
    this.clientState = {
      markerGroups: this.initialState.markerGroups || [],
      theme: this.initialState.theme || {},
      config: this.initialState.config || {},
      lastUpdate: Date.now()
    };

    // Track markers by ID for efficient updates
    this.activeMarkers = new Map();

    // Set up channel
    this.setupChannel();

    // Render initial markers
    this.renderInitialMarkers();

    // Listen for disconnect/reconnect events
    this.handleConnectionEvents();

    // Set up error handling
    this.setupErrorHandling();
  },

  destroyed() {
    console.log('RealTimeMapHook: Destroying real-time map');

    if (this.channel) {
      this.channel.leave();
    }
  },

  setupChannel() {
    // Join the map channel
    this.channel = socket.channel(this.channelTopic, {});

    // Handle channel events
    this.channel.on('marker_state', (payload) => {
      console.log('RealTimeMapHook: Received marker state', payload);
      this.handleMarkerState(payload);
    });

    this.channel.on('marker_update', (payload) => {
      console.log('RealTimeMapHook: Received marker update', payload);
      this.handleMarkerUpdate(payload);
    });

    this.channel.on('marker_add', (payload) => {
      console.log('RealTimeMapHook: Received marker add', payload);
      this.handleMarkerAdd(payload);
    });

    this.channel.on('marker_remove', (payload) => {
      console.log('RealTimeMapHook: Received marker remove', payload);
      this.handleMarkerRemove(payload);
    });

    this.channel.on('theme_change', (payload) => {
      console.log('RealTimeMapHook: Received theme change', payload);
      this.handleThemeChange(payload);
    });

    this.channel.on('group_toggle', (payload) => {
      console.log('RealTimeMapHook: Received group toggle', payload);
      this.handleGroupToggle(payload);
    });

    // Join channel and handle responses
    this.channel.join()
      .receive('ok', (resp) => {
        console.log('RealTimeMapHook: Joined channel successfully', resp);
        this.connectionState = 'joined';
        this.reconnectAttempts = 0; // Reset reconnect counter on successful join
      })
      .receive('error', (resp) => {
        console.error('RealTimeMapHook: Failed to join channel', resp);
        this.connectionState = 'error';
        this.fallbackToServerRendering();
      });
  },

  renderInitialMarkers() {
    const svg = document.getElementById(this.mapId);
    if (!svg) {
      console.error('RealTimeMapHook: Map SVG not found:', this.mapId);
      return;
    }

    // Clear any existing client-rendered markers
    this.clearClientMarkers();

    // Create markers from initial state
    const markers = createMarkersFromGroups(
      this.clientState.markerGroups,
      this.clientState.config.bbox
    );

    // Add markers to SVG and track them
    markers.forEach(marker => {
      svg.appendChild(marker);
      this.activeMarkers.set(marker.id, marker);
    });

    console.log(`RealTimeMapHook: Rendered ${markers.length} initial markers`);
  },

  handleMarkerState(payload) {
    // Update client state
    this.clientState = {
      ...this.clientState,
      markerGroups: payload.marker_groups || [],
      theme: payload.theme || this.clientState.theme,
      config: payload.config || this.clientState.config,
      lastUpdate: Date.now()
    };

    // Re-render all markers
    this.renderInitialMarkers();
  },

  handleMarkerUpdate(payload) {
    const { group_id, markers } = payload;

    if (!markers || !Array.isArray(markers)) {
      console.warn('RealTimeMapHook: Invalid marker update payload', payload);
      return;
    }

    // Find and update group in client state
    const groupIndex = this.clientState.markerGroups.findIndex(
      group => group.id === group_id
    );

    if (groupIndex === -1) {
      console.warn('RealTimeMapHook: Group not found for update:', group_id);
      return;
    }

    // Update group markers
    this.clientState.markerGroups[groupIndex].markers = markers;
    this.clientState.lastUpdate = Date.now();

    // Re-render affected group
    this.renderGroupMarkers(this.clientState.markerGroups[groupIndex]);
  },

  handleMarkerAdd(payload) {
    const { group_id, marker } = payload;

    // Find group
    const group = this.clientState.markerGroups.find(g => g.id === group_id);
    if (!group) {
      console.warn('RealTimeMapHook: Group not found for marker add:', group_id);
      return;
    }

    // Add marker to group
    group.markers = group.markers || [];
    group.markers.push(marker);
    this.clientState.lastUpdate = Date.now();

    // Create and add new marker
    const markerId = `${group_id}-${group.markers.length - 1}`;
    const markerElement = this.createSingleMarker(marker, group.style, markerId);

    if (markerElement) {
      const svg = document.getElementById(this.mapId);
      svg.appendChild(markerElement);
      this.activeMarkers.set(markerId, markerElement);
    }
  },

  handleMarkerRemove(payload) {
    const { group_id, marker_id } = payload;

    // Remove from DOM
    const removed = removeMarker(marker_id);
    if (removed) {
      this.activeMarkers.delete(marker_id);
    }

    // Update client state
    const group = this.clientState.markerGroups.find(g => g.id === group_id);
    if (group && group.markers) {
      group.markers = group.markers.filter((_, index) =>
        `${group_id}-${index}` !== marker_id
      );
      this.clientState.lastUpdate = Date.now();
    }
  },

  handleThemeChange(payload) {
    // Update theme in client state
    this.clientState.theme = { ...this.clientState.theme, ...payload.theme };
    this.clientState.lastUpdate = Date.now();

    // Apply theme changes to SVG
    this.applyThemeToSvg(payload.theme);
  },

  handleGroupToggle(payload) {
    const { group_id, visible } = payload;

    // Toggle group visibility
    toggleMarkerGroup(group_id, visible);

    // Update client state
    const group = this.clientState.markerGroups.find(g => g.id === group_id);
    if (group) {
      group.visible = visible;
      this.clientState.lastUpdate = Date.now();
    }
  },

  renderGroupMarkers(group) {
    // Remove existing markers for this group
    this.activeMarkers.forEach((marker, markerId) => {
      if (markerId.startsWith(`${group.id}-`)) {
        marker.remove();
        this.activeMarkers.delete(markerId);
      }
    });

    // Create new markers for group
    const markers = createMarkersFromGroups([group], this.clientState.config.bbox);
    const svg = document.getElementById(this.mapId);

    markers.forEach(marker => {
      svg.appendChild(marker);
      this.activeMarkers.set(marker.id, marker);
    });
  },

  createSingleMarker(markerData, style, markerId) {
    // Implementation would use markerToSvg and createMarker functions
    // This is a simplified version for demonstration
    console.log('Creating single marker:', markerId, markerData, style);
    return null; // Placeholder
  },

  clearClientMarkers() {
    this.activeMarkers.forEach(marker => marker.remove());
    this.activeMarkers.clear();
  },

  applyThemeToSvg(theme) {
    const svg = document.getElementById(this.mapId);
    if (!svg) return;

    // Apply theme colors to CSS variables
    const style = svg.querySelector('style');
    if (style && theme) {
      // Update CSS variables for theme colors
      Object.entries(theme).forEach(([key, value]) => {
        if (typeof value === 'string') {
          svg.style.setProperty(`--theme-${key}`, value);
        }
      });
    }
  },

  handleConnectionEvents() {
    // Handle socket disconnect
    socket.onError(() => {
      console.warn('RealTimeMapHook: Socket connection error, falling back to server rendering');
      this.fallbackToServerRendering();
    });

    // Handle socket reconnect
    socket.onOpen(() => {
      console.log('RealTimeMapHook: Socket reconnected, requesting state sync');
      this.requestStateSync();
    });
  },

  requestStateSync() {
    if (this.channel && this.channel.state === 'joined') {
      this.channel.push('state_sync', {
        client_state: {
          last_update: this.clientState.lastUpdate,
          marker_count: this.activeMarkers.size
        }
      });
    }
  },

  fallbackToServerRendering() {
    // Clear client-rendered markers
    this.clearClientMarkers();

    // Mark as using fallback mode
    this.usingFallback = true;
    this.el.dataset.fallbackMode = 'true';

    // Trigger LiveView update by sending an event
    this.pushEvent('fallback_to_server', {
      reason: 'channel_error',
      timestamp: Date.now()
    });

    console.log('RealTimeMapHook: Switched to server rendering fallback');
  },

  // Enhanced error handling and recovery
  setupErrorHandling() {
    // Track connection state
    this.connectionState = 'connecting';
    this.reconnectAttempts = 0;
    this.maxReconnectAttempts = 5;
    this.reconnectDelay = 1000; // Start with 1 second

    // Handle channel errors
    this.channel.onError((error) => {
      console.error('RealTimeMapHook: Channel error', error);
      this.connectionState = 'error';
      this.handleChannelError(error);
    });

    // Handle channel close
    this.channel.onClose((reason) => {
      console.warn('RealTimeMapHook: Channel closed', reason);
      this.connectionState = 'closed';
      this.handleChannelClose(reason);
    });
  },

  handleChannelError(error) {
    if (this.reconnectAttempts < this.maxReconnectAttempts) {
      this.attemptReconnect();
    } else {
      console.error('RealTimeMapHook: Max reconnection attempts reached, falling back to server rendering');
      this.fallbackToServerRendering();
    }
  },

  handleChannelClose(reason) {
    if (reason !== 'leave' && this.reconnectAttempts < this.maxReconnectAttempts) {
      this.attemptReconnect();
    }
  },

  attemptReconnect() {
    this.reconnectAttempts++;
    const delay = Math.min(this.reconnectDelay * Math.pow(2, this.reconnectAttempts - 1), 30000);

    console.log(`RealTimeMapHook: Attempting reconnection ${this.reconnectAttempts}/${this.maxReconnectAttempts} in ${delay}ms`);

    setTimeout(() => {
      if (this.connectionState !== 'joined') {
        this.setupChannel();
      }
    }, delay);
  },

  validateMarkerData(marker) {
    if (!marker) return false;

    // Check if marker has valid coordinates
    if (typeof marker === 'string') {
      // Region code - should be valid
      return true;
    }

    if (Array.isArray(marker) && marker.length === 2) {
      const [lat, lng] = marker;
      return typeof lat === 'number' && typeof lng === 'number' &&
             lat >= -90 && lat <= 90 && lng >= -180 && lng <= 180;
    }

    if (typeof marker === 'object' && marker !== null) {
      const lat = marker.lat || marker.latitude;
      const lng = marker.lng || marker.longitude;
      return typeof lat === 'number' && typeof lng === 'number' &&
             lat >= -90 && lat <= 90 && lng >= -180 && lng <= 180;
    }

    return false;
  },

  // Enhanced state validation
  validateServerState(state) {
    try {
      if (!state || typeof state !== 'object') {
        throw new Error('Invalid state format');
      }

      if (!Array.isArray(state.marker_groups)) {
        throw new Error('marker_groups must be an array');
      }

      // Validate each marker group
      state.marker_groups.forEach((group, index) => {
        if (!group.id || typeof group.id !== 'string') {
          throw new Error(`Group ${index} missing valid id`);
        }

        if (group.markers && Array.isArray(group.markers)) {
          group.markers.forEach((marker, markerIndex) => {
            if (!this.validateMarkerData(marker)) {
              throw new Error(`Invalid marker data at group ${index}, marker ${markerIndex}`);
            }
          });
        }
      });

      return true;
    } catch (error) {
      console.error('RealTimeMapHook: State validation failed', error);
      return false;
    }
  },

  // Check if real-time mode is supported by the browser and environment
  isRealTimeModeSupported() {
    try {
      // Check for required browser features
      if (!window.WebSocket) {
        console.warn('RealTimeMapHook: WebSocket not supported');
        return false;
      }

      if (!document.createElementNS) {
        console.warn('RealTimeMapHook: SVG manipulation not supported');
        return false;
      }

      // Check if map SVG exists
      const mapSvg = document.getElementById(this.mapId || 'fly-region-map');
      if (!mapSvg) {
        console.warn('RealTimeMapHook: Map SVG not found');
        return false;
      }

      // Check for required data attributes
      if (!this.el.dataset.channel) {
        console.warn('RealTimeMapHook: Channel topic not specified');
        return false;
      }

      return true;
    } catch (error) {
      console.error('RealTimeMapHook: Support detection failed', error);
      return false;
    }
  },

  // Progressive enhancement check
  isProgressiveEnhancementMode() {
    return this.el.dataset.progressiveEnhancement === 'true';
  },

  // Feature detection for advanced capabilities
  detectAdvancedFeatures() {
    const features = {
      webgl: !!window.WebGLRenderingContext,
      animations: 'animate' in document.createElementNS('http://www.w3.org/2000/svg', 'animate'),
      transforms: 'transform' in document.createElement('div').style,
      observerAPI: !!window.MutationObserver,
      perfNow: !!window.performance && !!window.performance.now
    };

    console.log('RealTimeMapHook: Detected features', features);
    return features;
  },

  // Graceful degradation strategy
  selectRenderingStrategy() {
    if (!this.isRealTimeModeSupported()) {
      return 'server';
    }

    const features = this.detectAdvancedFeatures();

    // Use server rendering if critical features are missing
    if (!features.animations || !features.transforms) {
      console.log('RealTimeMapHook: Using server rendering due to missing browser features');
      return 'server';
    }

    // Check performance hints
    if (window.navigator && window.navigator.connection) {
      const connection = window.navigator.connection;
      if (connection.effectiveType === 'slow-2g' || connection.effectiveType === '2g') {
        console.log('RealTimeMapHook: Using server rendering due to slow connection');
        return 'server';
      }
    }

    return 'realtime';
  }
  };
}

// Deprecated: For backward compatibility only
// Modern apps should use: createRealTimeMapHook(socket) with a proper Phoenix Socket instance
export const RealTimeMapHook = {
  mounted() {
    console.error(
      'RealTimeMapHook: Deprecated export used. ' +
      'Please use createRealTimeMapHook(socket) with a Phoenix Socket instance instead. ' +
      'Example: new Socket("/socket", {params: {...}}) then createRealTimeMapHook(socket)'
    );
  }
};