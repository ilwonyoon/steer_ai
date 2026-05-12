import os from "node:os";
import path from "node:path";

export const steerHome = process.env.STEER_HOME || path.join(os.homedir(), ".steer");
export const socketPath = process.env.STEER_SOCKET || path.join(steerHome, "steer.sock");
export const sessionsDir = path.join(steerHome, "sessions");
export const databasePath = process.env.STEER_DB || path.join(steerHome, "steer.sqlite");
// PR S1: exclusive lockfile claimed before createStore so two
// concurrent agent processes can't race the SQLite open. Default
// next to the socket; STEER_LOCK overrides for tests.
export const lockfilePath = process.env.STEER_LOCK || path.join(steerHome, "agent.lock");
