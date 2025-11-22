# GeoWake Railway Deployment Guide

## Overview

This document details the Railway.app deployment configuration for the GeoWake backend Node.js server.

## What is Railway?

**Railway** is a modern Platform-as-a-Service (PaaS) that provides:
- **One-click deployments** from GitHub
- **Automatic HTTPS** with free SSL certificates
- **Zero-downtime deployments**
- **Auto-scaling** based on traffic
- **Built-in monitoring** and logging
- **Environment variable management**
- **Custom domains** support

**Website:** https://railway.app

---

## Current Deployment

### Production URL
```
https://geowake-production.up.railway.app
```

### API Base URL
```
https://geowake-production.up.railway.app/api
```

---

## Project Configuration

### 1. GitHub Integration

Railway is connected to the GitHub repository:
- **Repository:** `Raed2180416/GeoWake`
- **Branch:** `main` (auto-deploy on push)
- **Root Directory:** `/geowake-server`

When you push to the main branch, Railway automatically:
1. Detects changes in the `geowake-server/` directory
2. Runs `npm install` to install dependencies
3. Starts the server with `npm start`
4. Performs health checks
5. Routes traffic to the new deployment

### 2. Build Configuration

**Specified in `package.json`:**

```json
{
  "engines": {
    "node": "18.x"
  },
  "scripts": {
    "start": "node src/server.js",
    "dev": "nodemon src/server.js"
  }
}
```

**Railway Build Process:**
```bash
# 1. Install dependencies
npm install

# 2. Start application
npm start
```

### 3. Environment Variables

Set in the Railway Dashboard under **Variables** tab:

| Variable | Example Value | Required | Purpose |
|----------|---------------|----------|---------|
| `GOOGLE_MAPS_API_KEY` | `AIzaSyC...` | ✅ Yes | Google Maps API access |
| `JWT_SECRET` | `your_secret_min_32_chars` | ✅ Yes | JWT token signing |
| `NODE_ENV` | `production` | ✅ Yes | Environment mode |
| `APP_BUNDLE_ID` | `com.yourcompany.geowake2` | ✅ Yes | Mobile app identifier |
| `PORT` | `3000` | ❌ No | Server port (auto-set by Railway) |
| `MAX_REQUESTS_PER_HOUR` | `1000` | ❌ No | Rate limit |
| `MAX_REQUESTS_PER_MINUTE` | `100` | ❌ No | Rate limit |
| `ALLOWED_ORIGINS` | `*` | ❌ No | CORS origins |

**Setting Environment Variables:**
1. Go to Railway Dashboard
2. Select your project
3. Click **Variables** tab
4. Click **+ New Variable**
5. Enter key and value
6. Click **Add**

**Important:** Railway automatically exposes a `PORT` environment variable. Your app should use `process.env.PORT` (which the server does).

### 4. Networking

**Automatic HTTPS:**
- Railway provides a free HTTPS certificate
- All traffic is automatically encrypted
- No configuration needed

**Custom Domain (Optional):**
```
Settings → Networking → Custom Domain
```
Example: `api.geowake.com`

**Health Checks:**
Railway monitors:
- `/` - Root endpoint
- `/api/health` - Health check endpoint

If the server crashes or becomes unresponsive, Railway automatically restarts it.

---

## Deployment Process

### Initial Setup (Already Done)

1. **Create Railway Account**
   - Sign up at https://railway.app
   - Connect GitHub account

2. **Create New Project**
   - Click **New Project**
   - Select **Deploy from GitHub repo**
   - Choose `Raed2180416/GeoWake`

3. **Configure Project**
   - Set root directory to `geowake-server`
   - Add environment variables
   - Configure build settings

4. **Deploy**
   - Railway automatically deploys
   - Assigns a URL: `*.up.railway.app`

### Ongoing Deployments

**Automatic Deployment:**
```bash
# 1. Make changes to code
# 2. Commit changes
git add .
git commit -m "Update backend"

# 3. Push to GitHub
git push origin main

# 4. Railway automatically deploys (no action needed)
```

**Manual Deployment:**
In Railway Dashboard:
1. Go to your project
2. Click **Deployments** tab
3. Click **Deploy** → **Redeploy**

**Rollback:**
If a deployment breaks something:
1. Go to **Deployments** tab
2. Find the last working deployment
3. Click **...** → **Redeploy**

---

## Monitoring & Logs

### Viewing Logs

