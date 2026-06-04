// React components for embedding ego-ingest in your own web app.
//
// All components are **headless** w.r.t. styling — they render the
// minimal semantic markup (`<ul>`, `<dl>`, `<table>`) and apply only
// inline structural styles. Bring your own CSS / Tailwind / Mantine /
// shadcn — class names follow a `ego-*` prefix so you can target them
// without conflicting with your design system.
//
// They share one piece of glue: the `apiBase` URL where the
// `createReadApi()` middleware was mounted server-side.

export { SessionList } from "./SessionList.js";
export { SessionDetail } from "./SessionDetail.js";
export { StatsPanel } from "./StatsPanel.js";
export { useIngestEvents } from "./useIngestEvents.js";

export type { SessionListProps } from "./SessionList.js";
export type { SessionDetailProps } from "./SessionDetail.js";
export type { StatsPanelProps } from "./StatsPanel.js";
