# GeoWake Documentation Index

Welcome to the GeoWake project documentation. This index will help you find the information you need.

---

## 📖 Getting Started

**New to the project? Start here:**

1. **[Quick Start Guide](QUICK_START_GUIDE.md)** - Set up your development environment
   - Backend setup (Node.js server)
   - Frontend setup (Flutter app)
   - Running tests
   - Common issues & solutions

2. **[Main README](../README.md)** - Project overview and features

---

## 🏗️ Architecture & Infrastructure

### Backend (Node.js/Express)

- **[Frontend-Backend Connectivity](FRONTEND_BACKEND_CONNECTIVITY.md)** ⭐ **MAIN DOCUMENT**
  - Complete system architecture
  - Backend service details
  - Frontend API client
  - All API endpoints
  - Authentication & security
  - Testing infrastructure
  - **23KB comprehensive guide**

- **[Railway Deployment Guide](RAILWAY_DEPLOYMENT.md)**
  - Platform overview
  - Production configuration
  - Environment variables
  - Deployment workflow
  - Monitoring & troubleshooting
  - **12KB deployment guide**

### Frontend (Flutter/Dart)

- **[API Client Documentation](services/api_client.md)** (if exists)
  - API client architecture
  - Token management
  - Request/response handling

---

## 🧪 Testing

- **[API & Testing Overview](API_TESTING_OVERVIEW.md)** ⭐ **COMPREHENSIVE SUMMARY**
  - Executive summary
  - Complete architecture
  - All 76 tests (38 backend + 38 frontend)
  - Testing strategies
  - Comparison with typical projects
  - **19KB overview document**

- **[Backend Test Suite](../geowake-server/test/README.md)**
  - 38 backend tests
  - How to run tests
  - Test structure
  - CI/CD integration
  - **7KB test guide**

- **[Frontend Test Coverage](tests/coverage.md)** (if exists)
  - Flutter unit tests
  - Integration tests
  - Test utilities

---

## 🔐 Security

- **[Security Setup Guide](../SECURITY_SETUP.md)**
  - API key management
  - Environment variables
  - Production deployment security

