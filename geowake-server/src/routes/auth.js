// src/routes/auth.js
const express = require('express');
const { generateToken } = require('../controllers/authController');
const { rateLimitRules } = require('../middleware/security'); // Corrected import

const router = express.Router();

// Apply a specific rate limit for authentication requests
router.post('/token', rateLimitRules.auth, generateToken);

module.exports = router;