**Real-time Logs:**
```
Dashboard → Your Project → Logs tab
```

Shows:
- Server startup messages
- Request logs (Morgan)
- Error messages
- Cache statistics

**Example Log Output:**
```
🌍 ================================
🚀 GeoWake API Server Started!
🌍 ================================
📍 Environment: production
🌐 Port: 3000
🔑 Google Maps API: ✅ Configured
🛡️  JWT Secret: ✅ Configured
📱 Bundle ID: com.yourcompany.geowake2
⏰ Started at: 2024-01-15T10:30:00.000Z
🌍 ================================

🚀 GET /api/health 200 - 5ms
🚀 POST /api/auth/token 200 - 12ms
🚀 POST /api/maps/directions 200 - 235ms
💾 Cached directions for 300s: directions:40.7128,-74.0060:40.7580,-73.9855:transit:
📊 Cache Stats - Keys: 15, Hits: 42, Misses: 8
```

### Metrics

Railway provides:
- **CPU Usage**
- **Memory Usage**
- **Network Traffic**
- **Deployment History**
- **Build Times**

Access in Dashboard → **Metrics** tab

---

## Health Checks

The server exposes two health check endpoints:

### Root Endpoint: `GET /`

```bash
curl https://geowake-production.up.railway.app/
```

**Response:**
```json
{
  "success": true,
  "message": "GeoWake API Server",
  "version": "1.0.0",
  "environment": "production",
  "timestamp": "2024-01-15T10:30:00.000Z",
  "uptime": 86400.5
}
```

### Health Endpoint: `GET /api/health`

```bash
curl https://geowake-production.up.railway.app/api/health
```

**Response:**
```json
{
  "success": true,
  "message": "GeoWake Server is running",
  "timestamp": "2024-01-15T10:30:00.000Z",
  "version": "1.0.0",
  "environment": "production"
}
```

Railway uses these endpoints to:
- Determine if the server is healthy
- Auto-restart if health checks fail
- Route traffic only to healthy instances

---

## Scaling

### Vertical Scaling (Current)

Railway automatically scales compute resources based on load:
- **Memory:** Auto-scales up to plan limit
- **CPU:** Scales with traffic
- **Network:** Unlimited bandwidth

### Horizontal Scaling (Premium Feature)

For high traffic, Railway Pro supports:
- **Multiple instances**
- **Load balancing**
- **Auto-scaling rules**

---

## Cost & Limits

### Free Tier (Hobby Plan)
- **Monthly Usage:** $5 of compute time
- **Projects:** Unlimited
- **Deployments:** Unlimited
- **Team Members:** 1

### Current Usage
The GeoWake backend is lightweight:
- **Memory:** ~100-150 MB
- **CPU:** Low (mostly I/O bound)
- **Network:** Moderate (proxying Google API)

**Estimated Cost:** $0-5/month (within free tier for MVP usage)

### Usage Optimization

The backend reduces costs via:
1. **Response Caching** - Reduces Google API calls
2. **Compression** - Reduces bandwidth
3. **Rate Limiting** - Prevents abuse
4. **Efficient Code** - Low CPU/memory usage

---

## Troubleshooting

### Deployment Fails

**Check Build Logs:**
```
Dashboard → Deployments → Failed Deployment → Build Logs
```

**Common Issues:**
- Missing dependencies → Check `package.json`
- Environment variables missing → Check Variables tab
- Port configuration → Ensure using `process.env.PORT`

### Server Crashes

**Check Runtime Logs:**
```
Dashboard → Logs tab
```

**Common Causes:**
- Uncaught exceptions → Add error handling
- Memory leaks → Monitor memory usage
- API key issues → Verify environment variables

### Slow Response Times

**Check Metrics:**
```
Dashboard → Metrics tab
```

**Optimization:**
- Enable caching (already implemented)
- Add response compression (already implemented)
- Optimize API calls
- Consider CDN for static assets

### Cannot Connect from App

**Verify:**
1. Server is running: `curl https://geowake-production.up.railway.app/api/health`
2. CORS is configured correctly
3. Flutter app is using correct URL
4. Authentication is working

**Test Authentication:**
```bash
# Get token
curl -X POST https://geowake-production.up.railway.app/api/auth/token \
  -H "Content-Type: application/json" \
  -d '{"bundleId":"com.yourcompany.geowake2"}'

# Use token
curl -X POST https://geowake-production.up.railway.app/api/maps/directions \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer YOUR_TOKEN_HERE" \
  -d '{"origin":"40.7128,-74.0060","destination":"40.7580,-73.9855","mode":"transit"}'
```