- **Security Features in [Frontend-Backend Connectivity](FRONTEND_BACKEND_CONNECTIVITY.md#authentication--security)**
  - JWT authentication
  - Rate limiting
  - CORS configuration
  - Security headers

---

## 📡 API Reference

### Quick Reference

All endpoints documented in **[Frontend-Backend Connectivity](FRONTEND_BACKEND_CONNECTIVITY.md#api-endpoints)**

#### Authentication
- `POST /api/auth/token` - Generate JWT token

#### Maps APIs (require authentication)
- `POST /api/maps/directions` - Get route directions
- `POST /api/maps/autocomplete` - Place search suggestions
- `POST /api/maps/place-details` - Detailed place information
- `POST /api/maps/geocode` - Address ↔ Coordinates
- `POST /api/maps/nearby-search` - Find nearby places

#### Health Checks
- `GET /` - Server status
- `GET /api/health` - Health check

---

## 🔧 Services & Components

### Frontend Services

Located in `lib/services/`:

1. **API & Network**
   - `api_client.dart` - HTTP client with authentication
   - `direction_service.dart` - Route planning
   - `places_service.dart` - Place search
   
2. **Location & Tracking**
   - `trackingservice.dart` - GPS tracking
   - `active_route_manager.dart` - Active route management
   - `deviation_monitor.dart` - Route deviation detection
   - `snap_to_route.dart` - Position snapping
   
3. **Route Management**
   - `route_registry.dart` - Route storage
   - `route_cache.dart` - Route caching
   - `route_queue.dart` - Route queue
   - `offline_coordinator.dart` - Offline mode
   
4. **Notifications & Alarms**
   - `notification_service.dart` - Push notifications
   - `alarm_player.dart` - Alarm sounds
   
5. **Utilities**
   - `eta_utils.dart` - ETA calculations
   - `polyline_decoder.dart` - Polyline decoding
   - `polyline_simplifier.dart` - Polyline simplification
   - `sensor_fusion.dart` - Sensor data fusion

### Backend Services

Located in `geowake-server/src/`:

1. **Controllers**
   - `authController.js` - Authentication logic
   - `mapsController.js` - Google Maps proxy
   
2. **Middleware**
   - `auth.js` - JWT verification
   - `security.js` - Rate limiting & slow down
   
3. **Utilities**
   - `cache.js` - Response caching (NodeCache)
   
4. **Configuration**
   - `config.js` - Environment configuration

---

## 📊 Project Statistics

### Code Base
- **Backend:** ~1,000 lines (Node.js/Express)
- **Frontend:** ~10,000+ lines (Flutter/Dart)
- **Tests:** 76 total tests
  - Backend: 38 tests (Jest + Supertest)
  - Frontend: 38 tests (Flutter test framework)

### Dependencies
- **Backend:** 11 production dependencies
- **Frontend:** 30+ Flutter packages

### Documentation
- **Total Docs:** 60KB+ of comprehensive documentation
- **Main Guides:** 4 comprehensive documents
- **Code Comments:** Inline documentation throughout

---

## 🚀 Development Workflow

### Local Development

1. **Start Backend Server:**
   ```bash
   cd geowake-server
   npm run dev  # Auto-restarts on changes
   ```

2. **Run Flutter App:**
   ```bash
   cd GeoWake
   flutter run  # Hot reload enabled
   ```

3. **Run Tests:**
   ```bash
   # Backend tests
   cd geowake-server && npm test
   
   # Frontend tests
   cd .. && flutter test
   ```

### Deployment

- **Backend:** Auto-deploys to Railway on push to main
- **Frontend:** Build and deploy to app stores

**Full details:** [Quick Start Guide](QUICK_START_GUIDE.md)

---

## 🎓 Learning Path

### For New Developers

**Day 1: Setup & Basics**
1. Read [Main README](../README.md)
2. Follow [Quick Start Guide](QUICK_START_GUIDE.md)
3. Get app running locally

**Day 2: Architecture**
1. Read [Frontend-Backend Connectivity](FRONTEND_BACKEND_CONNECTIVITY.md)
2. Understand API flow
3. Explore code structure

**Day 3: Deep Dive**
1. Read [API Testing Overview](API_TESTING_OVERVIEW.md)
2. Run and examine tests
3. Make a small code change

**Day 4: Deployment**
1. Read [Railway Deployment Guide](RAILWAY_DEPLOYMENT.md)
2. Understand production setup
3. Monitor logs and metrics

### For Backend Developers

Focus on:
1. [Frontend-Backend Connectivity](FRONTEND_BACKEND_CONNECTIVITY.md#backend-service-architecture)
2. [Backend Test Suite](../geowake-server/test/README.md)
3. Backend source code in `geowake-server/src/`

### For Frontend Developers

Focus on:
1. [Frontend-Backend Connectivity](FRONTEND_BACKEND_CONNECTIVITY.md#frontend-backend-communication)
2. [API Client Documentation](FRONTEND_BACKEND_CONNECTIVITY.md#api-client-libservicesapi_clientdart)
3. Frontend source code in `lib/`

### For DevOps/Infrastructure

Focus on:
1. [Railway Deployment Guide](RAILWAY_DEPLOYMENT.md)
2. [Security Setup Guide](../SECURITY_SETUP.md)
3. Environment configuration

---

## 🔍 Quick Links

### External Resources
- **GitHub Repository:** https://github.com/Raed2180416/GeoWake
- **Production API:** https://geowake-production.up.railway.app
- **Railway Dashboard:** https://railway.app (requires login)

### API Documentation
- **Google Maps APIs:** https://developers.google.com/maps
- **Flutter Documentation:** https://flutter.dev/docs
- **Express.js Guide:** https://expressjs.com/

### Tools & Services
- **Railway:** https://railway.app
- **Node.js:** https://nodejs.org/
- **Flutter:** https://flutter.dev

---

## 📝 Documentation Standards

### File Naming
- Use UPPERCASE for main documents (e.g., `README.md`, `QUICK_START_GUIDE.md`)
- Use lowercase for service docs (e.g., `api_client.md`)
- Use descriptive names (e.g., `FRONTEND_BACKEND_CONNECTIVITY.md`)

### Document Structure
- Start with overview/summary
- Include table of contents for long docs
- Use clear headings and sections
- Include code examples
- Add diagrams where helpful
- End with version/date info

### Updating Documentation
- Update docs when making significant changes
- Keep examples accurate
- Update version numbers
- Add date of last update

---

## 🆘 Need Help?

### Documentation Issues
- Missing information? Create an issue on GitHub
- Found an error? Submit a pull request
- Need clarification? Ask in team chat

### Code Issues
- Check [Quick Start Guide](QUICK_START_GUIDE.md) for common problems
- Review test files for examples
- Check inline code comments

### Deployment Issues
- Review [Railway Deployment Guide](RAILWAY_DEPLOYMENT.md)
- Check Railway dashboard logs
- Verify environment variables

---

## 📚 Full Document List

### Main Documentation
- ✅ [README.md](../README.md) - Project overview
- ✅ [QUICK_START_GUIDE.md](QUICK_START_GUIDE.md) - Setup guide
- ✅ [FRONTEND_BACKEND_CONNECTIVITY.md](FRONTEND_BACKEND_CONNECTIVITY.md) - Architecture & APIs
- ✅ [RAILWAY_DEPLOYMENT.md](RAILWAY_DEPLOYMENT.md) - Deployment guide
- ✅ [API_TESTING_OVERVIEW.md](API_TESTING_OVERVIEW.md) - Testing overview
- ✅ [SECURITY_SETUP.md](../SECURITY_SETUP.md) - Security configuration

### Test Documentation
- ✅ [Backend Test Suite](../geowake-server/test/README.md) - Backend tests
- ✅ [Test Coverage](tests/coverage.md) - Frontend test coverage (if exists)
- ✅ [Test Traceability](tests/traceability.md) - Test mapping (if exists)

### Service Documentation
- ⚠️ Individual service docs in `services/` (some may be WIP)
- ⚠️ Screen documentation in `screens/` (some may be WIP)

### Other
- ✅ [Logic Flow](logic-flow.md) - App logic flow (if exists)
- ✅ [Annotated Docs](annotated/README.md) - Line-by-line code walkthrough (if exists)

**Legend:**
- ✅ Complete and up-to-date
- ⚠️ Exists but may be incomplete
- ❌ Planned but not yet created

---

## 🎯 Document Priorities

### Critical (Read First)
1. Quick Start Guide
2. Frontend-Backend Connectivity
3. API Testing Overview

### Important (Read Soon)
1. Railway Deployment
2. Security Setup
3. Backend Test Suite

### Reference (As Needed)
1. Service-specific docs
2. Test coverage details
3. Logic flow diagrams

---

**Documentation Index Version:** 1.0  
**Last Updated:** 2024-01-15  
**Total Documentation:** ~60KB across 8+ files  
**Maintained By:** GeoWake Development Team

---

**Pro Tip:** Start with the [Quick Start Guide](QUICK_START_GUIDE.md) if you're setting up for the first time, or dive into [Frontend-Backend Connectivity](FRONTEND_BACKEND_CONNECTIVITY.md) if you want to understand the architecture!
