import os from "node:os";
import path from "node:path";

export const steerHome = process.env.STEER_HOME || path.join(os.homedir(), ".steer");
export const socketPath = process.env.STEER_SOCKET || path.join(steerHome, "steer.sock");
export const sessionsDir = path.join(steerHome, "sessions");
export const databasePath = process.env.STEER_DB || path.join(steerHome, "steer.sqlite");
