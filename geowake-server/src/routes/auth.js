// src/routes/auth.js
const express = require('express');
const { generateToken } = require('../controllers/authController');
const { rateLimitRules } = require('../middleware/security'); // Corrected import variable name

const router = express.Router();

// Apply a specific rate limit for authentication requests
router.post('/token', rateLimitRules.auth, generateToken); // Corrected variable name

module.exports = router;
