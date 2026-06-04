/**
 * Per-session review state.
 *
 * Kept in a separate JSON file from the ingest's session index so the
 * ego-ingest package never has to know about app-specific concepts
 * (reviewed / flagged / notes). If you swap MemoryStore for SQLite
 * later, this file becomes a `reviews` table — the rest of the app
 * doesn't change.
 */

import { existsSync, mkdirSync, readFileSync, renameSync, writeFileSync } from "node:fs";
import path from "node:path";

import express, { type Request, type Response } from "express";

const DATA_ROOT = path.resolve(process.env.DATA_ROOT ?? "./data");
const REVIEWS_FILE = path.join(DATA_ROOT, "reviews.json");

export interface Review {
  sessionId: string;
  reviewed: boolean;
  flagged: boolean;
  notes: string;
  updatedAt: string;
}

type ReviewsMap = Record<string, Review>;

function load(): ReviewsMap {
  if (!existsSync(REVIEWS_FILE)) return {};
  try {
    return JSON.parse(readFileSync(REVIEWS_FILE, "utf8")) as ReviewsMap;
  } catch {
    return {};
  }
}

function save(reviews: ReviewsMap): void {
  mkdirSync(DATA_ROOT, { recursive: true });
  const tmp = REVIEWS_FILE + ".tmp";
  writeFileSync(tmp, JSON.stringify(reviews, null, 2), "utf8");
  renameSync(tmp, REVIEWS_FILE);
}

const cache: ReviewsMap = load();

export function getReview(sessionId: string): Review {
  return (
    cache[sessionId] ?? {
      sessionId,
      reviewed: false,
      flagged: false,
      notes: "",
      updatedAt: "",
    }
  );
}

export function listReviews(): ReviewsMap {
  return { ...cache };
}

export function updateReview(sessionId: string, patch: Partial<Omit<Review, "sessionId" | "updatedAt">>): Review {
  const prev = getReview(sessionId);
  const next: Review = {
    ...prev,
    ...patch,
    sessionId,
    updatedAt: new Date().toISOString(),
  };
  cache[sessionId] = next;
  save(cache);
  return next;
}

export function deleteReview(sessionId: string): void {
  if (sessionId in cache) {
    delete cache[sessionId];
    save(cache);
  }
}

// --- HTTP router ----------------------------------------------------------

export const reviewsRouter = express.Router();
reviewsRouter.use(express.json({ limit: "256kb" }));

reviewsRouter.get("/", (_req: Request, res: Response) => {
  res.json(listReviews());
});

reviewsRouter.get("/:id", (req: Request, res: Response) => {
  res.json(getReview(req.params.id!));
});

reviewsRouter.patch("/:id", (req: Request, res: Response) => {
  const body = (req.body ?? {}) as Partial<Review>;
  // Hand-pick the fields we accept so a malicious payload can't smuggle
  // anything weird into the cache.
  const patch: Partial<Review> = {};
  if (typeof body.reviewed === "boolean") patch.reviewed = body.reviewed;
  if (typeof body.flagged === "boolean") patch.flagged = body.flagged;
  if (typeof body.notes === "string") patch.notes = body.notes.slice(0, 4000);
  const updated = updateReview(req.params.id!, patch);
  res.json(updated);
});

reviewsRouter.delete("/:id", (req: Request, res: Response) => {
  deleteReview(req.params.id!);
  res.status(204).end();
});
