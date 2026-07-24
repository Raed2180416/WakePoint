// src/utils/cache.js
const NodeCache = require('node-cache');
const config = require('../config/config');

class CacheManager {
  constructor() {
    this.cache = new NodeCache({
      stdTTL: 300, // Default 5 minutes
      checkperiod: 120, // Check for expired keys every 2 minutes
      useClones: false, // Better performance
      // server-cost-security: cache keys are built from client-supplied
      // request params (origin/destination/input/address/... in generateKey
      // below), so without a bound an attacker holding one token could send
      // many distinct junk queries to inflate server memory indefinitely.
      // node-cache throws ECACHEFULL once this is hit; set() below catches
      // that and just skips caching rather than failing the request.
      maxKeys: parseInt(process.env.CACHE_MAX_KEYS) || 2000
    });
    
    // Log cache statistics in development only
    if (config.nodeEnv !== 'production') {
      const statsInterval = setInterval(() => {
        const stats = this.cache.getStats();
        console.log(`📊 Cache Stats - Keys: ${stats.keys}, Hits: ${stats.hits}, Misses: ${stats.misses}`);
      }, 5 * 60 * 1000); // Every 5 minutes
      // Don't let this timer keep the process (or a Jest worker) alive on
      // its own — it's a nice-to-have log, not something that should block
      // a clean shutdown/exit.
      if (typeof statsInterval.unref === 'function') statsInterval.unref();
    }
  }
  
  // Generate cache key for different types of requests
  generateKey(type, params) {
    switch (type) {
      case 'directions':
        return `directions:${params.origin}:${params.destination}:${params.mode || 'driving'}:${params.transit_mode || ''}:${params.departure_time || ''}`;
      
      case 'places':
        return `places:${params.input}:${params.location || ''}:${params.radius || ''}:${params.components || ''}`;
      
      case 'place-details':
        return `place-details:${params.place_id}`;
      
      case 'geocoding':
        return `geocoding:${params.latlng || params.address}`;
      
      case 'nearby-search':
        return `nearby:${params.location}:${params.radius}:${params.type}`;
      
      default:
        return `generic:${JSON.stringify(params)}`;
    }
  }
  
  // Get from cache
  get(type, params) {
    const key = this.generateKey(type, params);
    const result = this.cache.get(key);
    
    // Only log cache hit/miss in development to avoid I/O overhead in production
    if (config.nodeEnv !== 'production') {
      if (result) {
        console.log(`🎯 Cache HIT for ${type}: ${key}`);
      } else {
        console.log(`❌ Cache MISS for ${type}: ${key}`);
      }
    }
    
    return result;
  }
  
  // Set in cache with appropriate TTL
  set(type, params, data) {
    const key = this.generateKey(type, params);
    const ttl = config.cacheTimeouts[type] || 300; // Default 5 minutes

    try {
      this.cache.set(key, data, ttl);
    } catch (err) {
      // node-cache throws (ECACHEFULL) once maxKeys is exceeded. Skip caching
      // rather than failing the request — the caller still gets a valid,
      // just-uncached response.
      if (config.nodeEnv !== 'production') {
        console.warn(`⚠️  Cache set skipped (${err.message || err}) for ${type}: ${key}`);
      }
      return false;
    }

    if (config.nodeEnv !== 'production') {
      console.log(`💾 Cached ${type} for ${ttl}s: ${key}`);
    }

    return true;
  }
  
  // Clear cache for a specific type
  clearType(type) {
    const keys = this.cache.keys();
    const typeKeys = keys.filter(key => key.startsWith(`${type}:`));
    
    typeKeys.forEach(key => this.cache.del(key));
    console.log(`🗑️  Cleared ${typeKeys.length} ${type} cache entries`);
    
    return typeKeys.length;
  }
  
  // Get cache statistics
  getStats() {
    return this.cache.getStats();
  }
  
  // Clear all cache
  flush() {
    this.cache.flushAll();
    console.log('🗑️  Cache completely flushed');
  }
}

// Export singleton instance
module.exports = new CacheManager();