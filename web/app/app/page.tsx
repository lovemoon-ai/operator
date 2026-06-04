import { SessionList } from "./components/SessionList";
import { StatsCards } from "./components/StatsCards";

// Home: stats overview + session list. Everything is rendered as
// client components because the underlying data updates live via SSE
// — server components would require a full RSC stream per refresh,
// which is more machinery than we need for a live dashboard.
export default function HomePage() {
  return (
    <div style={{ display: "grid", gap: 16 }}>
      <section className="panel">
        <h2>Overview</h2>
        <StatsCards apiBase="/api/ingest-read" />
      </section>
      <section className="panel">
        <h2>Sessions</h2>
        <SessionList apiBase="/api/ingest-read" reviewsBase="/api/reviews" />
      </section>
    </div>
  );
}
