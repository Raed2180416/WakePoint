// src/utils/cache.js
const NodeCache = require('node-cache');
const config = require('../config/config');

class CacheManager {
  constructor() {
    this.cache = new NodeCache({
      stdTTL: 300, // Default 5 minutes
      checkperiod: 120, // Check for expired keys every 2 minutes
      useClones: false // Better performance
    });
    
    // Log cache statistics
    setInterval(() => {
      const stats = this.cache.getStats();
      console.log(`📊 Cache Stats - Keys: ${stats.keys}, Hits: ${stats.hits}, Misses: ${stats.misses}`);
    }, 5 * 60 * 1000); // Every 5 minutes
  }
  
  // Generate cache key for different types of requests
  generateKey(type, params) {
    switch (type) {
      case 'directions':
        return `directions:${params.origin}:${params.destination}:${params.mode || 'driving'}:${params.transit_mode || ''}`;
      
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
    
    if (result) {
      console.log(`🎯 Cache HIT for ${type}: ${key}`);
    } else {
      console.log(`❌ Cache MISS for ${type}: ${key}`);
    }
    
    return result;
  }
  
  // Set in cache with appropriate TTL
  set(type, params, data) {
    const key = this.generateKey(type, params);
    const ttl = config.cacheTimeouts[type] || 300; // Default 5 minutes
    
    this.cache.set(key, data, ttl);
    console.log(`💾 Cached ${type} for ${ttl}s: ${key}`);
    
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