---

## Security Best Practices

### ✅ Implemented

- [x] **API keys stored server-side** (not in app)
- [x] **HTTPS enabled** (automatic via Railway)
- [x] **JWT authentication** required for all API calls
- [x] **Rate limiting** prevents abuse
- [x] **Security headers** via Helmet.js
- [x] **CORS configured** for mobile apps
- [x] **Environment variables** for secrets
- [x] **Bundle ID verification**

### 🔒 Additional Recommendations

- [ ] **Add monitoring** (Sentry, DataDog)
- [ ] **Add alerts** for errors/downtime
- [ ] **Implement API versioning** (/api/v1/...)
- [ ] **Add request validation** (express-validator)
- [ ] **Add audit logging**
- [ ] **Rotate JWT secrets** periodically
- [ ] **Add backup & disaster recovery**

---

## Continuous Integration (Optional)

### GitHub Actions Integration

Create `.github/workflows/deploy.yml`:

```yaml
name: Deploy to Railway

on:
  push:
    branches: [main]
    paths:
      - 'geowake-server/**'

jobs:
  test:
    runs-on: ubuntu-latest
    
    steps:
      - uses: actions/checkout@v3
      
      - name: Setup Node.js
        uses: actions/setup-node@v3
        with:
          node-version: '18'
      
      - name: Install dependencies
        working-directory: ./geowake-server
        run: npm install
      
      - name: Run tests
        working-directory: ./geowake-server
        env:
          GOOGLE_MAPS_API_KEY: ${{ secrets.GOOGLE_MAPS_API_KEY }}
          JWT_SECRET: ${{ secrets.JWT_SECRET }}
        run: npm test
  
  deploy:
    needs: test
    runs-on: ubuntu-latest
    
    steps:
      - name: Deploy to Railway
        run: echo "Railway auto-deploys from GitHub"
```

---

## Alternatives to Railway

If you need to migrate, consider:

| Platform | Pros | Cons |
|----------|------|------|
| **Heroku** | Mature, well-documented | More expensive |
| **Vercel** | Great for serverless | Limited for traditional servers |
| **Render** | Similar to Railway | Slightly slower cold starts |
| **DigitalOcean App Platform** | More control | Requires more configuration |
| **AWS Elastic Beanstalk** | Powerful, scalable | Complex setup |
| **Google Cloud Run** | Auto-scaling, serverless | Requires containerization |

**Railway is ideal for GeoWake because:**
- ✅ Simple setup (no Docker required)
- ✅ Free tier sufficient for MVP
- ✅ Automatic HTTPS
- ✅ GitHub integration
- ✅ Good developer experience

---

## Migration Guide (If Needed)

### Exporting Configuration

**Environment Variables:**
```bash
# Export from Railway Dashboard
Settings → Variables → Copy All
```

**Database (if added later):**
```bash
# Railway provides backup options
Settings → Database → Backups
```

### Deploying to New Platform

Most platforms need:
1. **Dockerfile** (optional, but common)
   ```dockerfile
   FROM node:18-alpine
   WORKDIR /app
   COPY package*.json ./
   RUN npm install --production
   COPY . .
   EXPOSE 3000
   CMD ["npm", "start"]
   ```

2. **Environment Variables** (copy from Railway)

3. **Build Configuration** (usually auto-detected from `package.json`)

---

## Summary

### What Railway Provides

✅ **Automated Deployments**
- Push to GitHub → Auto-deploy
- Zero-downtime updates
- Easy rollbacks

✅ **Infrastructure Management**
- HTTPS certificates
- Load balancing
- Auto-scaling
- Health monitoring

✅ **Developer Experience**
- Simple dashboard
- Real-time logs
- Metrics & analytics
- Environment management

✅ **Cost-Effective**
- Free tier for MVP
- Pay-as-you-grow pricing
- No upfront costs

### Typical Development Flow

1. **Develop locally** (`npm run dev`)
2. **Test changes** (`npm test`)
3. **Commit & push** to GitHub
4. **Railway auto-deploys**
5. **Monitor in dashboard**
6. **Verify via health checks**

---

**Document Version:** 1.0  
**Last Updated:** 2024-01-15  
**Platform:** Railway.app  
**Maintained By:** GeoWake Development Team
