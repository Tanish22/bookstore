import dotenv from 'dotenv';
dotenv.config();

const { PORT, mongodb_local_url, COSMOS_DB_URL, mongodb_atlas_url } = process.env;

import express from 'express';
// import { PORT, mongoDBURL } from './config.js';
import mongoose from 'mongoose';
import booksRoute from './routes/booksRoute.js';
import cors from 'cors';

// new changes to optimise and centralise logging on the server meant for logging

import pino from 'pino';
import os from 'os';

const app = express();

const logger = pino({
    level: process.env.LOG_LEVEL || 'info',
    // LOG_LEVEL from .env — allows changing verbosity without code changes
    // 'info' captures info, warn, error. Use 'debug' for development.
    
    base: {
        hostname: os.hostname(),
        machine_ip: process.env.MACHINE_IP || '192.168.1.10'
        // These fields appear in EVERY log entry from this instance
        // No need to manually add them to every logger.info() call
    },
    
    timestamp: pino.stdTimeFunctions.isoTime
    // ISO 8601 format: "2024-01-06T12:34:56.789Z"
    // Human-readable AND machine-sortable AND timezone-unambiguous
});

app.use(express.json());
app.use(cors());

app.get('/api/health', (req, res) => {
    res.json({
        status: 'ok',
        hostname: os.hostname(),
        machine_ip: process.env.MACHINE_IP || 'unknown',
	pid: process.pid,		
        uptime_seconds: Math.floor(process.uptime()),
        timestamp: new Date().toISOString()
    });
});

app.get('/', (request, response) => {
  return response.status(200).send("Welcome To MERN Bookstore on Tanish's Vivobook => Backend 1 !!");
});

// Request logging middleware - runs on every request
app.use((req, res, next) => {
  const start = Date.now();
  res.on('finish', () => {
    const logData = {
      ip: req.ip,
      method: req.method,
      path: req.originalUrl,
      status: res.statusCode,
      ua: req.headers['user-agent'],
      duration_ms: Date.now() - start,
    };

    // Log errors with warn/error level so you can filter them separately
    if (res.statusCode >= 500) {
      logger.error(logData);
    } else if (res.statusCode >= 400) {
      logger.warn(logData);
    } else {
      logger.info(logData);
    }
  });
  next();
});

app.use('/api/books', booksRoute);

mongoose
  .connect(mongodb_atlas_url)
  .then(() => {
    logger.info('App connected to database');
    app.listen(PORT, '0.0.0.0', () => {
      logger.info({ port: PORT }, 'App is listening');
    });
  })
  .catch((error) => {
    logger.error({ err: error }, 'Database connection failed');
    process.exit(1); // Exit on DB failure — no point running without DB
  });




