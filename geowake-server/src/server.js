// src/server.js
const express = require('express');
const cors = require('cors');
const helmet = require('helmet');
const compression = require('compression');
const morgan = require('morgan');

const config = require('./config/config');
const { authenticateDevice } = require('./middleware/auth');
const { slowDownRules, handleRateLimitError } = require('./middleware/security');

// Import routes
const authRoutes = require('./routes/auth');
const mapsRoutes = require('./routes/maps');

const app = express();

// ================================
// SECURITY & MIDDLEWARE SETUP
// ================================

// Security headers
app.use(helmet({
  crossOriginEmbedderPolicy: false, // Allow embedding for mobile apps
  contentSecurityPolicy: false // Disable CSP for API server
}));

// Compression
app.use(compression());

// CORS configuration
app.use(cors({
  origin: (origin, callback) => {
    // Allow requests with no origin (mobile apps)
    if (!origin) return callback(null, true);
    
    // Check if origin is in allowed list
    if (config.allowedOrigins.includes(origin)) {
      return callback(null, true);
    }
    
    // For development, allow localhost
    if (config.nodeEnv === 'development' && origin.includes('localhost')) {
      return callback(null, true);
    }
    
    callback(new Error('Not allowed by CORS'));
  },
  credentials: true,
  methods: ['GET', 'POST', 'OPTIONS'],
  allowedHeaders: ['Content-Type', 'Authorization', 'X-Requested-With']
}));

// Request parsing
app.use(express.json({ limit: '10mb' }));
app.use(express.urlencoded({ extended: true, limit: '10mb' }));

// Logging
const logFormat = config.nodeEnv === 'production' 
  ? 'combined' 
  : '🚀 :method :url :status :res[content-length] - :response-time ms';

app.use(morgan(logFormat));

// Slow down middleware for all routes
app.use(slowDownRules.general);

// ================================
// ROUTES SETUP
// ================================

// Health check (no auth required)
app.get('/', (req, res) => {
  res.json({
    success: true,
    message: 'GeoWake API Server',
    version: '1.0.0',
    environment: config.nodeEnv,
    timestamp: new Date().toISOString(),
    uptime: process.uptime()
  });
});

// Authentication routes (no auth required)
app.use('/api/auth', authRoutes);

// Protected API routes (require authentication)
app.use('/api/maps', authenticateDevice, mapsRoutes);

// ================================
// ERROR HANDLING
// ================================


// 404 handler - Fixed path pattern
app.use((req, res) => {
  res.status(404).json({
    success: false,
    error: 'Endpoint not found',
    path: req.originalUrl
  });
});
// Rate limit error handler
app.use(handleRateLimitError);

// Global error handler
app.use((err, req, res, next) => {
  console.error('❌ Server Error:', err.message);
  console.error('Stack:', err.stack);
  
  // Don't leak error details in production
  const isDev = config.nodeEnv === 'development';
  
  res.status(err.status || 500).json({
    success: false,
    error: isDev ? err.message : 'Internal server error',
    ...(isDev && { stack: err.stack }),
    timestamp: new Date().toISOString()
  });
});

// ================================
// START SERVER
// ================================

const server = app.listen(config.port, () => {
  console.log('\n🌍 ================================');
  console.log('🚀 GeoWake API Server Started!');
  console.log('🌍 ================================');
  console.log(`📍 Environment: ${config.nodeEnv}`);
  console.log(`🌐 Port: ${config.port}`);
  console.log(`🔑 Google Maps API: ${config.googleMapsApiKey ? '✅ Configured' : '❌ Missing'}`);
  console.log(`🛡️  JWT Secret: ${config.jwtSecret ? '✅ Configured' : '❌ Missing'}`);
  console.log(`📱 Bundle ID: ${config.appBundleId}`);
  console.log(`⏰ Started at: ${new Date().toISOString()}`);
  console.log('🌍 ================================\n');
  
  // Graceful shutdown handling
  process.on('SIGINT', () => {
    console.log('\n🛑 Received SIGINT, shutting down gracefully...');
    server.close(() => {
      console.log('✅ Server closed successfully');
      process.exit(0);
    });
  });
  
  process.on('SIGTERM', () => {
    console.log('\n🛑 Received SIGTERM, shutting down gracefully...');
    server.close(() => {
      console.log('✅ Server closed successfully');
      process.exit(0);
    });
  });
});

module.exports = app;