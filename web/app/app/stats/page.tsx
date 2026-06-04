import { StatsCards } from "../components/StatsCards";
import { DailyTable } from "./DailyTable";

export const dynamic = "force-dynamic";

export default function StatsPage() {
  return (
    <div style={{ display: "grid", gap: 16 }}>
      <section className="panel">
        <h2>Aggregate</h2>
        <StatsCards apiBase="/api/ingest-read" />
      </section>
      <section className="panel">
        <h2>Daily breakdown</h2>
        <DailyTable apiBase="/api/ingest-read" />
      </section>
    </div>
  );
}
